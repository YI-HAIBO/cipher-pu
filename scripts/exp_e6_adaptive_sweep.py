#!/usr/bin/env python3
"""
E6: 自适应闭环 vs 静态档位 sweep

在多噪声场景下对比：
  - 静态档位（始终用 Gear 0/1/2/3）
  - 自适应档位（按噪声监测结果动态选档）

输出：各配置下的精度/吞吐/失效层统计
"""
import json, math, os, sys
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "reports", "experiments")
os.makedirs(OUT_DIR, exist_ok=True)

# ---- 生产参数 ----
N = 4096
Q = 17592186175489
BASE_GROWTH = 1.55
R_INIT = 1.0 / (1 << 24)
R_MAX = 0.5

# 档位表（与 M4-h 一致，含 threshold 用于噪声计算）
GEARS = [
    {"name": "Gear 0", "threshold": 0,     "trunc_bits": 0,  "skip_rate": 0.00, "throughput_mult": 1.0},
    {"name": "Gear 1", "threshold": 4096,  "trunc_bits": 0,  "skip_rate": 0.15, "throughput_mult": 1.3},
    {"name": "Gear 2", "threshold": 16384, "trunc_bits": 9,  "skip_rate": 0.30, "throughput_mult": 2.0},
    {"name": "Gear 3", "threshold": 65536, "trunc_bits": 17, "skip_rate": 0.50, "throughput_mult": 3.0},
]

def noise_after_layer(r_in, gear, n_layers_remaining):
    """模拟一层后的噪声增长（解析模型，与 verify_m4_h_multilayer.py 一致）"""
    sigma_0 = Q * R_INIT
    base_growth_abs = sigma_0 * (BASE_GROWTH - 1)
    sigma_skip = math.sqrt(N * gear["skip_rate"]) * gear["threshold"] / math.sqrt(12.0)
    sigma_trunc = (2.0 ** gear["trunc_bits"]) / math.sqrt(12.0)
    extra = 1.0 + (sigma_skip + sigma_trunc) / base_growth_abs
    growth = BASE_GROWTH * extra
    return r_in * growth

def select_gear_adaptive(r_in, n_remaining):
    """自适应选档：选最高档使执行后仍 < R_MAX"""
    for g in reversed(GEARS):
        r_next = noise_after_layer(r_in, g, n_remaining)
        if r_next < R_MAX:
            return g
    return GEARS[0]  # 安全兜底

def run_inference(n_layers, r_init, strategy="adaptive"):
    """运行多层推理，返回 (gear_sequence, final_r, failed_layers)"""
    r = r_init
    gears_used = []
    failed = []
    for layer in range(n_layers):
        remaining = n_layers - layer - 1
        if strategy == "adaptive":
            g = select_gear_adaptive(r, remaining)
        else:
            # 静态：用固定档位
            g_idx = min(int(strategy), len(GEARS)-1)
            g = GEARS[g_idx]
        r_next = noise_after_layer(r, g, remaining)
        gears_used.append(g["name"])
        if r_next > R_MAX:
            failed.append(layer)
        r = r_next
    return gears_used, r, failed

# ---- 主实验 ----
print("=== E6: 自适应闭环 vs 静态档位 sweep ===")
n_layers = 20  # 足够深，使 Gear 3 在后期失效，触发自适应切换
n_trials = 20

# 噪声场景：从低到高
noise_levels = [0.5, 0.8, 1.0, 1.2, 1.5, 2.0]
strategies = ["adaptive", 0, 1, 2, 3]

results = {}
for noise_level in noise_levels:
    r_init = R_INIT * noise_level
    results[noise_level] = {}
    for strat in strategies:
        key = f"adaptive" if strat == "adaptive" else f"static_G{strat}"
        all_gears = []
        all_failed = []
        final_rs = []
        for trial in range(n_trials):
            # 每个 trial 略微不同的初始噪声
            r_trial = r_init * (0.9 + 0.2 * trial / n_trials)
            gears, r_final, failed = run_inference(n_layers, r_trial, strat)
            all_gears.append(gears)
            all_failed.append(failed)
            final_rs.append(r_final)

        # 统计
        total_failed = sum(len(f) for f in all_failed)
        avg_final_r = np.mean(final_rs)
        std_final_r = np.std(final_rs)
        gear_dist = {}
        for g in all_gears:
            for gn in g:
                gear_dist[gn] = gear_dist.get(gn, 0) + 1

        # 吞吐（相对 Gear 0）—— 所有 trial 的平均吞吐倍数
        total_tp = 0.0
        total_layers = 0
        for trial_gears in all_gears:
            for gn in trial_gears:
                idx = int(gn[5]) if gn.startswith("Gear") else 0
                total_tp += GEARS[idx]["throughput_mult"]
                total_layers += 1
        avg_throughput = total_tp / max(total_layers, 1)

        # 每层平均档位（用于观察自适应切换模式）
        layer_gear_counts = [{} for _ in range(n_layers)]
        for trial_gears in all_gears:
            for li, gn in enumerate(trial_gears):
                layer_gear_counts[li][gn] = layer_gear_counts[li].get(gn, 0) + 1
        # 最常见的 trial 的档位序列
        mode_gears = []
        for li in range(n_layers):
            best = max(layer_gear_counts[li], key=layer_gear_counts[li].get) if layer_gear_counts[li] else "?"
            mode_gears.append(best)

        results[noise_level][key] = {
            "failed_layers": total_failed,
            "failed_rate": total_failed / (n_trials * n_layers),
            "avg_final_r": round(avg_final_r, 6),
            "std_final_r": round(std_final_r, 6),
            "avg_throughput": round(avg_throughput, 3),
            "gear_distribution": {k: v for k, v in sorted(gear_dist.items())},
            "mode_gear_sequence": mode_gears,
        }
        print(f"  noise={noise_level:.1f}  {key:12s}: "
              f"failed={total_failed:3d}/{n_trials*n_layers}  "
              f"final_r={avg_final_r:.6f}±{std_final_r:.6f}  "
              f"tp={avg_throughput:.2f}x")

# ---- 保存 ----
out_json = os.path.join(OUT_DIR, "adaptive_sweep.json")
with open(out_json, "w") as f:
    json.dump({
        "n_layers": n_layers,
        "n_trials": n_trials,
        "R_MAX": R_MAX,
        "results": results
    }, f, indent=2)
print(f"\n  结果已保存: {out_json}")

# ---- 关键发现 ----
print("\n=== 关键发现 ===")
print()
for noise_level in noise_levels:
    adapt = results[noise_level]["adaptive"]
    print(f"  noise={noise_level:.1f}:")
    print(f"    自适应: 失败率={adapt['failed_rate']:.1%}, 吞吐={adapt['avg_throughput']:.2f}x, "
          f"最终噪声={adapt['avg_final_r']:.6f}")
    print(f"    档位序列: {' → '.join(adapt['mode_gear_sequence'])}")
    # 与各静态档位对比
    for i in range(4):
        s = results[noise_level][f"static_G{i}"]
        marker = " ← 同失败率但更低吞吐" if s["failed_rate"] == adapt["failed_rate"] and s["avg_throughput"] < adapt["avg_throughput"] else ""
        print(f"    静态G{i}: 失败率={s['failed_rate']:.1%}, 吞吐={s['avg_throughput']:.2f}x{marker}")
    print()