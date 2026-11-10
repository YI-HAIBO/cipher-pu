#!/usr/bin/env python3
"""E36: 大样本统计验证 — 方案B 实验

在 E22 v2 配对比较方法学基础上把样本量提升到一区要求：
  - MLP-2L: 200 配对样本/seed × 5 seeds × 3 sigma = 3000 次加密推理
  - CNN   :  60 配对样本/seed × 5 seeds × 3 sigma =  900 次加密推理
  - 数据集: MNIST + Fashion-MNIST（FashionMNIST 下载失败则跳过）

新增统计（E22 未做）:
  1. McNemar 精确检验（配对二元结果 plain_ok vs enc_ok）→ p-value
  2. Wilson 得分区间（加密精度 + 判定不一致率）
  3. Bootstrap 95% CI（配对精度损失均值，10000 次重采样）

依赖: exp_e22_statistical_reliability.run_experiment（复用 v2 配对比较实现）
"""
import json
import os
import sys
import time
from datetime import datetime

import numpy as np
import torch
from torchvision import datasets, transforms
from scipy import stats

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
os.chdir(ROOT_DIR)

from exp_e22_statistical_reliability import run_experiment  # noqa: E402

N = 1024
Q = 998244353
SCALE = 2 ** 10
NOISE_SIGMAS = [1, 4, 16]
N_SEEDS = 5

CONFIGS = [
    {'name': 'MLP-2L', 'dims': [784, 128, 10], 'n_layers': 2, 'n_test': 200},
    {'name': 'CNN', 'dims': 'cnn', 'n_layers': 3, 'n_test': 60},
]

BOOTSTRAP_N = 10000
CONFIDENCE = 0.95


def make_loaders(dataset_name):
    transform = transforms.Compose([transforms.ToTensor()])
    dset_cls = datasets.MNIST if dataset_name == 'MNIST' else datasets.FashionMNIST
    train_data = dset_cls(os.path.join(ROOT_DIR, 'data'), train=True,
                          download=(dataset_name != 'MNIST'), transform=transform)
    train_ds = torch.utils.data.Subset(
        train_data, np.random.choice(len(train_data), 30000, replace=False))
    train_loader = torch.utils.data.DataLoader(train_ds, batch_size=128, shuffle=True)
    test_data = dset_cls(os.path.join(ROOT_DIR, 'data'), train=False,
                         download=(dataset_name != 'MNIST'), transform=transform)
    return train_loader, test_data


def wilson_ci(k, n, conf=CONFIDENCE):
    """Wilson score interval for a binomial proportion."""
    if n == 0:
        return (0.0, 0.0)
    z = stats.norm.ppf(1 - (1 - conf) / 2)
    p = k / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, center - half), min(1.0, center + half))


def bootstrap_ci(values, n_boot=BOOTSTRAP_N, conf=CONFIDENCE, seed=20261024):
    """Bootstrap CI for the mean of paired differences."""
    arr = np.asarray(values, dtype=np.float64)
    if len(arr) == 0:
        return (0.0, 0.0)
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(arr), size=(n_boot, len(arr)))
    means = arr[idx].mean(axis=1)
    lo, hi = np.percentile(means, [(1 - conf) / 2 * 100, (1 + conf) / 2 * 100])
    return (float(lo), float(hi))


def paired_e22_from_result(result):
    """Flatten seed_detail into per-sample paired binary outcomes per sigma."""
    per_sigma = {f'sigma_{s}': [] for s in NOISE_SIGMAS}
    for sd in result['seed_detail']:
        for samp in sd['samples']:
            for s in NOISE_SIGMAS:
                per_sigma[f'sigma_{s}'].append(
                    (bool(samp['plain_ok']), bool(samp.get(f'sigma_{s}_ok'))))
    return per_sigma


def analyze_paired(pairs):
    """McNemar exact test + Wilson CIs + bootstrap loss CI."""
    plain_ok = np.array([p[0] for p in pairs])
    enc_ok = np.array([p[1] for p in pairs])
    n = len(pairs)
    b = int(np.sum(plain_ok & ~enc_ok))   # plain right, enc wrong
    c = int(np.sum(~plain_ok & enc_ok))   # plain wrong, enc right
    disc = b + c
    if disc == 0:
        pval = 1.0
        note = 'no discordant pairs (encryption never changes a prediction)'
    elif disc < 25:
        # exact binomial: under H0 b ~ Binom(disc, 0.5), two-sided
        pval = float(2 * min(stats.binom.cdf(b, disc, 0.5),
                             1 - stats.binom.cdf(b - 1, disc, 0.5)))
        pval = min(1.0, pval)
        note = f'McNemar exact (b={b}, c={c})'
    else:
        chi2 = (abs(b - c) - 1) ** 2 / disc
        pval = float(1 - stats.chi2.cdf(chi2, 1))
        note = f'McNemar chi2 (b={b}, c={c})'
    enc_acc = float(enc_ok.mean())
    plain_acc = float(plain_ok.mean())
    loss = plain_acc - enc_acc
    losses = (plain_ok.astype(float) - enc_ok.astype(float))
    ci_enc = wilson_ci(int(enc_ok.sum()), n)
    ci_disc = wilson_ci(disc, n)
    ci_loss = bootstrap_ci(losses.tolist())
    return {
        'n': n,
        'plain_acc': plain_acc,
        'enc_acc': enc_acc,
        'mean_loss': float(loss),
        'discordant': disc,
        'b_plain_right_enc_wrong': b,
        'c_plain_wrong_enc_right': c,
        'mcnemar_p': pval,
        'mcnemar_note': note,
        'enc_acc_wilson_ci': [ci_enc[0], ci_enc[1]],
        'discordant_rate_wilson_ci': [ci_disc[0], ci_disc[1]],
        'loss_bootstrap_ci95': [ci_loss[0], ci_loss[1]],
    }


def main():
    print("=" * 70)
    print("E36: large-sample statistical validation (plan B)")
    print("=" * 70)
    t0 = time.time()
    np.random.seed(42)
    torch.manual_seed(42)
    seeds = list(range(N_SEEDS))

    all_results = {}
    all_analysis = {}
    failures = []

    datasets_to_run = ['MNIST']
    try:
        datasets.FashionMNIST(os.path.join(ROOT_DIR, 'data'), train=True,
                              download=True)
        datasets_to_run.append('FashionMNIST')
    except Exception as ex:
        print(f"[e36] FashionMNIST unavailable ({ex}); running MNIST only",
              flush=True)
        failures.append(f'FashionMNIST download failed: {ex}')

    for dset_name in datasets_to_run:
        print(f"\n{'='*60}\nDataset: {dset_name}\n{'='*60}", flush=True)
        try:
            train_loader, test_data = make_loaders(dset_name)
        except Exception as ex:
            print(f"[e36] {dset_name} loader failed: {ex}", flush=True)
            failures.append(f'{dset_name} loader: {ex}')
            continue
        for config in CONFIGS:
            cfg_name = f"{dset_name}/{config['name']}"
            print(f"\n----- {cfg_name} (n_test={config['n_test']}) -----", flush=True)
            try:
                result = run_experiment(config, seeds, train_loader, test_data,
                                        NOISE_SIGMAS)
            except Exception as ex:
                print(f"[e36] {cfg_name} FAILED: {ex}", flush=True)
                failures.append(f'{cfg_name}: {ex}')
                continue
            all_results[cfg_name] = result
            pairs = paired_e22_from_result(result)
            all_analysis[cfg_name] = {
                f'sigma_{s}': analyze_paired(pairs[f'sigma_{s}'])
                for s in NOISE_SIGMAS
            }
            for s in NOISE_SIGMAS:
                a = all_analysis[cfg_name][f'sigma_{s}']
                print(f"  sigma={s}: n={a['n']} plain={a['plain_acc']:.4f} "
                      f"enc={a['enc_acc']:.4f} disc={a['discordant']} "
                      f"p={a['mcnemar_p']:.4g}", flush=True)

    elapsed = time.time() - t0
    print("\n" + "=" * 70 + "\nfinal analysis\n" + "=" * 70, flush=True)

    # ---- summary table ----
    lines = [
        "| 配置 | σ | n | 明文精度 | 加密精度 | 不一致对 | Wilson CI (加密) | "
        "McNemar p | 损失 95% CI (bootstrap) |",
        "|------|---|---|----------|----------|----------|------------------|"
        "-----------|---------------------------|",
    ]
    for cfg, per_sigma in all_analysis.items():
        for key, a in per_sigma.items():
            sigma = key.split('_')[1]
            lines.append(
                f"| {cfg} | {sigma} | {a['n']} | {a['plain_acc']:.4f} | "
                f"{a['enc_acc']:.4f} | {a['discordant']} | "
                f"[{a['enc_acc_wilson_ci'][0]:.4f}, {a['enc_acc_wilson_ci'][1]:.4f}] | "
                f"{a['mcnemar_p']:.4g} | "
                f"[{a['loss_bootstrap_ci95'][0]:.4f}, {a['loss_bootstrap_ci95'][1]:.4f}] |"
            )
    table = "\n".join(lines)
    print(table, flush=True)

    out_dir = os.path.join(ROOT_DIR, 'reports', 'experiments')
    os.makedirs(out_dir, exist_ok=True)
    data = {
        'experiment': 'E36',
        'title': '大样本统计验证（配对比较 + McNemar + Wilson + Bootstrap）',
        'date': datetime.now().strftime('%Y-%m-%d %H:%M'),
        'parameters': {
            'N': N, 'Q': Q, 'SCALE': SCALE, 'n_seeds': N_SEEDS,
            'n_test_per_seed': {c['name']: c['n_test'] for c in CONFIGS},
            'noise_sigmas': NOISE_SIGMAS, 'bootstrap_n': BOOTSTRAP_N,
            'confidence': CONFIDENCE,
        },
        'summary_table': table,
        'analysis': all_analysis,
        'failures': failures,
        'elapsed_s': elapsed,
    }
    json_path = os.path.join(out_dir, 'e36_large_sample.json')
    # seed_detail is large; keep per-sample detail out of JSON to stay slim
    slim_results = {}
    for cfg, r in all_results.items():
        slim_results[cfg] = {
            'plain_accuracy_full': r['plain_accuracy_full'],
            'plain_accuracy_subset': r['plain_accuracy_subset'],
            'encrypted_results': r['encrypted_results'],
            'accuracy_loss': r['accuracy_loss'],
            'n_test': r.get('n_test'),
            'n_seeds': len(r['seeds']),
        }
    data['results_slim'] = slim_results
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

    md_path = os.path.join(out_dir, 'e36_large_sample.md')
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write("# E36: 大样本统计验证\n\n")
        f.write(f"**日期**: {data['date']}  |  **耗时**: {elapsed:.1f} s\n\n")
        f.write("**方法**: 在 E22 v2 配对比较方法学上扩大样本量；新增 McNemar "
                "精确检验、Wilson 得分区间与 Bootstrap CI。\n\n")
        f.write(f"- MLP-2L: {CONFIGS[0]['n_test']} 配对样本/seed × {N_SEEDS} seeds "
                f"× {len(NOISE_SIGMAS)} σ = "
                f"{CONFIGS[0]['n_test']*N_SEEDS*len(NOISE_SIGMAS)} 次加密推理\n")
        f.write(f"- CNN: {CONFIGS[1]['n_test']} 配对样本/seed × {N_SEEDS} seeds "
                f"× {len(NOISE_SIGMAS)} σ = "
                f"{CONFIGS[1]['n_test']*N_SEEDS*len(NOISE_SIGMAS)} 次加密推理\n")
        f.write(f"- N={N}, Q={Q}, SCALE={SCALE}\n\n")
        if failures:
            f.write("## 跳过的项\n\n" + "\n".join(f"- {x}" for x in failures) + "\n\n")
        f.write("## 汇总\n\n")
        f.write(table + "\n\n")
        f.write("## 解读\n\n")
        f.write("- **McNemar p > 0.05** ⇒ 无法拒绝「加密推理与明文预测一致」的零假设；"
                "不一致对数为 0 时 p=1（无任何分歧证据）。\n")
        f.write("- **Wilson CI** 以配对样本数为分母，比 E22 的 5-seed t 区间功效更高。\n")
        f.write("- **损失 Bootstrap CI 包含 0** ⇒ 无统计显著的精度退化证据。\n")
    print(f"\nJSON: {json_path}\nMD:   {md_path}")
    print(f"完成，总耗时 {elapsed:.1f}s")


if __name__ == '__main__':
    main()
