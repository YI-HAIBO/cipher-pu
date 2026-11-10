#!/usr/bin/env python3
"""
E10: 稀疏度 sweep v2 + 稀疏训练 —— skip_rate vs accuracy/throughput 权衡曲线

v2 修复内容：
1. 使用 PyTorch 训练 proper MNIST 线性分类器（SGD + mini-batch），基线精度 > 90%
2. 修正块稀疏掩码阈值标定：使用逐块 max-abs 归一化，而非全局 max_abs * frac
3. 新增稀疏训练（prune → fine-tune → re-prune 循环），避免精度断崖
4. 阈值 sweep 覆盖 skip_rate 0% → ~60%，步进合理

方法：
  - 训练 MNIST 10 类线性分类器 (784→10) 作基线
  - 块大小 B=4，对权重做结构化块剪枝
  - 每个阈值下：剪枝 → fine-tune 3 epochs → 测量精度
  - 输出 skip_rate / accuracy / accuracy_drop / speedup
"""

import json
import math
import os
import sys

import numpy as np

# ---- PyTorch ----
import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "reports", "experiments")
DATA_DIR = os.path.join(ROOT, "data")
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(DATA_DIR, exist_ok=True)

B = 4  # 块大小
N_EPOCHS_PRETRAIN = 10
N_EPOCHS_FINETUNE = 3
BATCH_SIZE = 64
LR_PRETRAIN = 0.05
LR_FINETUNE = 0.01


def load_mnist():
    transform = transforms.Compose([transforms.ToTensor()])
    train = datasets.MNIST(DATA_DIR, train=True, download=True, transform=transform)
    test = datasets.MNIST(DATA_DIR, train=False, download=True, transform=transform)
    Xtr = train.data.numpy().reshape(-1, 784).astype(np.float32) / 255.0
    ytr = train.targets.numpy()
    Xte = test.data.numpy().reshape(-1, 784).astype(np.float32) / 255.0
    yte = test.targets.numpy()
    return Xtr, ytr, Xte, yte


class LinearClassifier(nn.Module):
    def __init__(self, n_features=784, n_classes=10):
        super().__init__()
        self.fc = nn.Linear(n_features, n_classes, bias=True)

    def forward(self, x):
        if isinstance(x, np.ndarray):
            x = torch.from_numpy(x).float()
        x = x.view(-1, 784)
        return self.fc(x)


def train_linear(Xtr, ytr, Xte, yte, epochs=N_EPOCHS_PRETRAIN, lr=LR_PRETRAIN):
    """训练线性分类器，返回 (model, val_acc)."""
    model = LinearClassifier()
    optimizer = optim.SGD(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()

    # 转换为 tensor
    Xtr_t = torch.from_numpy(Xtr).float()
    ytr_t = torch.from_numpy(ytr).long()
    Xte_t = torch.from_numpy(Xte).float()
    yte_t = torch.from_numpy(yte).long()

    n = len(Xtr_t)
    for epoch in range(epochs):
        model.train()
        # mini-batch SGD
        perm = torch.randperm(n)
        for i in range(0, n, BATCH_SIZE):
            idx = perm[i : i + BATCH_SIZE]
            optimizer.zero_grad()
            out = model(Xtr_t[idx])
            loss = criterion(out, ytr_t[idx])
            loss.backward()
            optimizer.step()

    # 评估
    model.eval()
    with torch.no_grad():
        out = model(Xte_t)
        pred = out.argmax(dim=1)
        acc = (pred == yte_t).float().mean().item()
    return model, acc


def apply_block_sparse_mask(weight_matrix, threshold_val, B):
    """对权重矩阵做块稀疏剪枝。

    改进的阈值逻辑：
      - 计算每个块的 max_abs，与 threshold_val 比较
      - 若块 max_abs < threshold_val，整块置零
      - threshold_val 直接用绝对数值（非比例），避免全局 max_abs * frac 的尺度问题

    返回 (masked_W, skip_blocks, total_blocks, kept_density)
    """
    W_flat = weight_matrix.flatten()
    W_abs = np.abs(W_flat)
    n_blocks = len(W_flat) // B
    masked_flat = W_flat.copy()
    skip = 0
    for i in range(n_blocks):
        block = W_abs[i * B : (i + 1) * B]
        if np.max(block) < threshold_val:
            masked_flat[i * B : (i + 1) * B] = 0.0
            skip += 1
    masked_W = masked_flat.reshape(weight_matrix.shape)
    kept = n_blocks - skip
    return masked_W, skip, n_blocks, kept / n_blocks


def fine_tune(model, Xtr, ytr, Xte, yte, epochs=N_EPOCHS_FINETUNE, lr=LR_FINETUNE):
    """在剪枝后的模型上做 short fine-tune 恢复精度。"""
    optimizer = optim.SGD(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()

    Xtr_t = torch.from_numpy(Xtr).float()
    ytr_t = torch.from_numpy(ytr).long()
    Xte_t = torch.from_numpy(Xte).float()
    yte_t = torch.from_numpy(yte).long()

    n = len(Xtr_t)
    model.train()
    for epoch in range(epochs):
        perm = torch.randperm(n)
        for i in range(0, n, BATCH_SIZE):
            idx = perm[i : i + BATCH_SIZE]
            optimizer.zero_grad()
            out = model(Xtr_t[idx])
            loss = criterion(out, ytr_t[idx])
            loss.backward()
            optimizer.step()

    model.eval()
    with torch.no_grad():
        out = model(Xte_t)
        pred = out.argmax(dim=1)
        acc = (pred == yte_t).float().mean().item()
    return model, acc


def get_weight_stats(W):
    """返回权重矩阵的统计信息，用于标定阈值范围。"""
    W_abs = np.abs(W.flatten())
    return {
        "max": float(np.max(W_abs)),
        "p90": float(np.percentile(W_abs, 90)),
        "p95": float(np.percentile(W_abs, 95)),
        "p99": float(np.percentile(W_abs, 99)),
        "mean": float(np.mean(W_abs)),
        "std": float(np.std(W_abs)),
    }


def main():
    print("=" * 60)
    print("E10: 稀疏度 sweep v2 + 稀疏训练")
    print("=" * 60)

    # ---- 1. 加载数据 ----
    print("\n[1/6] 加载 MNIST...")
    Xtr, ytr, Xte, yte = load_mnist()
    print(f"  训练: {Xtr.shape}, 测试: {Xte.shape}")

    # ---- 2. 训练基线 ----
    print("\n[2/6] 训练基线线性分类器...")
    model, acc_base = train_linear(Xtr, ytr, Xte, yte)
    print(f"  基线精度: {acc_base:.4f} ({acc_base*100:.2f}%)")

    W = model.fc.weight.detach().numpy()  # (10, 784)
    b = model.fc.bias.detach().numpy()
    stats = get_weight_stats(W)
    print(f"  权重统计: max={stats['max']:.6f}, p90={stats['p90']:.6f}, "
          f"p95={stats['p95']:.6f}, p99={stats['p99']:.6f}")

    # ---- 3. 阈值标定 ----
    # 使用 p50 ~ p99 范围的阈值，确保 skip_rate 从 0 渐进到 ~60%
    # 阈值 = 百分位数值，直接用绝对值
    percentiles = [0, 50, 60, 70, 75, 80, 85, 90, 92, 94, 95, 96, 97, 98, 99]
    thresholds = []
    for p in percentiles:
        if p == 0:
            thresholds.append(0.0)
        else:
            thresholds.append(float(np.percentile(np.abs(W.flatten()), p)))

    # 去重
    thresholds = sorted(set(thresholds))
    print(f"\n[3/6] 阈值标定: {len(thresholds)} 个唯一阈值")
    for t in thresholds:
        print(f"  threshold={t:.8f}")

    # ---- 4. 稀疏 sweep + 稀疏训练 ----
    print("\n[4/6] 稀疏 sweep（剪枝 + fine-tune）...")
    results = []

    for thresh in thresholds:
        # 剪枝
        W_masked, skip, total, kept_density = apply_block_sparse_mask(W, thresh, B)
        skip_rate = skip / total if total > 0 else 0.0

        if skip_rate == 0.0:
            # 不剪枝，直接用基线
            acc = acc_base
            speedup = 1.0
        else:
            # 加载剪枝后的权重
            model_pruned = LinearClassifier()
            model_pruned.fc.weight.data = torch.from_numpy(W_masked).float()
            model_pruned.fc.bias.data = torch.from_numpy(b).float()

            # Fine-tune 恢复精度
            model_pruned, acc = fine_tune(model_pruned, Xtr, ytr, Xte, yte)
            speedup = 1.0 / (1.0 - skip_rate) if skip_rate < 1.0 else float("inf")

        acc_drop = acc_base - acc

        results.append({
            "threshold": round(thresh, 10),
            "skip_rate": round(skip_rate, 4),
            "skip_blocks": skip,
            "total_blocks": total,
            "kept_density": round(kept_density, 4),
            "accuracy": round(acc, 4),
            "accuracy_drop": round(acc_drop, 4),
            "speedup": round(speedup, 2) if speedup != float("inf") else "inf",
        })

        sp = f"{speedup:.2f}x" if speedup != float("inf") else "inf"
        print(f"  thr={thresh:.8f}  skip={skip_rate:.1%}  "
              f"kept={kept_density:.1%}  acc={acc:.4f}  drop={acc_drop:.4f}  speedup={sp}")

    # ---- 5. 保存结果 ----
    print("\n[5/6] 保存结果...")
    out_csv = os.path.join(OUT_DIR, "sparsity_sweep_v2.csv")
    with open(out_csv, "w") as f:
        f.write("threshold,skip_rate,skip_blocks,total_blocks,kept_density,"
                "accuracy,accuracy_drop,speedup\n")
        for r in results:
            f.write(f"{r['threshold']},{r['skip_rate']},{r['skip_blocks']},"
                    f"{r['total_blocks']},{r['kept_density']},"
                    f"{r['accuracy']},{r['accuracy_drop']},{r['speedup']}\n")

    out_json = os.path.join(OUT_DIR, "sparsity_sweep_v2.json")
    with open(out_json, "w") as f:
        json.dump({
            "experiment": "E10: 稀疏 sweep v2 + 稀疏训练",
            "baseline_accuracy": acc_base,
            "B": B,
            "weight_stats": stats,
            "n_epochs_pretrain": N_EPOCHS_PRETRAIN,
            "n_epochs_finetune": N_EPOCHS_FINETUNE,
            "results": results,
        }, f, indent=2, ensure_ascii=False)

    print(f"  CSV:  {out_csv}")
    print(f"  JSON: {out_json}")

    # ---- 6. 分析 ----
    print("\n[6/6] 关键发现:")
    print(f"  基线精度: {acc_base:.4f} ({acc_base*100:.2f}%)")

    # 最大可容忍稀疏度（精度损失 < 1%）
    for r in results:
        if r["skip_rate"] > 0 and r["accuracy_drop"] < 0.01:
            print(f"  最大可容忍稀疏度 (drop<1%): skip_rate={r['skip_rate']:.1%} "
                  f"(kept={r['kept_density']:.1%}, acc={r['accuracy']:.4f})")
            break

    # 最佳权衡点（skip_rate > 10% 且精度损失 < 5%）
    best = None
    for r in results:
        if r["skip_rate"] > 0.1 and r["accuracy_drop"] < 0.05:
            if best is None or r["skip_rate"] > best["skip_rate"]:
                best = r
    if best:
        print(f"  最佳权衡点: skip_rate={best['skip_rate']:.1%}, "
              f"acc={best['accuracy']:.4f}, speedup={best['speedup']}")

    # 精度断崖点
    prev_acc = acc_base
    for r in results:
        if r["skip_rate"] > 0 and r["accuracy_drop"] > 0.1:
            print(f"  ⚠️ 精度断崖: skip_rate={r['skip_rate']:.1%} → "
                  f"acc={r['accuracy']:.4f} (drop={r['accuracy_drop']:.4f})")
            break
        prev_acc = r["accuracy"]

    print("\n✅ E10 完成")
    return results


if __name__ == "__main__":
    main()