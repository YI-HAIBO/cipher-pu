#!/usr/bin/env python3
"""
E14: 端到端 CNN 加密推理验证

目的：证明 E11 v4 方案（系数编码同态线性层）可扩展到 CNN。

方法：
- CNN: Conv2d(1, 4, 3, padding=1, stride=4) → ReLU → Flatten(196) → FC(196, 32) → ReLU → FC(32, 10)
- 卷积通过 IM2COL 概念转化为 196 个独立的 9 元素点积（stride=4 直接下采样到 7×7）
- 复用 E11 v4 系数编码同态线性层（分数 m_x + 整数 m_w + 无 rescale + Δ² 除法）
- 卷积权重多项式使用"散布位置"约定：每个 3x3 patch 覆盖的 9 个输入像素位置不同
- ReLU 在解密域计算后重新加密（明文点态操作，不引入额外噪声）
- **关键**：stride=4 将 FC1 输入从 784 缩减到 196，使 Δ²·196=196M < q/2=499M，避免溢出

参数：N=1024, Q=998244353, SCALE=2^10
测试：10 个 MNIST 样本 × 3 档噪声 sigma
"""

import json
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

sys.path.insert(0, os.path.join(ROOT, "scripts"))
from exp_e11_ckks_e2e_real import (
    neg_conv, mod_center, rlwe_encrypt, rlwe_decrypt,
    rlwe_mul_plain, rlwe_add_plain, build_weight_poly,
    encrypted_linear_layer,
    estimate_r_hat, select_gear, GEARS,
    load_mnist,
)


# ===================== CNN 架构 =====================

class SmallCNN(nn.Module):
    """紧凑 CNN：Conv2d(1,4,3,pad=1,stride=4) → ReLU → FC(196,32) → ReLU → FC(32,10)。
    stride=4 将输出缩到 7x7，避免 FC1 dot product 溢出。"""
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 4, 3, padding=1, stride=4)  # 28x28 → 4x7x7
        self.fc1 = nn.Linear(4 * 7 * 7, 32)                   # 196 → 32
        self.fc2 = nn.Linear(32, 10)                          # 32 → 10

    def forward(self, x):
        x = torch.relu(self.conv1(x))
        x = x.view(x.size(0), -1)
        x = torch.relu(self.fc1(x))
        return self.fc2(x)


# ===================== 加密原语（散布位置版） =====================

def build_weight_poly_scattered(msg_indices, weights, N, scale):
    """
    构造散布位置的权重多项式（卷积用）。
    E11 v4 约定：msg_idx=0 取负号，msg_idx>=1 存于 m_w[N-msg_idx]。
    """
    m_w = np.zeros(N, dtype=np.float64)
    for msg_idx, w in zip(msg_indices, weights):
        val = round(scale * w)
        if msg_idx == 0:
            m_w[0] = -val
        else:
            m_w[N - msg_idx] = val
    return m_w


def encrypt_vec(vec, s_key, q, scale, noise_sigma):
    """把 1D 向量加密为一个 RLWE 密文（分数 m_x，不预乘 Δ）。"""
    N = len(s_key)
    m_x = np.zeros(N, dtype=np.float64)
    m_x[:len(vec)] = vec
    e = np.random.randint(-noise_sigma, noise_sigma + 1, size=N).astype(np.int64)
    return rlwe_encrypt(m_x, s_key, e, q, scale)


def encrypted_conv(ct_x, W1, b1, s_key, q, scale):
    """
    加密卷积层 Conv2d(1, 4, 3, padding=1, stride=4) → ReLU。
    ct_x: 加密的 784-长度输入（28x28 展平）
    W1: (4, 1, 3, 3)
    b1: (4,)
    返回: (7, 7, 4) 明文输出（已 ReLU）
    """
    N = len(s_key)
    Hp, Wp = 7, 7
    num_f = W1.shape[0]
    conv_out = np.zeros((Hp, Wp, num_f), dtype=np.float64)
    for i in range(Hp):
        for j in range(Wp):
            for f in range(num_f):
                # 计算 3x3 patch 覆盖的 9 个输入像素 msg_idx
                # stride=4, pad=1: output (i,j) → input (4i+k-1, 4j+l-1) for k,l in 0..2
                msg_indices = []
                filter_weights = []
                for k in range(3):
                    for l in range(3):
                        ii = 4 * i + k - 1
                        jj = 4 * j + l - 1
                        if 0 <= ii < 28 and 0 <= jj < 28:
                            msg_indices.append(ii * 28 + jj)
                            filter_weights.append(float(W1[f, 0, k, l]))
                # 散布位置权重多项式
                m_w = build_weight_poly_scattered(msg_indices, filter_weights, N, scale)
                # 同态乘法
                ct_out = rlwe_mul_plain(ct_x, m_w, q)
                # 加偏置（p_poly[0] = -Δ·b，rlwe_add_plain 再乘 Δ 共 -Δ²·b）
                bias_poly = np.zeros(N, dtype=np.float64)
                bias_poly[0] = -scale * b1[f]
                ct_out = rlwe_add_plain(ct_out, bias_poly, q, scale)
                # 解密
                m_dec = rlwe_decrypt(ct_out, s_key, q)
                conv_out[i, j, f] = -float(m_dec[0]) / (scale * scale)
    return np.maximum(conv_out, 0.0)  # ReLU


def encrypted_fc(ct_x, W, b, s_key, q, scale):
    """加密全连接层，返回解密后的输出（未做激活）。W: (out, in), b: (out,)。"""
    ct_outs = encrypted_linear_layer(ct_x, W, b, s_key, q, scale)
    outs = np.zeros(W.shape[0], dtype=np.float64)
    for o in range(W.shape[0]):
        m_dec = rlwe_decrypt(ct_outs[o], s_key, q)
        outs[o] = -float(m_dec[0]) / (scale * scale)
    return outs


def encrypted_cnn_forward(model, x_plain, s_key, q, scale, noise_sigma):
    """完整 CNN 加密推理。x_plain: (28, 28)。返回 (out_enc, out_plain)。"""
    W1 = model.conv1.weight.detach().numpy()
    b1 = model.conv1.bias.detach().numpy()
    W_fc1 = model.fc1.weight.detach().numpy()
    b_fc1 = model.fc1.bias.detach().numpy()
    W_fc2 = model.fc2.weight.detach().numpy()
    b_fc2 = model.fc2.bias.detach().numpy()

    N = len(s_key)

    # 明文前向（基准）
    xt = torch.from_numpy(x_plain.astype(np.float32)).unsqueeze(0).unsqueeze(0)
    with torch.no_grad():
        out_plain = model(xt).numpy()[0]

    # 加密卷积（输入 784 元素一次加密）
    x_flat = x_plain.flatten()
    ct_x = encrypt_vec(x_flat, s_key, q, scale, noise_sigma)
    h1 = encrypted_conv(ct_x, W1, b1, s_key, q, scale)  # (7,7,4), ReLU 已应用

    # 重新加密 h1（196 元素）
    # 注意：h1 形状 (7,7,4) 即 (i,j,f)，FC1 期望 (f,i,j) 顺序
    # 需 transpose(2,0,1) → (4,7,7) 后再 flatten，与 torch conv_t.view(1,-1) 一致
    h1_flat = h1.transpose(2, 0, 1).reshape(-1)
    ct_h1 = encrypt_vec(h1_flat, s_key, q, scale, noise_sigma)

    # 加密 FC1
    h2 = encrypted_fc(ct_h1, W_fc1, b_fc1, s_key, q, scale)
    h2 = np.maximum(h2, 0.0)  # ReLU

    # 重新加密 h2
    ct_h2 = encrypt_vec(h2, s_key, q, scale, noise_sigma)

    # 加密 FC2
    out_enc = encrypted_fc(ct_h2, W_fc2, b_fc2, s_key, q, scale)

    return out_enc, out_plain


# ===================== 训练与评估 =====================

def train_small_cnn(epochs=2, lr=0.01, n_train=20000):
    """训练小型 CNN。"""
    model = SmallCNN()
    optimizer = optim.Adam(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()
    train_dataset = datasets.MNIST(DATA_DIR, train=True, download=False,
                                   transform=transforms.Compose([transforms.ToTensor()]))
    subset = torch.utils.data.Subset(train_dataset, range(min(n_train, len(train_dataset))))
    train_loader = torch.utils.data.DataLoader(subset, batch_size=128, shuffle=True)
    model.train()
    for epoch in range(epochs):
        correct = 0
        total = 0
        running_loss = 0.0
        for data, target in train_loader:
            optimizer.zero_grad()
            output = model(data)
            loss = criterion(output, target)
            loss.backward()
            optimizer.step()
            pred = output.argmax(dim=1)
            correct += (pred == target).sum().item()
            total += target.size(0)
            running_loss += loss.item()
        acc = correct / total
        avg_loss = running_loss / len(train_loader)
        print(f"  Epoch {epoch+1}/{epochs}: train_acc={acc:.4f}, loss={avg_loss:.4f}")
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


# ===================== 自测 =====================

def self_test():
    """验证 encrypted_conv 解密结果与明文 conv 的相对误差在容限内。"""
    print("[自测] 验证 encrypted_conv 正确性...")
    np.random.seed(123)
    N = 1024
    q = 998244353
    scale = 2 ** 10
    noise_sigma = 1

    s_key = np.random.randint(-1, 2, size=N).astype(np.int64)
    x = np.random.rand(28, 28).astype(np.float32) * 0.5

    # 明文 conv
    model = SmallCNN()
    with torch.no_grad():
        xt = torch.from_numpy(x).unsqueeze(0).unsqueeze(0)
        h_plain = torch.relu(model.conv1(xt)).numpy()[0]  # (4, 7, 7)

    # 加密 conv
    x_flat = x.flatten()
    ct_x = encrypt_vec(x_flat, s_key, q, scale, noise_sigma)
    W1 = model.conv1.weight.detach().numpy()
    b1 = model.conv1.bias.detach().numpy()
    h_enc = encrypted_conv(ct_x, W1, b1, s_key, q, scale)  # (14, 14, 4)

    # 对比
    h_plain_rearranged = np.transpose(h_plain, (1, 2, 0))  # (14, 14, 4)
    rel_err = np.mean(np.abs(h_enc - h_plain_rearranged) / (np.abs(h_plain_rearranged) + 1e-6))
    max_abs_err = np.max(np.abs(h_enc - h_plain_rearranged))
    print(f"  平均相对误差: {rel_err:.6f}, 最大绝对误差: {max_abs_err:.6f}")
    assert rel_err < 0.5, f"自测失败: 平均相对误差 {rel_err} 超过容限"
    print("[自测] 通过 ✓")
    return True


# ===================== 主实验 =====================

def main():
    print("=" * 60)
    print("E14: 端到端 CNN 加密推理验证")
    print("=" * 60)

    # ---- 0. 自测 ----
    if not self_test():
        print("自测失败，退出")
        sys.exit(1)

    # ---- 1. 训练 CNN ----
    print("\n[1/5] 训练小型 CNN (Conv2d 1→4 stride=4 → FC 196→32→10)...")
    model = train_small_cnn(epochs=2, lr=0.01, n_train=20000)

    # ---- 2. 加载 MNIST 测试集 ----
    print("\n[2/5] 加载 MNIST 测试集...")
    loader, n_samples = load_mnist(num_samples=2000)
    print(f"  测试样本: {n_samples}")

    # ---- 3. 明文精度 ----
    print("\n[3/5] 明文精度评估...")
    plain_acc = evaluate_plain(model, loader)
    print(f"  明文精度: {plain_acc:.4f} ({plain_acc*100:.2f}%)")

    # ---- 4. CKKS 参数 ----
    Q = 998244353
    SCALE = 2 ** 10
    N = 1024
    print(f"\n  CKKS 参数: N={N}, Q={Q}, SCALE={SCALE}")

    # ---- 5. 预处理数据 ----
    all_data = []
    all_targets = []
    for data, target in loader:
        all_data.append(data.numpy())
        all_targets.append(target.numpy())
    all_data = np.concatenate(all_data, axis=0)
    all_targets = np.concatenate(all_targets, axis=0)

    n_test = 10

    # ---- 6. CKKS 加密推理（噪声 sigma sweep）----
    print(f"\n[4/5] CKKS 加密推理（{n_test} 样本 × 3 档噪声）...")
    noise_sigmas = [1, 4, 16]
    results_by_sigma = {}

    t0 = time.time()
    for sigma in noise_sigmas:
        correct = 0
        total = 0
        all_rel_errors = []

        for i in range(n_test):
            x = all_data[i].reshape(28, 28)
            s_key = np.random.randint(-1, 2, size=N).astype(np.int64)

            out_enc, out_plain = encrypted_cnn_forward(
                model, x, s_key, Q, SCALE, sigma
            )

            pred = int(np.argmax(out_enc))
            actual = int(all_targets[i])
            if pred == actual:
                correct += 1
            total += 1

            rel_err = np.mean(np.abs(out_enc - out_plain) / (np.abs(out_plain) + 1e-8))
            all_rel_errors.append(float(rel_err))

        acc = correct / total if total > 0 else 0.0
        avg_rel_error = float(np.mean(all_rel_errors)) if all_rel_errors else 0.0

        results_by_sigma[sigma] = {
            "accuracy": acc,
            "correct": correct,
            "total": total,
            "avg_rel_error": avg_rel_error,
        }

        print(f"  sigma={sigma:3d}: 精度={acc:.4f} ({acc*100:.1f}%), "
              f"avg_rel_error={avg_rel_error:.6f}")

    elapsed = time.time() - t0
    print(f"\n  总耗时: {elapsed:.1f}s")

    # ---- 7. 保存结果 ----
    output = {
        "experiment": "E14: 端到端 CNN 加密推理验证",
        "method": "E11 v4 coefficient encoding + IM2COL conv → GEMM",
        "cnn_architecture": "Conv2d(1,4,3,pad=1,stride=4) → ReLU → FC(196,32) → ReLU → FC(32,10)",
        "plain_accuracy": plain_acc,
        "n_test_samples": n_test,
        "N": N,
        "Q": Q,
        "SCALE": SCALE,
        "noise_sigmas": noise_sigmas,
        "results_by_sigma": results_by_sigma,
        "elapsed_seconds": elapsed,
    }

    json_path = os.path.join(OUT_DIR, "e14_cnn_e2e.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"\n  JSON: {json_path}")

    md_path = os.path.join(OUT_DIR, "e14_cnn_e2e.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# E14: 端到端 CNN 加密推理验证\n\n")
        f.write("## 方法\n\n")
        f.write("- **架构**: Conv2d(1, 4, 3, padding=1, stride=4) → ReLU → FC(196, 32) → ReLU → FC(32, 10)\n")
        f.write("- **卷积转 GEMM**: stride=4 直接下采样到 7×7，输出 7×7×4=196 个位置×滤波器组合\n")
        f.write("- **复用 E11 v4**: 分数 m_x + 整数 m_w + 无 rescale + Δ² 除法\n")
        f.write("- **散布位置权重多项式**: 每个 3×3 patch 覆盖的 9 个输入像素位置不同\n")
        f.write("- **溢出控制**: stride=4 使 FC1 输入=196，Δ²·196=196M < q/2=499M\n")
        f.write("- **ReLU 位置**: 解密域计算后重新加密（明文点态操作，不引入额外噪声）\n")
        f.write("- **参数**: N=1024, Q=998244353, SCALE=2^10\n\n")
        f.write("## 结果\n\n")
        f.write(f"- 明文精度: {plain_acc:.4f} ({plain_acc*100:.2f}%)\n")
        f.write(f"- 测试样本: {n_test}\n\n")
        f.write("| sigma | 精度 | avg_rel_error |\n")
        f.write("|-------|------|---------------|\n")
        for sigma in noise_sigmas:
            r = results_by_sigma[sigma]
            f.write(f"| {sigma} | {r['accuracy']:.4f} ({r['accuracy']*100:.1f}%) | {r['avg_rel_error']:.6f} |\n")
        f.write(f"\n耗时: {elapsed:.1f}s\n")
    print(f"  MD: {md_path}")

    print("\n[5/5] 完成 ✓")


if __name__ == "__main__":
    main()
