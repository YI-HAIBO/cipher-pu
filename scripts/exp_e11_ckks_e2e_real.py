#!/usr/bin/env python3
"""
E11: 真实 CKKS 加密推理 (RLWE + 系数编码同态点积)

v4 重写（修复 v3 的所有数值错误）：

v3 的致命缺陷：
1. 整数 m_x（round(Δ·x)）使消息尺度变为 Δ²（加密乘 Δ，m_x 又乘 Δ），
   导致 ct×m_w 后消息尺度为 Δ³，rescale 后为 Δ²，最终除以 Δ 得到 Δ·(x·w) 而非 (x·w)。
2. rescale 用 float64 计算 b·inv，乘积 ~q²≈10^18 超出 float64 精确整数范围 (2^53)。
3. rescale 对噪声也乘 inv（而非除以 Δ），当 noise·inv > q 时模 q 把噪声变成随机值。

v4 的正确方案（经 20+ 轮调试验证）：
- **分数 m_x**：m_x[i] = x[i]（不预乘 Δ），加密时乘一次 Δ → 消息在 Δ 尺度
- **整数 m_w**：m_w 条目为 round(Δ·w_j)，整数是模 q 同余在卷积下保持的必要条件
  （分数 m_w 会使 k·q 项在卷积后产生非零分数部分，破坏模 q 消去）
- **无 rescale**：ct×m_w 后消息在 Δ² 尺度，直接解密后除以 Δ²
- **偏置符号**：p_poly[0] = -Δ·b（rlwe_add_plain 内部再乘 Δ，共 -Δ²·b），
  使得解密常数项 = -Δ²·(x·w + b)，取负除以 Δ² 得 x·w + b
- 每层后 ReLU → 重新加密（分数 m_h1），下一层 ct×m_w2 消息在 Δ²

正确性保证：脚本内置自测（N=16），断言同态线性层解密结果与明文点积的相对误差
在噪声容限内；自测不过则直接退出，不跑大数据。
"""

import json
import math
import os
import sys
import time

import numpy as np

import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "reports", "experiments")
DATA_DIR = os.path.join(ROOT, "data")
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(DATA_DIR, exist_ok=True)

# ===================== 多项式运算（负循环卷积） =====================

def neg_conv(x, y):
    """负循环卷积 c = x *_{neg} y，长度 N=len(x)=len(y)。

    c_k = Σ_{i+j=k} x_i y_j  -  Σ_{i+j=k+N} x_i y_j

    通过线性卷积 + 折叠实现，数值精确（累加和 < 2^53 时 float64 无损）。
    """
    x = np.asarray(x, dtype=np.float64)
    y = np.asarray(y, dtype=np.float64)
    N = len(x)
    conv = np.convolve(x, y, "full")  # 长度 2N-1，索引 0..2N-2
    c = np.zeros(N, dtype=np.float64)
    c[:] = conv[:N]
    c[: N - 1] -= conv[N : 2 * N - 1]  # conv[N..2N-2] 对应 k=0..N-2
    return c


# ===================== RLWE CKKS（模 q 整数环） =====================

def mod_center(v, q):
    """把 v 居中到 [-q/2, q/2)（float64）。"""
    v = np.mod(np.asarray(v, dtype=np.float64), q)
    return np.where(v > q / 2, v - q, v)


def rlwe_encrypt(m_poly, s, e, q, scale):
    """RLWE 加密：b = a·s + e + Δ·m (mod q)，a 均匀随机。

    m_poly 是**分数**明文（不预乘 Δ），此处乘 Δ 后加入密文。
    全程 float64：a/s/e 是整数采样，消息部分 Δ·m 与卷积结果保持浮点。
    """
    N = len(s)
    # np.random.randint 的 high 参数受限于 int32；大 Q (>2^31) 时改用 float64 均匀采样
    if q <= 2**31 - 1:
        a = np.random.randint(0, q, size=N).astype(np.int64)
    else:
        a = np.floor(np.random.random(size=N) * q).astype(np.int64)
    as_prod = neg_conv(a.astype(np.float64), s.astype(np.float64))
    b = as_prod + e.astype(np.float64) + scale * m_poly
    b = np.mod(b, q)
    return b, a


def rlwe_decrypt(ct, s, q):
    """RLWE 解密：m_noisy = (b - a·s) mod q，居中后得到 Δ·明文多项式（未除 Δ）。

    加密用 b = a·s + e + Δ·m，故解密用 b - a·s = e + Δ·m。
    返回值是 Δ·m（调用方需除以 scale 得到明文）。
    """
    b, a = ct
    as_prod = neg_conv(a.astype(np.float64), s.astype(np.float64))
    m = np.asarray(b, dtype=np.float64) - as_prod
    return mod_center(m, q)


def rlwe_mul_plain(ct, p_poly, q):
    """密文 × 明文多项式（同态）：(b·p, a·p) mod q。全程 float64。

    p_poly 必须为**整数**多项式（分数 p_poly 会破坏模 q 同余）。
    """
    b, a = ct
    new_b = np.mod(neg_conv(np.asarray(b, dtype=np.float64), p_poly), q)
    new_a = np.mod(neg_conv(np.asarray(a, dtype=np.float64), p_poly), q)
    return new_b, new_a


def rlwe_add_plain(ct, p_poly, q, scale):
    """密文 + 明文多项式：b += Δ·p (mod q)。全程 float64。

    p_poly 是"未乘 Δ"的明文偏置，此处乘 Δ 后加到 b 上。
    消息域增加 p_poly（消息本身在 Δ 尺度）。
    """
    b, a = ct
    b = np.mod(np.asarray(b, dtype=np.float64) + scale * p_poly, q)
    return b, a


# ===================== 系数编码同态线性层 =====================

def build_weight_poly(w_row, N, scale):
    """把权重行 w_row 编码为**整数**明文多项式（Δ 尺度）。

    m_w[0] = -round(Δ·w_0)（由 X^N=-1 折叠产生），m_w[N-j] = round(Δ·w_j) (j=1..D-1)。

    整数 m_w 是必须的：ct×m_w 时 b_x 已被模 q 约简，若 m_w 有分数条目，
    k·q·m_w 的分数部分在 mod q 后不消失，破坏同态线性。
    """
    D = len(w_row)
    m_w = np.zeros(N, dtype=np.float64)
    m_w[0] = -round(scale * w_row[0])
    for j in range(1, D):
        m_w[N - j] = round(scale * w_row[j])
    return m_w


def encrypted_linear_layer(ct_x, W, b, s, q, scale):
    """同态计算 y = W x + b（系数编码，无 rescale）。

    对每个输出 o：
      m_w = build_weight_poly(W[o])        # 整数明文，Δ 尺度
      ct_o = ct_x × m_w                    # 消息变为 Δ²·(x·w)
      # 不 rescale：消息保持在 Δ² 尺度
      # 偏置：加 -Δ·b_o 到常数项（rlwe_add_plain 内部乘 Δ，共 -Δ²·b_o）
      bias_poly = np.zeros(N, dtype=np.float64)
      bias_poly[0] = -scale * b[o]         # 关键：负号！
      ct_o = rlwe_add_plain(ct_o, bias_poly, q, scale)

    返回 ct_outputs（解密常数项取负除以 Δ² 即得输出值）。
    """
    N = len(s)
    ct_outputs = []
    for o in range(W.shape[0]):
        m_w = build_weight_poly(W[o], N, scale)
        ct_o = rlwe_mul_plain(ct_x, m_w, q)
        # 偏置：p_poly[0] = -Δ·b_o，rlwe_add_plain 加 Δ·p_poly = -Δ²·b_o
        bias_poly = np.zeros(N, dtype=np.float64)
        bias_poly[0] = -scale * b[o]
        ct_o = rlwe_add_plain(ct_o, bias_poly, q, scale)
        ct_outputs.append(ct_o)
    return ct_outputs


def estimate_r_hat(decrypted_val, true_val):
    """从解密值与明文真值的相对误差估计噪声比 r_hat（CKKS 噪声度量）。

    对齐 adaptive_gear_ctrl.sv 的 noise_monitor：FPGA 从密文统计量估计噪声水平，
    此处用精确的解密残差作为噪声比（离线标定场景下可获得真值）。
    """
    denom = abs(true_val) + 1e-8
    return float(min(abs(decrypted_val - true_val) / denom, 1.0))


# ===================== 自适应档位控制器（对齐 adaptive_gear_ctrl.sv） =====================

GEARS = [
    {"name": "Gear 0 (严格)", "noise_factor": 1.00, "cost_factor": 1.00, "r_max": 0.10},
    {"name": "Gear 1 (均衡)", "noise_factor": 1.60, "cost_factor": 0.62, "r_max": 0.20},
    {"name": "Gear 2 (激进)", "noise_factor": 2.40, "cost_factor": 0.36, "r_max": 0.35},
    {"name": "Gear 3 (极限)", "noise_factor": 3.50, "cost_factor": 0.20, "r_max": 0.55},
]


def select_gear(r_hat, safety_first=True):
    """safety-first：选择能容忍当前 r_hat 的最严格档位。"""
    if safety_first:
        for g in range(len(GEARS)):
            if GEARS[g]["r_max"] >= r_hat:
                return g
        return 0
    best = 0
    for g in range(len(GEARS)):
        if GEARS[g]["r_max"] >= r_hat:
            best = g
    return best


# ===================== 正确性自测 =====================

def self_test():
    """验证同态线性层解密结果 = 明文点积（在噪声容限内）。

    v4 方案：分数 m_x + 整数 m_w + 无 rescale + 除以 Δ²。
    """
    print("[自测] 验证系数编码同态点积正确性（v4 方案）...")
    np.random.seed(42)
    N = 16
    q = 998244353
    scale = 2**14  # 16384: scale²·0.12 ≈ 3.2e7 < q/2 ≈ 5e8
    D = 8
    x = np.random.rand(D) * 0.5
    w = np.random.rand(D) * 2.0 - 1.0
    b_val = 0.3

    s = np.random.randint(-1, 2, size=N).astype(np.int64)
    e = np.random.randint(-2, 3, size=N).astype(np.int64)

    # 明文点积
    plain_dp = float(x @ w + b_val)

    # 分数 m_x（不预乘 Δ）
    m_x = np.zeros(N, dtype=np.float64)
    m_x[:D] = x

    ct_x = rlwe_encrypt(m_x, s, e, q, scale)

    W = w.reshape(1, D)
    b_arr = np.array([b_val])
    ct_outs = encrypted_linear_layer(ct_x, W, b_arr, s, q, scale)

    # 解密常数项，取负并除以 Δ²
    m_dec = rlwe_decrypt(ct_outs[0], s, q)
    enc_dp = -float(m_dec[0]) / (scale * scale)

    rel_err = abs(enc_dp - plain_dp) / (abs(plain_dp) + 1e-12)
    print(f"  明文点积: {plain_dp:.6f}, 同态解密: {enc_dp:.6f}, 相对误差: {rel_err:.2e}")
    assert rel_err < 0.05, f"自测失败: 相对误差 {rel_err} 超过 5%"
    print("[自测] 通过 ✓")
    return True


# ===================== MNIST 模型 =====================

class PlainMLP(nn.Module):
    def __init__(self, hidden1=64, hidden2=32):
        super().__init__()
        self.fc1 = nn.Linear(784, hidden1)
        self.fc2 = nn.Linear(hidden1, hidden2)
        self.fc3 = nn.Linear(hidden2, 10)

    def forward(self, x):
        x = x.view(-1, 784)
        x = torch.relu(self.fc1(x))
        x = torch.relu(self.fc2(x))
        return self.fc3(x)


def load_mnist(num_samples=2000):
    transform = transforms.Compose([transforms.ToTensor()])
    test = datasets.MNIST(DATA_DIR, train=False, download=False, transform=transform)
    subset = torch.utils.data.Subset(test, range(min(num_samples, len(test))))
    loader = torch.utils.data.DataLoader(subset, batch_size=64, shuffle=False)
    return loader, len(subset)


def train_model(model, epochs=8, lr=0.01):
    optimizer = optim.SGD(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()
    train_dataset = datasets.MNIST(DATA_DIR, train=True, download=False,
                                   transform=transforms.Compose([transforms.ToTensor()]))
    train_loader = torch.utils.data.DataLoader(train_dataset, batch_size=64, shuffle=True)
    model.train()
    for epoch in range(epochs):
        for data, target in train_loader:
            optimizer.zero_grad()
            output = model(data)
            loss = criterion(output, target)
            loss.backward()
            optimizer.step()
    return model


def evaluate_plain(model, loader):
    model.eval()
    correct = 0
    total = 0
    with torch.no_grad():
        for data, target in loader:
            output = model(data)
            pred = output.argmax(dim=1)
            correct += (pred == target).sum().item()
            total += target.size(0)
    return correct / total


# ===================== CKKS 加密推理 =====================

def ckks_inference(model, x_plain, s_key, q, scale, noise_sigma):
    """完整 3 层 CKKS 加密推理（系数编码同态线性层 + 明文 ReLU + 重加密）。

    v4 方案：分数 m_x + 整数 m_w + 无 rescale + 除以 Δ²。
    明文前向同时计算作为各层真值基准，用于估计 r_hat（噪声比）并驱动档位选择。
    返回: (decrypted_outputs, layer_r_hats, layer_gears, total_noise_growth)
    """
    W1 = model.fc1.weight.detach().numpy()
    b1 = model.fc1.bias.detach().numpy()
    W2 = model.fc2.weight.detach().numpy()
    b2 = model.fc2.bias.detach().numpy()
    W3 = model.fc3.weight.detach().numpy()
    b3 = model.fc3.bias.detach().numpy()

    D = 784
    N = 1
    while N < D:
        N *= 2
    N = max(N, 1024)

    # ---- 明文前向（各层真值基准）----
    h1_p = np.maximum(x_plain @ W1.T + b1, 0.0)
    h2_p = np.maximum(h1_p @ W2.T + b2, 0.0)
    out_p = h2_p @ W3.T + b3

    # ---- 编码 + 加密输入（分数 m_x，不预乘 Δ）----
    m_x = np.zeros(N, dtype=np.float64)
    m_x[:D] = x_plain  # 分数，加密时乘 Δ
    e = np.random.randint(-noise_sigma, noise_sigma + 1, size=N).astype(np.int64)
    ct = rlwe_encrypt(m_x, s_key, e, q, scale)

    all_r_hats = []
    all_gears = []
    noise_growth = 1.0

    def _layer(ct_in, W, b, plain_ref):
        """同态一层：加密运算 → 解密 → 计算 r_hat/档位 → ReLU。"""
        nonlocal noise_growth
        ct_outs = encrypted_linear_layer(ct_in, W, b, s_key, q, scale)
        outs = np.zeros(W.shape[0], dtype=np.float64)
        r_hats = []
        gears = []
        for o in range(W.shape[0]):
            m_dec = rlwe_decrypt(ct_outs[o], s_key, q)
            # 消息在 Δ² 尺度，除以 Δ² 得到明文值
            val = -float(m_dec[0]) / (scale * scale)
            outs[o] = val
            r_hats.append(estimate_r_hat(val, float(plain_ref[o])))
            gears.append(select_gear(r_hats[-1]))
        all_r_hats.extend(r_hats)
        all_gears.extend(gears)
        noise_growth *= float(np.mean([GEARS[g]["noise_factor"] for g in gears]) or 1.0)
        return outs

    # ---- 第一层 ----
    h1 = _layer(ct, W1, b1, h1_p)
    h1 = np.maximum(h1, 0.0)  # ReLU

    # 重新加密 h1（分数 m_h1，不预乘 Δ）
    m_h1 = np.zeros(N, dtype=np.float64)
    m_h1[:W1.shape[0]] = h1
    e2 = np.random.randint(-noise_sigma, noise_sigma + 1, size=N).astype(np.int64)
    ct = rlwe_encrypt(m_h1, s_key, e2, q, scale)

    # ---- 第二层 ----
    h2 = _layer(ct, W2, b2, h2_p)
    h2 = np.maximum(h2, 0.0)

    m_h2 = np.zeros(N, dtype=np.float64)
    m_h2[:W2.shape[0]] = h2
    e3 = np.random.randint(-noise_sigma, noise_sigma + 1, size=N).astype(np.int64)
    ct = rlwe_encrypt(m_h2, s_key, e3, q, scale)

    # ---- 第三层 ----
    out = _layer(ct, W3, b3, out_p)

    return out, all_r_hats, all_gears, noise_growth


# ===================== 主实验 =====================

def main():
    print("=" * 60)
    print("E11: 真实 CKKS 加密推理 (RLWE + 系数编码同态点积) v4")
    print("=" * 60)

    # ---- 0. 自测 ----
    if not self_test():
        print("自测失败，退出")
        sys.exit(1)

    # ---- 1. 加载数据 ----
    print("\n[1/5] 加载 MNIST...")
    loader, n_samples = load_mnist(num_samples=2000)
    print(f"  测试样本: {n_samples}")

    # ---- 2. 训练模型 ----
    print("\n[2/5] 训练明文 MLP (784→64→32→10, ReLU)...")
    model = PlainMLP(hidden1=64, hidden2=32)
    model = train_model(model, epochs=8, lr=0.01)
    plain_acc = evaluate_plain(model, loader)
    print(f"  明文精度: {plain_acc:.4f} ({plain_acc*100:.2f}%)")

    # ---- 3. CKKS 参数 ----
    Q = 998244353      # NTT 友好素数 (≡1 mod 2048)，支持 N=1024
    SCALE = 2**12      # 4096: scale²·10 ≈ 1.7e8 < q/2 ≈ 5e8（MNIST 中间值 ≤10）
    print(f"\n  CKKS 参数: Q={Q}, SCALE={SCALE}, N=1024")

    # ---- 4. 预处理数据 ----
    all_data = []
    all_targets = []
    for data, target in loader:
        all_data.append(data.numpy())
        all_targets.append(target.numpy())
    all_data = np.concatenate(all_data, axis=0)
    all_targets = np.concatenate(all_targets, axis=0)

    n_test = min(50, len(all_data))

    # ---- 5. CKKS 加密推理（噪声 sigma sweep）----
    print("\n[3/5] CKKS 加密推理（乘性噪声累积，5 档初始噪声）...")

    noise_sigmas = [1, 4, 16, 64, 256]
    results_by_sigma = {}

    t0 = time.time()
    for sigma in noise_sigmas:
        correct = 0
        total = 0
        all_rel_errors = []
        all_gears = []
        all_r_hats = []
        noise_growths = []

        for i in range(n_test):
            x = all_data[i].flatten()
            x = x * 0.3081 + 0.1307
            x = np.clip(x, 0, 1)

            s_key = np.random.randint(-1, 2, size=1024).astype(np.int64)

            out_enc, r_hats, gears, noise_growth = ckks_inference(
                model, x, s_key, Q, SCALE, sigma
            )

            # 明文前向（基准）
            with torch.no_grad():
                xt = torch.from_numpy(all_data[i]).view(1, 1, 28, 28)
                out_plain = model(xt).numpy()[0]

            pred = int(np.argmax(out_enc))
            actual = int(all_targets[i])
            if pred == actual:
                correct += 1
            total += 1

            rel_err = np.mean(np.abs(out_enc - out_plain) / (np.abs(out_plain) + 1e-8))
            all_rel_errors.append(float(rel_err))
            all_gears.extend(gears)
            all_r_hats.extend(r_hats)
            noise_growths.append(noise_growth)

        acc = correct / total if total > 0 else 0.0
        avg_rel_error = float(np.mean(all_rel_errors)) if all_rel_errors else 0.0
        avg_noise = float(np.mean(noise_growths)) if noise_growths else 0.0
        avg_r_hat = float(np.mean(all_r_hats)) if all_r_hats else 0.0

        gear_dist = {}
        for g in all_gears:
            gname = GEARS[g]["name"]
            gear_dist[gname] = gear_dist.get(gname, 0) + 1

        results_by_sigma[sigma] = {
            "accuracy": acc,
            "correct": correct,
            "total": total,
            "avg_rel_error": avg_rel_error,
            "avg_noise_growth": avg_noise,
            "avg_r_hat": avg_r_hat,
            "gear_distribution": gear_dist,
        }

        print(f"  sigma={sigma:4d}: 精度={acc:.4f} ({acc*100:.2f}%), "
              f"avg_rel_error={avg_rel_error:.6f}, avg_r_hat={avg_r_hat:.6f}, "
              f"avg_noise_growth={avg_noise:.2f}")
        print(f"    档位分布: {gear_dist}")

    elapsed = time.time() - t0
    print(f"\n  总耗时: {elapsed:.1f}s")

    # ---- 6. 保存 ----
    print("\n[4/5] 保存结果...")
    output = {
        "experiment": "E11: 真实 CKKS 加密推理 (RLWE + 系数编码同态点积) v4",
        "version": "v4",
        "method": "fractional m_x + integer m_w + no rescale + divide by scale^2",
        "plain_accuracy": plain_acc,
        "n_samples": n_samples,
        "Q": Q,
        "SCALE": SCALE,
        "N": 1024,
        "noise_sigmas": noise_sigmas,
        "results_by_sigma": results_by_sigma,
        "elapsed_seconds": elapsed,
    }

    json_path = os.path.join(OUT_DIR, "e11_ckks_e2e_real.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"  JSON: {json_path}")

    # Markdown 报告
    md_path = os.path.join(OUT_DIR, "e11_ckks_e2e_real.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# E11: 真实 CKKS 加密推理 (RLWE + 系数编码同态点积) v4\n\n")
        f.write("## 方法\n\n")
        f.write("- **分数 m_x**：输入 x 直接编码为多项式（不预乘 Δ），加密时乘一次 Δ\n")
        f.write("- **整数 m_w**：权重行编码为 round(Δ·w_j)，整数是模 q 同余在卷积下保持的必要条件\n")
        f.write("- **无 rescale**：ct×m_w 后消息在 Δ² 尺度，解密后除以 Δ²\n")
        f.write("- **偏置符号**：p_poly[0] = -Δ·b（rlwe_add_plain 内部再乘 Δ，共 -Δ²·b）\n")
        f.write("- 每层后 ReLU → 重新加密（分数 m_h），下一层 ct×m_w2\n\n")
        f.write("## 参数\n\n")
        f.write(f"- Q = {Q}\n")
        f.write(f"- SCALE = {SCALE}\n")
        f.write(f"- N = 1024\n")
        f.write(f"- 明文精度: {plain_acc:.4f}\n\n")
        f.write("## 结果\n\n")
        f.write("| sigma | 精度 | avg_rel_error | avg_r_hat | 档位分布 |\n")
        f.write("|-------|------|---------------|-----------|----------|\n")
        for sigma in noise_sigmas:
            r = results_by_sigma[sigma]
            gd = ", ".join(f"{k}: {v}" for k, v in r["gear_distribution"].items())
            f.write(f"| {sigma} | {r['accuracy']:.4f} ({r['accuracy']*100:.2f}%) | "
                    f"{r['avg_rel_error']:.6f} | {r['avg_r_hat']:.6f} | {gd} |\n")
        f.write(f"\n耗时: {elapsed:.1f}s\n")
    print(f"  MD: {md_path}")

    print("\n[5/5] 完成 ✓")


if __name__ == "__main__":
    main()