#!/usr/bin/env python3
"""
E12: CKKS 软件基线对比（Python RLWE + 系数编码同态点积）

目的：与 E11 FPGA 方案对比，展示软件实现的参数空间与精度权衡。

FPGA 约束（E11）：
- N=1024, Q=998244353, SCALE=4096
- 单素数模，硬件资源受限
- 3 层 MLP 784→64→32→10

软件优势：
- 更大的 N（2048/4096）→ 更高的精度和更深的网络
- 更大的 Q → 更低的噪声
- 更多的噪声重采样 → 更干净的信号

本脚本用**相同的 v4 方案**（分数 m_x + 整数 m_w + 无 rescale + 除以 Δ²），
但使用软件级参数，作为 FPGA 方案的基线对比。
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

# 复用 E11 的 v4 方案核心函数
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from exp_e11_ckks_e2e_real import (
    neg_conv, mod_center, rlwe_encrypt, rlwe_decrypt,
    rlwe_mul_plain, rlwe_add_plain, build_weight_poly,
    encrypted_linear_layer, estimate_r_hat, select_gear, GEARS,
    PlainMLP, load_mnist, train_model, evaluate_plain,
)


def ckks_inference_sw(model, x_plain, s_key, q, scale, noise_sigma):
    """软件版 CKKS 推理（与 E11 相同的 v4 方案，不同参数）。"""
    W1 = model.fc1.weight.detach().numpy()
    b1 = model.fc1.bias.detach().numpy()
    W2 = model.fc2.weight.detach().numpy()
    b2 = model.fc2.bias.detach().numpy()
    W3 = model.fc3.weight.detach().numpy()
    b3 = model.fc3.bias.detach().numpy()

    D = 784
    N = len(s_key)

    # 明文前向
    h1_p = np.maximum(x_plain @ W1.T + b1, 0.0)
    h2_p = np.maximum(h1_p @ W2.T + b2, 0.0)
    out_p = h2_p @ W3.T + b3

    # 编码 + 加密输入
    m_x = np.zeros(N, dtype=np.float64)
    m_x[:D] = x_plain
    e = np.random.randint(-noise_sigma, noise_sigma + 1, size=N).astype(np.int64)
    ct = rlwe_encrypt(m_x, s_key, e, q, scale)

    all_r_hats = []
    all_gears = []
    noise_growth = 1.0

    def _layer(ct_in, W, b, plain_ref):
        nonlocal noise_growth
        ct_outs = encrypted_linear_layer(ct_in, W, b, s_key, q, scale)
        outs = np.zeros(W.shape[0], dtype=np.float64)
        r_hats = []
        gears = []
        for o in range(W.shape[0]):
            m_dec = rlwe_decrypt(ct_outs[o], s_key, q)
            val = -float(m_dec[0]) / (scale * scale)
            outs[o] = val
            r_hats.append(estimate_r_hat(val, float(plain_ref[o])))
            gears.append(select_gear(r_hats[-1]))
        all_r_hats.extend(r_hats)
        all_gears.extend(gears)
        noise_growth *= float(np.mean([GEARS[g]["noise_factor"] for g in gears]) or 1.0)
        return outs

    h1 = _layer(ct, W1, b1, h1_p)
    h1 = np.maximum(h1, 0.0)

    m_h1 = np.zeros(N, dtype=np.float64)
    m_h1[:W1.shape[0]] = h1
    e2 = np.random.randint(-noise_sigma, noise_sigma + 1, size=N).astype(np.int64)
    ct = rlwe_encrypt(m_h1, s_key, e2, q, scale)

    h2 = _layer(ct, W2, b2, h2_p)
    h2 = np.maximum(h2, 0.0)

    m_h2 = np.zeros(N, dtype=np.float64)
    m_h2[:W2.shape[0]] = h2
    e3 = np.random.randint(-noise_sigma, noise_sigma + 1, size=N).astype(np.int64)
    ct = rlwe_encrypt(m_h2, s_key, e3, q, scale)

    out = _layer(ct, W3, b3, out_p)

    return out, all_r_hats, all_gears, noise_growth


def main():
    print("=" * 60)
    print("E12: CKKS 软件基线对比（Python RLWE + v4 方案）")
    print("=" * 60)

    # ---- 1. 加载数据 ----
    print("\n[1/4] 加载 MNIST...")
    loader, n_samples = load_mnist(num_samples=2000)
    print(f"  测试样本: {n_samples}")

    # ---- 2. 训练模型 ----
    print("\n[2/4] 训练明文 MLP (784→64→32→10, ReLU)...")
    model = PlainMLP(hidden1=64, hidden2=32)
    model = train_model(model, epochs=8, lr=0.01)
    plain_acc = evaluate_plain(model, loader)
    print(f"  明文精度: {plain_acc:.4f} ({plain_acc*100:.2f}%)")

    # ---- 3. 软件参数 sweep ----
    # 软件可以使用更大的 N 和 Q，展示参数空间
    param_sets = [
        # (name, Q, SCALE, N)
        ("SW-N1024-Q998M-S4096", 998244353, 2**12, 1024),   # 与 FPGA 相同参数
        ("SW-N2048-Q998M-S4096", 998244353, 2**12, 2048),   # N 翻倍
        ("SW-N2048-Q17592186175489-S2**16", 17592186175489, 2**16, 2048),  # 大 Q + 大 N
    ]

    all_data = []
    all_targets = []
    for data, target in loader:
        all_data.append(data.numpy())
        all_targets.append(target.numpy())
    all_data = np.concatenate(all_data, axis=0)
    all_targets = np.concatenate(all_targets, axis=0)

    n_test = min(50, len(all_data))
    noise_sigmas = [1, 4, 16, 64, 256]

    results = {}

    for name, Q, SCALE, N in param_sets:
        print(f"\n[3/4] 软件参数: {name}")
        print(f"  Q={Q}, SCALE={SCALE}, N={N}")

        t0 = time.time()
        sigma_results = {}

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

                s_key = np.random.randint(-1, 2, size=N).astype(np.int64)

                out_enc, r_hats, gears, noise_growth = ckks_inference_sw(
                    model, x, s_key, Q, SCALE, sigma
                )

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

            sigma_results[sigma] = {
                "accuracy": acc,
                "avg_rel_error": avg_rel_error,
                "avg_r_hat": avg_r_hat,
                "avg_noise_growth": avg_noise,
                "gear_distribution": gear_dist,
            }

            print(f"  sigma={sigma:4d}: 精度={acc:.4f} ({acc*100:.2f}%), "
                  f"avg_rel_error={avg_rel_error:.6f}, avg_r_hat={avg_r_hat:.6f}")

        elapsed = time.time() - t0
        results[name] = {
            "Q": Q,
            "SCALE": SCALE,
            "N": N,
            "sigma_results": sigma_results,
            "elapsed_seconds": elapsed,
        }
        print(f"  耗时: {elapsed:.1f}s")

    # ---- 4. 保存 ----
    print("\n[4/4] 保存结果...")
    output = {
        "experiment": "E12: CKKS 软件基线对比（Python RLWE + v4 方案）",
        "method": "same v4 scheme as E11 (fractional m_x + integer m_w + no rescale)",
        "plain_accuracy": plain_acc,
        "n_samples": n_samples,
        "param_sets": results,
    }

    json_path = os.path.join(OUT_DIR, "e12_sw_baseline.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"  JSON: {json_path}")

    md_path = os.path.join(OUT_DIR, "e12_sw_baseline.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# E12: CKKS 软件基线对比\n\n")
        f.write("## 方法\n\n")
        f.write("与 E11 FPGA 方案相同的 v4 方案（分数 m_x + 整数 m_w + 无 rescale + 除以 Δ²），")
        f.write("但使用软件级参数（更大 N / 更大 Q），展示参数空间与精度权衡。\n\n")
        f.write("## 参数\n\n")
        f.write(f"- 明文精度: {plain_acc:.4f}\n")
        f.write("- 噪声 sweep: sigma = [1, 4, 16, 64, 256]\n")
        f.write("- 测试样本: 50\n\n")
        f.write("## 结果\n\n")
        for name, r in results.items():
            f.write(f"### {name} (Q={r['Q']}, SCALE={r['SCALE']}, N={r['N']})\n\n")
            f.write("| sigma | 精度 | avg_rel_error | avg_r_hat |\n")
            f.write("|-------|------|---------------|----------|\n")
            for sigma in noise_sigmas:
                sr = r["sigma_results"][sigma]
                f.write(f"| {sigma} | {sr['accuracy']:.4f} ({sr['accuracy']*100:.2f}%) | "
                        f"{sr['avg_rel_error']:.6f} | {sr['avg_r_hat']:.6f} |\n")
            f.write(f"\n耗时: {r['elapsed_seconds']:.1f}s\n\n")

    print(f"  MD: {md_path}")
    print("\n完成 ✓")


if __name__ == "__main__":
    main()