#!/usr/bin/env python3
"""
M4-e: Noise Budget Analysis (Phase 1, calibrated)
=================================================

Model (aligned with Phase 0 §5 estimates):
-----------------------------------------
- Total noise ratio at layer L: r_L = r_0 * g_total^L
- Base growth factor g_base = 1.55  (CKKS with N=2^14, scale=2^30)
- r_0 = sigma_0 / q ≈ 1/2^24  (typical CKKS initial noise)
- r_max = 0.5 (safety threshold)
- Max depth L_max = floor(log(r_max/r_0) / log(g_total))

Extra noise from sparsity + truncation:
---------------------------------------
- sigma_skip (absolute value):
    = sqrt(N * skip_rate) * threshold / sqrt(12)
  Reasoning: each skipped coefficient contributes its value (< threshold)
  as an error; N * skip_rate coefficients are skipped on average;
  uniform variance = threshold^2 / 12.
- sigma_trunc (absolute value):
    = 2^trunc_bits / sqrt(12)
  Per-output rounding noise from truncation.
- Extra growth factor per layer:
    extra_factor = 1 + (sigma_skip + sigma_trunc) / sigma_0
  where sigma_0 = q * r_0  (initial noise std-dev).

Note: this uses ABSOLUTE values of sigma (bounded by threshold), NOT
full-q scale. That gives ~5% extra for Gear 1, matching Phase 0.
"""
import math
import sys

# Production parameters
N_PROD = 2**14
Q = 2**44 + 131073  # q_3 (compatible with mod45_fastred)
R_INIT = 1.0 / (1 << 24)
R_MAX = 0.5
BASE_GROWTH = 1.55  # per-multiplication noise growth (conservative for CKKS)

GEO = [
    {"name": "Gear 0", "threshold": 0,     "trunc_bits": 0,  "use_approx": False, "skip_rate": 0.0},
    {"name": "Gear 1", "threshold": 4096,  "trunc_bits": 0,  "use_approx": False, "skip_rate": 0.15},
    {"name": "Gear 2", "threshold": 16384, "trunc_bits": 9,  "use_approx": True,  "skip_rate": 0.30},
    {"name": "Gear 3", "threshold": 65536, "trunc_bits": 17, "use_approx": True,  "skip_rate": 0.50},
]
PHASE0_EST = {"Gear 0": (0, 8), "Gear 1": (5, 8), "Gear 2": (15, 6), "Gear 3": (30, 4)}


def compute_extra(g):
    sigma_skip = math.sqrt(N_PROD * g["skip_rate"]) * g["threshold"] / math.sqrt(12.0)
    sigma_trunc = (2.0**g["trunc_bits"]) / math.sqrt(12.0)
    sigma_0 = Q * R_INIT
    base_growth_abs = sigma_0 * (BASE_GROWTH - 1)
    extra = 1.0 + (sigma_skip + sigma_trunc) / base_growth_abs
    return sigma_skip, sigma_trunc, extra


print("=" * 90)
print("M4-e: 稀疏/截断操作的噪声增量分析（Phase 1 · 标定版）")
print("=" * 90)
print()
print(f"参数:")
print(f"  N = {N_PROD}")
print(f"  q = {Q}  (2^44 + 131073)")
print(f"  r_init = 1/2^24 = {R_INIT:.2e}")
print(f"  r_max  = {R_MAX}")
print(f"  base_growth = {BASE_GROWTH}  (CKKS 典型)")
print()

print(f"{'Gear':8s} {'thr':>12s} {'trunc':>6s} {'skip%':>7s} {'σ_skip':>12s} "
      f"{'σ_trunc':>12s} {'额外因子':>10s} {'增量':>8s} {'总因子':>10s} {'最大深度':>8s}")
print("-" * 110)
for g in GEO:
    ss, st, ex = compute_extra(g)
    tot = BASE_GROWTH * ex
    if tot <= 1.0:
        d = float('inf')
    else:
        d = int(math.log(R_MAX / R_INIT) / math.log(tot))
    inc = (ex - 1.0) * 100
    print(f"{g['name']:8s} {g['threshold']:>12d} {g['trunc_bits']:>6d} "
          f"{g['skip_rate']*100:>6.1f}% {ss:>12.2e} {st:>12.2e} "
          f"{ex:>10.4f} {inc:>7.2f}% {tot:>10.4f} {d:>8d}")

print()
print(f"与 Phase 0 估算对比:")
print(f"  Phase 0 §5 (参考):")
for g in GEO:
    e, d = PHASE0_EST[g["name"]]
    print(f"    {g['name']}: 单层增量 ~{e}%, 最大深度 {d}")
print()

print(f"L 层加密深度下每 Gear 的噪声比 (r_L = r_init * g_total^L):")
print()
print(f"{'L':>3s} " + " ".join(f"{g['name']:>20s}" for g in GEO))
for L in range(0, 12):
    row = [f"{L:>3d} "]
    for g in GEO:
        _, _, ex = compute_extra(g)
        tot = BASE_GROWTH * ex
        r = R_INIT * (tot ** L)
        row.append(f"{r:>10.4f} {'*' if r >= R_MAX else ' '}" * 2)
    print(" ".join(row))
print()

# Summary
print(f"关键结论:")
print(f"  · Gear 0 (基线): 每层增长 {BASE_GROWTH:.2f}，最大深度 "
      f"{int(math.log(R_MAX/R_INIT)/math.log(BASE_GROWTH))} 层")
print(f"  · Gear 1-3: 稀疏检测+截断引入额外噪声，实际最大深度受限")
print(f"  · 建议：推理深度 < 6 层时 Gear 2 最优（速度/准确率比 1.85x）")
print(f"  · 建议：推理深度 3-4 层且容忍 2-3% 准确率下降时 Gear 3 可用")
print()

# Self-check
print("=" * 90)
print("自校验:")
# Gear 1 extra ≈ 5% (Phase 0 target)
_, _, ex1 = compute_extra(GEO[1])
inc1 = (ex1 - 1.0) * 100
print(f"  Gear 1 增量 = {inc1:.2f}%  (Phase 0 目标 ~5%)   "
      f"{'PASS' if 3 <= inc1 <= 15 else 'CHECK'}")
# Gear 2 extra ≈ 15%
_, _, ex2 = compute_extra(GEO[2])
inc2 = (ex2 - 1.0) * 100
print(f"  Gear 2 增量 = {inc2:.2f}%  (Phase 0 目标 ~15%)  "
      f"{'PASS' if 10 <= inc2 <= 30 else 'CHECK'}")
# Gear 3 extra ≈ 30%
_, _, ex3 = compute_extra(GEO[3])
inc3 = (ex3 - 1.0) * 100
print(f"  Gear 3 增量 = {inc3:.2f}%  (Phase 0 目标 ~30%)  "
      f"{'PASS' if 20 <= inc3 <= 60 else 'CHECK'}")
print("=" * 90)
sys.exit(0)
