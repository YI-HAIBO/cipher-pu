#!/usr/bin/env python3
"""
E22: 统计可靠性实验（多 seed + 置信区间）— v2 方法学修正版

对 E2/E14/E19 关键实验做 5 次不同 seed 重复运行，计算 95% 置信区间。

v2 方法学修正（相对 v1）:
1. 「明文精度」v1 取的是 train_model 返回的 best_train_acc（训练集精度），
   与加密精度（测试集子集）不可比。v2 改为**真实测试集全集精度**。
2. v1 加密精度在随机测试子集上算，与明文精度不同样本集。v2 改为**配对比较**：
   每个 seed 固定 n_test 个测试样本索引，在同一批样本上同时算明文精度与
   加密精度，并可算**配对差值**（精度损失），方差远小于独立 CI。
3. CNN v1 用 n_test=6（精度为 1/6 倍数），CI 宽度达 0.25 不可发表。
   v2 统一 n_test=20。
4. 95% CI 截断到 [0,1]（精度是有界比例，t 区间在小样本高估时上界会越过 1.0）。
5. 密钥/噪声全部走独立确定性 RNG，结果可复现。

依赖: exp_e11_ckks_e2e_real 的 RLWE 实现
"""

import json
import os
import sys
import numpy as np
import torch
import torch.nn as nn
import time
from datetime import datetime
from torchvision import datasets, transforms
from scipy import stats

# ── 路径设置 ──
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
os.chdir(ROOT_DIR)

from exp_e11_ckks_e2e_real import (
    rlwe_encrypt, rlwe_decrypt, rlwe_mul_plain, rlwe_add_plain,
    build_weight_poly, encrypted_linear_layer,
)

# ── 参数 ──
N = 1024
Q = 998244353
SCALE = 2 ** 10  # 1024
NOISE_SIGMAS = [1, 4, 16]
N_SEEDS = 5
N_TEST = 20  # 每 seed 配对子集样本数（所有配置统一）
CONFIDENCE = 0.95

# 测试配置
CONFIGS = [
    {'name': 'MLP-2L', 'dims': [784, 128, 10], 'n_layers': 2},
    {'name': 'MLP-5L', 'dims': [784, 256, 128, 64, 32, 10], 'n_layers': 5},
    {'name': 'CNN', 'dims': 'cnn', 'n_layers': 3},  # Conv→ReLU→FC→ReLU→FC
]


class MLP(nn.Module):
    def __init__(self, dims):
        super().__init__()
        layers = []
        for i in range(len(dims) - 1):
            layers.append(nn.Linear(dims[i], dims[i + 1]))
            if i < len(dims) - 2:
                layers.append(nn.ReLU())
        self.net = nn.Sequential(*layers)

    def forward(self, x):
        return self.net(x)


class SmallCNN(nn.Module):
    """E14 的 CNN 架构: Conv(1,4,3,padding=1,stride=4) → ReLU → FC(196,32) → ReLU → FC(32,10)"""

    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 4, 3, padding=1, stride=4)
        self.fc1 = nn.Linear(196, 32)
        self.fc2 = nn.Linear(32, 10)

    def forward(self, x):
        x = torch.relu(self.conv1(x))
        x = x.view(x.size(0), -1)
        x = torch.relu(self.fc1(x))
        return self.fc2(x)


def train_model(model, train_loader, epochs=3, lr=0.001, seed=42):
    """训练模型，返回 (训练精度序列, 最终测试无) —— 精度用全集评估函数单独算"""
    torch.manual_seed(seed)
    np.random.seed(seed)

    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=lr, weight_decay=1e-5)
    scheduler = torch.optim.lr_scheduler.StepLR(optimizer, step_size=2, gamma=0.5)

    model.train()
    train_accs = []

    for epoch in range(epochs):
        total = correct = 0
        for batch_x, batch_y in train_loader:
            if isinstance(model, SmallCNN):
                batch_x = batch_x.view(batch_x.size(0), 1, 28, 28)
            else:
                batch_x = batch_x.view(batch_x.size(0), -1)

            optimizer.zero_grad()
            output = model(batch_x)
            loss = criterion(output, batch_y)
            loss.backward()
            optimizer.step()

            _, predicted = output.max(1)
            total += batch_y.size(0)
            correct += predicted.eq(batch_y).sum().item()

        scheduler.step()
        train_accs.append(correct / total)

    model.eval()
    return train_accs


def evaluate_plain_full(model, test_data, batch_size=256):
    """全集测试精度（真正的明文精度）。

    MNIST 不支持切片，逐样本取数据后用 TensorDataset 组批。
    """
    model.eval()
    correct = total = 0
    with torch.no_grad():
        for i in range(0, len(test_data), batch_size):
            idxs = range(i, min(i + batch_size, len(test_data)))
            imgs, labs = [], []
            for k in idxs:
                im, lb = test_data[k]
                imgs.append(im)
                labs.append(int(lb))
            xb = torch.stack(imgs)
            yb = torch.tensor(labs)
            if isinstance(model, SmallCNN):
                xb = xb.view(xb.size(0), 1, 28, 28)
            else:
                xb = xb.view(xb.size(0), -1)
            pred = model(xb).argmax(1)
            correct += (pred == yb).sum().item()
            total += yb.size(0)
    return correct / total


def single_plain_forward(model, x_flat):
    """单样本明文前向，返回 logits"""
    with torch.no_grad():
        if isinstance(model, SmallCNN):
            xt = torch.from_numpy(x_flat.reshape(1, 1, 28, 28)).float()
        else:
            xt = torch.from_numpy(x_flat).float().unsqueeze(0)
        return model(xt).numpy()[0]


def extract_weights(model):
    """提取权重"""
    weights = []
    for module in model.modules():
        if isinstance(module, nn.Linear):
            W = module.weight.detach().numpy()
            b = module.bias.detach().numpy()
            weights.append({'W': W, 'b': b})
    if isinstance(model, SmallCNN):
        W_conv = model.conv1.weight.detach().numpy()
        b_conv = model.conv1.bias.detach().numpy()
        weights.insert(0, {'W_conv': W_conv, 'b_conv': b_conv, 'is_conv': True})
    return weights


def generate_noise(sigma, N):
    e = np.random.randint(-sigma, sigma + 1, size=N).astype(np.int64)
    return e


def build_weight_poly_scattered(msg_indices, weights, N, scale):
    """散布位置权重多项式（卷积用，E11 v4 约定）。

    负循环卷积 c_0 = -Δ·Σ x_{msg_idx}·w，因此权重 w 对 msg_idx>=1 放在
    m_w[N-msg_idx]，对 msg_idx==0 放在 m_w[0] 并取负。stride=4 时 3x3 邻居
    在展平向量中不连续（如 (0,0) 位置为 0,1,2,28,29,30,56,57,58），
    不能当成连续窗口处理。
    """
    m_w = np.zeros(N, dtype=np.float64)
    for msg_idx, w in zip(msg_indices, weights):
        val = round(scale * w)
        if msg_idx == 0:
            m_w[0] = -val
        else:
            m_w[N - msg_idx] = val
    return m_w


def encrypted_inference_mlp(model, x_plain, weights, s_key, q, scale, noise_sigma):
    """MLP 加密推理"""
    m_x = np.zeros(N, dtype=np.float64)
    m_x[:len(x_plain)] = x_plain
    e = generate_noise(noise_sigma, N)
    ct = rlwe_encrypt(m_x, s_key, e, q, scale)

    for layer_idx, layer in enumerate(weights):
        W = layer['W']
        b = layer['b']
        ct_outputs = encrypted_linear_layer(ct, W, b, s_key, q, scale)

        out_dim = W.shape[0]
        h_encrypted = np.zeros(out_dim, dtype=np.float64)
        for j in range(out_dim):
            m_dec = rlwe_decrypt(ct_outputs[j], s_key, q)
            h_encrypted[j] = -float(m_dec[0]) / (scale * scale)

        h_encrypted = np.maximum(h_encrypted, 0.0)

        if layer_idx < len(weights) - 1:
            m_h = np.zeros(N, dtype=np.float64)
            m_h[:len(h_encrypted)] = h_encrypted
            e = generate_noise(noise_sigma, N)
            ct = rlwe_encrypt(m_h, s_key, e, q, scale)

    return h_encrypted


def encrypted_inference_cnn(model, x_plain, weights, s_key, q, scale, noise_sigma):
    """CNN 加密推理 (E14 方案)"""
    W_conv = weights[0]['W_conv']  # (4, 1, 3, 3)
    b_conv = weights[0]['b_conv']  # (4,)
    n_filters = W_conv.shape[0]

    x_flat = x_plain.flatten()
    m_x = np.zeros(N, dtype=np.float64)
    m_x[:len(x_flat)] = x_flat
    e = generate_noise(noise_sigma, N)
    ct = rlwe_encrypt(m_x, s_key, e, q, scale)

    h1 = np.zeros((7, 7, n_filters), dtype=np.float64)

    for f in range(n_filters):
        w_f = W_conv[f]  # (1, 3, 3)
        for i in range(7):
            for j in range(7):
                msg_indices = []
                fw = []
                for ki in range(3):
                    for kj in range(3):
                        ii = 4 * i + ki - 1
                        jj = 4 * j + kj - 1
                        if 0 <= ii < 28 and 0 <= jj < 28:
                            msg_indices.append(ii * 28 + jj)
                            fw.append(float(w_f[0, ki, kj]))

                m_w = build_weight_poly_scattered(msg_indices, fw, N, scale)
                ct_out = rlwe_mul_plain(ct, m_w, q)
                bias_poly = np.zeros(N, dtype=np.float64)
                bias_poly[0] = -scale * b_conv[f]
                ct_out = rlwe_add_plain(ct_out, bias_poly, q, scale)
                m_dec = rlwe_decrypt(ct_out, s_key, q)
                h1[i, j, f] = -float(m_dec[0]) / (scale * scale)

    h1 = np.maximum(h1, 0.0)

    W_fc1 = weights[1]['W']
    b_fc1 = weights[1]['b']
    h1_flat = h1.transpose(2, 0, 1).reshape(-1)  # (f, i, j) 顺序

    m_h1 = np.zeros(N, dtype=np.float64)
    m_h1[:len(h1_flat)] = h1_flat
    e = generate_noise(noise_sigma, N)
    ct_h1 = rlwe_encrypt(m_h1, s_key, e, q, scale)

    ct_outs = encrypted_linear_layer(ct_h1, W_fc1, b_fc1, s_key, q, scale)
    h2 = np.zeros(W_fc1.shape[0], dtype=np.float64)
    for j in range(W_fc1.shape[0]):
        m_dec = rlwe_decrypt(ct_outs[j], s_key, q)
        h2[j] = -float(m_dec[0]) / (scale * scale)

    h2 = np.maximum(h2, 0.0)

    W_fc2 = weights[2]['W']
    b_fc2 = weights[2]['b']

    m_h2 = np.zeros(N, dtype=np.float64)
    m_h2[:len(h2)] = h2
    e = generate_noise(noise_sigma, N)
    ct_h2 = rlwe_encrypt(m_h2, s_key, e, q, scale)

    ct_outs = encrypted_linear_layer(ct_h2, W_fc2, b_fc2, s_key, q, scale)
    out = np.zeros(W_fc2.shape[0], dtype=np.float64)
    for j in range(W_fc2.shape[0]):
        m_dec = rlwe_decrypt(ct_outs[j], s_key, q)
        out[j] = -float(m_dec[0]) / (scale * scale)

    return out


def run_experiment(config, seeds, train_loader, test_data, noise_sigmas):
    """对一个配置运行多 seed 实验（v2: 配对比较）"""
    n_test = config.get('n_test', N_TEST)
    results = {
        'config_name': config['name'],
        'n_test': n_test,
        'seeds': [],
        'plain_accuracy_full': [],      # 全集测试精度
        'plain_accuracy_subset': [],    # 配对子集明文精度
        'encrypted_results': {},        # sigma -> [per-seed acc]
        'accuracy_loss': {},            # sigma -> [per-seed (plain_subset - enc)]
        'seed_detail': [],              # 每 seed 的样本索引与逐条对错
    }

    for seed in seeds:
        print(f"  Seed {seed}: 训练 {config['name']}...", flush=True)

        model = SmallCNN() if config['dims'] == 'cnn' else MLP(config['dims'])
        train_accs = train_model(model, train_loader, epochs=3, seed=seed)

        # ① 全集测试精度
        plain_full = evaluate_plain_full(model, test_data)
        results['plain_accuracy_full'].append(plain_full)

        # ② 固定配对子集索引（确定性）
        rng_idx = np.random.default_rng(20261023 + seed * 7919)
        subset_idxs = np.sort(rng_idx.choice(len(test_data), n_test, replace=False))

        weights = extract_weights(model)

        plain_sub_correct = 0
        enc_correct = {s: 0 for s in noise_sigmas}
        detail = {'seed': seed, 'train_acc_last': float(train_accs[-1]),
                  'plain_full': float(plain_full),
                  'subset_idxs': [int(x) for x in subset_idxs],
                  'samples': []}

        t_sample0 = None
        for k, si in enumerate(subset_idxs):
            x_plain, actual = test_data[int(si)]
            x_flat = (x_plain.view(-1).numpy() if not isinstance(x_plain, np.ndarray)
                      else x_plain.reshape(-1)).astype(np.float64)
            actual = int(actual)

            plain_out = single_plain_forward(model, x_flat)
            plain_pred = int(np.argmax(plain_out))
            if plain_pred == actual:
                plain_sub_correct += 1

            # 密钥：每样本一个，跨 sigma 共享（隔离噪声尺度单一变量）
            rng_key = np.random.default_rng(9901 + seed * 100003 + int(si))
            s_key = rng_key.integers(-1, 2, size=N).astype(np.int64)

            sample_detail = {'idx': int(si), 'actual': actual,
                             'plain_pred': plain_pred, 'plain_ok': bool(plain_pred == actual)}

            for sigma in noise_sigmas:
                # 噪声：独立确定性流
                np.random.seed((99991 + seed * 2654435 + int(si) * 40503 + sigma * 9973) & 0x7FFFFFFF)
                if t_sample0 is None:
                    t_sample0 = time.time()
                if isinstance(model, SmallCNN):
                    enc_out = encrypted_inference_cnn(model, x_flat.reshape(28, 28),
                                                       weights, s_key, Q, SCALE, sigma)
                else:
                    enc_out = encrypted_inference_mlp(model, x_flat, weights,
                                                       s_key, Q, SCALE, sigma)
                enc_pred = int(np.argmax(enc_out))
                sample_detail[f'sigma_{sigma}_pred'] = enc_pred
                sample_detail[f'sigma_{sigma}_ok'] = bool(enc_pred == actual)
                if enc_pred == actual:
                    enc_correct[sigma] += 1

            detail['samples'].append(sample_detail)

            if k < 3 or (config['dims'] == 'cnn' and k % 5 == 4):
                rate = (time.time() - t_sample0) / (k + 1)
                print(f"    seed={seed} sample {k}/{n_test} idx={int(si)} "
                      f"plain_ok={sample_detail['plain_ok']} rate={rate:.2f}s/样本", flush=True)

        plain_sub = plain_sub_correct / n_test
        results['plain_accuracy_subset'].append(plain_sub)
        for sigma in noise_sigmas:
            key = f'sigma_{sigma}'
            results['encrypted_results'].setdefault(key, []).append(enc_correct[sigma] / n_test)
            results['accuracy_loss'].setdefault(key, []).append(
                plain_sub - enc_correct[sigma] / n_test)

        for sigma in noise_sigmas:
            print(f"    sigma={sigma}: 加密精度={enc_correct[sigma] / n_test:.4f} "
                  f"(明文子集={plain_sub:.4f})", flush=True)

        results['seeds'].append({
            'seed': seed,
            'plain_accuracy_full': plain_full,
            'plain_accuracy_subset': plain_sub,
        })
        results['seed_detail'].append(detail)

        print(f"  Seed {seed}: 全集明文={plain_full:.4f} 子集明文={plain_sub:.4f}", flush=True)

    return results


def compute_statistics(values):
    """计算统计指标（95% CI 截断到 [0,1]，精度是有界比例）"""
    values = np.array(values, dtype=np.float64)
    n = len(values)
    mean = float(np.mean(values))
    std = float(np.std(values, ddof=1)) if n > 1 else 0.0
    se = std / np.sqrt(n) if n > 1 else 0.0

    if n > 1:
        t_crit = float(stats.t.ppf((1 + CONFIDENCE) / 2, df=n - 1))
        ci_low = mean - t_crit * se
        ci_high = mean + t_crit * se
        ci_low = max(0.0, min(1.0, ci_low))
        ci_high = max(0.0, min(1.0, ci_high))
    else:
        t_crit = 0.0
        ci_low = mean
        ci_high = mean

    return {
        'n': n,
        'mean': mean,
        'std': std,
        'se': se,
        't_crit': t_crit,
        'ci_95_low': ci_low,
        'ci_95_high': ci_high,
        'ci_95_width': ci_high - ci_low,
    }


def format_statistics_table(stats_dict):
    lines = [
        "| 配置 | 指标 | n | 均值 | 标准差 | 95% CI 下界 | 95% CI 上界 | CI 宽度 |",
        "|------|------|---|------|--------|-------------|-------------|---------|",
    ]
    for cfg, cstats in stats_dict.items():
        for mname, ms in cstats.items():
            lines.append(
                f"| {cfg} | {mname} | {ms['n']} | {ms['mean']:.4f} | "
                f"{ms['std']:.4f} | {ms['ci_95_low']:.4f} | {ms['ci_95_high']:.4f} | "
                f"{ms['ci_95_width']:.4f} |"
            )
    return "\n".join(lines)


def main():
    print("=" * 70)
    print("E22: 统计可靠性实验 (v2 配对比较)")
    print("=" * 70)

    t0 = time.time()
    np.random.seed(42)
    torch.manual_seed(42)
    seeds = list(range(N_SEEDS))

    transform = transforms.Compose([transforms.ToTensor()])
    train_data = datasets.MNIST(os.path.join(ROOT_DIR, 'data'), train=True,
                                download=False, transform=transform)
    train_ds = torch.utils.data.Subset(train_data, np.random.choice(len(train_data), 30000, replace=False))
    train_loader = torch.utils.data.DataLoader(train_ds, batch_size=128, shuffle=True)
    test_data = datasets.MNIST(os.path.join(ROOT_DIR, 'data'), train=False,
                               download=False, transform=transform)

    all_results = {}
    for config in CONFIGS:
        print(f"\n{'='*50}\n配置: {config['name']}\n{'='*50}", flush=True)
        result = run_experiment(config, seeds, train_loader, test_data, NOISE_SIGMAS)
        all_results[config['name']] = result

    elapsed = time.time() - t0

    print("\n" + "=" * 70 + "\n统计分析\n" + "=" * 70, flush=True)

    all_stats = {}
    for cfg_name, result in all_results.items():
        cs = {}
        cs['明文精度(全集)'] = compute_statistics(result['plain_accuracy_full'])
        cs['明文精度(配对子集)'] = compute_statistics(result['plain_accuracy_subset'])
        for key, accs in result['encrypted_results'].items():
            sigma = key.split('_')[1]
            cs[f'加密精度 (σ={sigma})'] = compute_statistics(accs)
        for key, losses in result['accuracy_loss'].items():
            sigma = key.split('_')[1]
            cs[f'精度损失 (σ={sigma})'] = compute_statistics(losses)
        all_stats[cfg_name] = cs

    stats_table = format_statistics_table(all_stats)
    print(stats_table)

    bad = [(c, m, s['ci_95_low'], s['ci_95_high'])
           for c, cs in all_stats.items() for m, s in cs.items()
           if (m.startswith('加密') or m.startswith('明文')) and (s['ci_95_high'] > 1.0 + 1e-9)]
    print("\nCI 越界检查:", bad if bad else "无越界")

    out_dir = os.path.join(ROOT_DIR, 'reports', 'experiments')
    os.makedirs(out_dir, exist_ok=True)

    results_data = {
        'experiment': 'E22',
        'title': '统计可靠性实验',
        'version': 'v2-paired',
        'date': datetime.now().strftime('%Y-%m-%d %H:%M'),
        'methodology_notes': [
            '明文精度 = 真实测试集全集精度（v1 误用 best_train_acc）',
            '加密精度与明文子集精度在同一批固定样本上配对计算',
            '精度损失 = 明文子集精度 - 加密精度（配对差值，方差远小于独立 CI）',
            '95% CI 截断到 [0,1]（精度是有界比例）',
            '密钥/噪声走独立确定性 RNG，结果可复现',
        ],
        'parameters': {
            'N': N, 'Q': Q, 'SCALE': SCALE,
            'n_seeds': N_SEEDS, 'n_test_per_seed': N_TEST,
            'noise_sigmas': NOISE_SIGMAS, 'confidence': CONFIDENCE,
        },
        'results': all_results,
        'statistics': all_stats,
        'elapsed_s': elapsed,
    }

    json_path = os.path.join(out_dir, 'e22_statistical_reliability.json')
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(results_data, f, indent=2, ensure_ascii=False)
    print(f"\nJSON: {json_path}")

    md_path = os.path.join(out_dir, 'e22_statistical_reliability.md')
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write("# E22: 统计可靠性实验\n\n")
        f.write(f"**日期**: {results_data['date']}\n")
        f.write(f"**版本**: v2（配对比较 + CI 截断）\n")
        f.write(f"**参数**: N={N}, Q={Q}, SCALE={SCALE}\n")
        f.write(f"**重复次数**: {N_SEEDS} 个不同 seed\n")
        f.write(f"**每 seed 配对测试样本**: {N_TEST}（全配置统一）\n")
        f.write(f"**置信水平**: {CONFIDENCE * 100:.0f}%\n")
        f.write(f"**总耗时**: {elapsed:.1f} s\n\n")

        f.write("## 方法学（v2 修正点）\n\n")
        for i, note in enumerate(results_data['methodology_notes'], 1):
            f.write(f"{i}. {note}\n")
        f.write("\n")

        f.write("## 网络架构\n\n")
        f.write("| 配置 | 结构 | 层数 |\n|------|------|------|\n")
        for config in CONFIGS:
            dims_str = ' → '.join(str(d) for d in config['dims']) if config['dims'] != 'cnn' else 'Conv→ReLU→FC→ReLU→FC'
            f.write(f"| {config['name']} | {dims_str} | {config['n_layers']} |\n")
        f.write("\n")

        f.write("## 统计结果（95% CI）\n\n")
        f.write(stats_table + "\n\n")

        f.write("## 逐 seed 明细\n\n")
        for cfg_name, result in all_results.items():
            f.write(f"### {cfg_name}\n\n")
            f.write("| Seed | 训练精度(末轮) | 明文(全集) | 明文(配对子集) |")
            for sigma in NOISE_SIGMAS:
                f.write(f" 加密(σ={sigma}) |")
            f.write("\n|------|----------------|-----------|----------------|")
            for _ in NOISE_SIGMAS:
                f.write("---------------|")
            f.write("\n")
            for k, sd in enumerate(result['seed_detail']):
                f.write(f"| {sd['seed']} | {sd['train_acc_last']:.4f} | "
                        f"{sd['plain_full']:.4f} | "
                        f"{result['plain_accuracy_subset'][k]:.4f} |")
                for sigma in NOISE_SIGMAS:
                    f.write(f" {result['encrypted_results'][f'sigma_{sigma}'][k]:.4f} |")
                f.write("\n")
            f.write("\n")

        f.write("## 配对样本索引（可复现）\n\n")
        for cfg_name, result in all_results.items():
            for sd in result['seed_detail']:
                f.write(f"- {cfg_name} seed={sd['seed']}: "
                        f"{sd['subset_idxs']}\n")
        f.write("\n")

    print(f"MD: {md_path}")
    print(f"\n完成，总耗时 {elapsed:.1f}s")


if __name__ == '__main__':
    main()
