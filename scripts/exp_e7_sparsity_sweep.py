#!/usr/bin/env python3
"""
E7: 稀疏度 sweep —— skip_rate vs accuracy/throughput 权衡曲线

方法：
  - 用块稀疏（Block-Sparse）模型对 MNIST 权重矩阵做结构化剪枝
  - 阈值 sweep → skip_rate 从 0% 到 ~50%
  - 用简单线性分类器（MNIST 10 类）评估剪枝后精度损失
  - 输出 skip_rate / accuracy / 相对加速比 三列数据

加速比假设：硬件跳过整块计算，加速比 = 1 / (1 - skip_rate)
"""
import numpy as np
import json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "reports", "experiments")
os.makedirs(OUT_DIR, exist_ok=True)

B = 4               # 块大小

# ---- 1. 加载 MNIST ----
print("=== E7: 稀疏度 sweep ===")
try:
    from torchvision import datasets, transforms
    transform = transforms.Compose([transforms.ToTensor()])
    train = datasets.MNIST(ROOT + "/data", train=True, download=True, transform=transform)
    test = datasets.MNIST(ROOT + "/data", train=False, download=True, transform=transform)
    Xtr = train.data.numpy().reshape(-1, 784).astype(np.float32) / 255.0
    ytr = train.targets.numpy()
    Xte = test.data.numpy().reshape(-1, 784).astype(np.float32) / 255.0
    yte = test.targets.numpy()
    print(f"  MNIST: train={Xtr.shape}, test={Xte.shape}")
except Exception as e:
    print(f"  WARN: MNIST 加载失败 ({e})，使用随机数据模拟")
    rng = np.random.default_rng(42)
    Xtr = rng.random((1000, 784)).astype(np.float32)
    ytr = rng.integers(0, 10, 1000)
    Xte = rng.random((200, 784)).astype(np.float32)
    yte = rng.integers(0, 10, 200)

# ---- 2. 训练基线线性分类器 ----
rng = np.random.default_rng(42)
n_features = Xtr.shape[1]
n_classes = 10
W = rng.standard_normal((n_features, n_classes)) * 0.01
b = np.zeros(n_classes)

for epoch in range(10):
    logits = Xtr @ W + b
    logits -= np.max(logits, axis=1, keepdims=True)
    exp_logits = np.exp(logits)
    probs = exp_logits / np.sum(exp_logits, axis=1, keepdims=True)
    y_true = np.zeros((len(ytr), n_classes))
    y_true[np.arange(len(ytr)), ytr] = 1
    grad_logits = probs - y_true
    grad_W = Xtr.T @ grad_logits / len(ytr)
    grad_b = np.sum(grad_logits, axis=0) / len(ytr)
    W -= 0.1 * grad_W
    b -= 0.1 * grad_b

def predict(X, W, b):
    return np.argmax(X @ W + b, axis=1)

def accuracy(X, y, W, b):
    return np.mean(predict(X, W, b) == y)

acc_base = accuracy(Xte, yte, W, b)
print(f"  基线精度 (无稀疏): {acc_base:.4f}")

# ---- 3. 块稀疏掩码 ----
def block_sparse_mask(weight_matrix, threshold_frac, B):
    """对权重矩阵的展平表示做块稀疏剪枝。
    threshold_frac: 阈值 = max_abs_weight * threshold_frac
    返回 (masked_W, skip_blocks, total_blocks)
    """
    W_flat = weight_matrix.flatten()
    W_abs = np.abs(W_flat)
    max_abs = np.max(W_abs)
    threshold = max_abs * threshold_frac
    n_blocks = len(W_flat) // B
    masked_flat = W_flat.copy()
    skip = 0
    for i in range(n_blocks):
        block = W_abs[i*B:(i+1)*B]
        if np.max(block) < threshold:
            masked_flat[i*B:(i+1)*B] = 0
            skip += 1
    masked_W = masked_flat.reshape(weight_matrix.shape)
    return masked_W, skip, n_blocks

# ---- 4. 阈值 sweep ----
# 阈值相对于权重最大绝对值的比例
fracs = [0.0, 0.02, 0.05, 0.08, 0.10, 0.15, 0.20, 0.25, 0.30]
results = []

for frac in fracs:
    W_masked, skip, total = block_sparse_mask(W, frac, B)
    acc = accuracy(Xte, yte, W_masked, b)
    skip_rate = skip / total if total > 0 else 0.0
    speedup = 1.0 / (1.0 - skip_rate) if skip_rate < 1.0 else float('inf')

    results.append({
        "threshold_frac": frac,
        "skip_rate": round(skip_rate, 4),
        "skip_blocks": skip,
        "total_blocks": total,
        "accuracy": round(acc, 4),
        "accuracy_drop": round(acc_base - acc, 4),
        "speedup": round(speedup, 2) if speedup != float('inf') else "inf"
    })
    print(f"  frac={frac:.2f}  skip_rate={skip_rate:.4f}  acc={acc:.4f}  "
          f"drop={acc_base-acc:.4f}  speedup={speedup:.1f}x"
          if speedup != float('inf') else
          f"  frac={frac:.2f}  skip_rate={skip_rate:.4f}  acc={acc:.4f}  "
          f"drop={acc_base-acc:.4f}  speedup=inf")

# ---- 5. 保存结果 ----
out_csv = os.path.join(OUT_DIR, "sparsity_sweep.csv")
with open(out_csv, "w") as f:
    f.write("threshold_frac,skip_rate,skip_blocks,total_blocks,accuracy,accuracy_drop,speedup\n")
    for r in results:
        f.write(f"{r['threshold_frac']},{r['skip_rate']},{r['skip_blocks']},"
                f"{r['total_blocks']},{r['accuracy']},{r['accuracy_drop']},{r['speedup']}\n")

out_json = os.path.join(OUT_DIR, "sparsity_sweep.json")
with open(out_json, "w") as f:
    json.dump({
        "baseline_accuracy": acc_base,
        "B": B,
        "weight_matrix_shape": list(W.shape),
        "results": results
    }, f, indent=2)

print(f"\n  结果已保存: {out_csv}")
print(f"  结果已保存: {out_json}")

# ---- 6. 关键发现 ----
print("\n=== 关键发现 ===")
print(f"  基线精度: {acc_base:.4f}")
for r in results:
    if r["skip_rate"] > 0 and r["accuracy_drop"] < 0.01:
        print(f"  最大可容忍稀疏度（精度损失 < 1%）: skip_rate={r['skip_rate']:.1%} (frac={r['threshold_frac']:.2f})")
        break
for r in results:
    if r["skip_rate"] > 0.1 and r["skip_rate"] < 0.5:
        print(f"  skip_rate={r['skip_rate']:.1%}: 精度={r['accuracy']:.4f}, 加速比={r['speedup']}")