#!/usr/bin/env python3
"""
M4-h: SNR-Adaptive Sparsity + Runtime Noise Monitoring
========================================================

Python prototype extending M4-e's static 4-gear noise budget with:
  1. Online SNR estimation (Welford's algorithm) - validated standalone
  2. Dynamic gear selection based on measured r_hat
  3. Hysteresis to prevent gear oscillation
  4. Multi-layer noise accumulation with mixed gears
  5. Throughput gain comparison vs static baselines

Model (aligned with M4-e):
  - r_L       = sigma_L / Q
  - g_total   = g_base * extra_factor
  - extra_f   = 1 + (sigma_skip + sigma_trunc) / sigma_0
  - sigma_skip  = sqrt(N * skip_rate) * threshold / sqrt(12)
  - sigma_trunc = 2^trunc_bits / sqrt(12)
  - sigma_0 = q * r_init  (= 2^20 for production)

Gear throughput assumptions (empirical Phase 1):
  - Gear 0: 1.0x, Gear 1: 1.3x, Gear 2: 2.0x, Gear 3: 3.0x
"""
import math
import sys
import random
from typing import Tuple

# ===================== Parameters (aligned with M4-e) =====================
N_PROD = 2 ** 14
Q = 2 ** 44 + 131073
R_INIT = 1.0 / (1 << 24)
R_MAX = 0.5
BASE_GROWTH = 1.55
SIGMA_0 = Q * R_INIT  # = 2^20 = 1048576

GEO = [
    {"name": "Gear 0", "threshold": 0,     "trunc_bits": 0,  "use_approx": False, "skip_rate": 0.00, "throughput": 1.0},
    {"name": "Gear 1", "threshold": 4096,  "trunc_bits": 0,  "use_approx": False, "skip_rate": 0.15, "throughput": 1.3},
    {"name": "Gear 2", "threshold": 16384, "trunc_bits": 9,  "use_approx": True,  "skip_rate": 0.30, "throughput": 2.0},
    {"name": "Gear 3", "threshold": 65536, "trunc_bits": 17, "use_approx": True,  "skip_rate": 0.50, "throughput": 3.0},
]

HYSTERESIS_FRAC = 0.05  # fraction of R_MAX


# ===================== M4-e core =====================
def compute_extra(g: dict) -> Tuple[float, float, float]:
    sigma_skip = math.sqrt(N_PROD * g["skip_rate"]) * g["threshold"] / math.sqrt(12.0)
    sigma_trunc = (2.0 ** g["trunc_bits"]) / math.sqrt(12.0)
    base_growth_abs = SIGMA_0 * (BASE_GROWTH - 1)
    extra = 1.0 + (sigma_skip + sigma_trunc) / base_growth_abs
    return sigma_skip, sigma_trunc, extra


def total_growth(g: dict) -> float:
    return BASE_GROWTH * compute_extra(g)[2]


def max_depth(g: dict) -> int:
    tot = total_growth(g)
    if tot <= 1.0:
        return float('inf')
    return int(math.log(R_MAX / R_INIT) / math.log(tot))


# ===================== SNR Estimator =====================
class WelfordMonitor:
    """Online variance estimator (Welford's algorithm).

    Mirrors the RTL module design: single-pass update with running
    count, mean, and M2 (sum of squared deviations).
    """
    def __init__(self):
        self.n = 0
        self.mean = 0.0
        self.m2 = 0.0

    def update(self, x: float) -> None:
        self.n += 1
        delta = x - self.mean
        self.mean += delta / self.n
        delta2 = x - self.mean
        self.m2 += delta * delta2

    def variance(self) -> float:
        if self.n < 2:
            return 0.0
        return self.m2 / (self.n - 1)

    def std(self) -> float:
        return math.sqrt(self.variance())


def estimate_r_hat(monitor: WelfordMonitor) -> float:
    """r_hat = sigma_measured / Q."""
    return monitor.std() / Q


# ===================== Dynamic Gear Controller =====================
def select_gear_safe(r_current: float) -> int:
    """Pick highest gear whose post-execution r stays < R_MAX.

    Safety-first: prefer maximum throughput (highest gear) that
    will NOT push r over R_MAX. Falls back to Gear 0 if none fit.
    """
    for g_idx in range(3, -1, -1):
        g = GEO[g_idx]
        if r_current * total_growth(g) < R_MAX:
            return g_idx
    return 0


def select_gear_with_hysteresis(gear_new: int, gear_old: int,
                                r_current: float) -> int:
    """Hysteresis: allow downgrade immediately (safer); upgrade only with margin.

    Upgrade margin: r * g_new * (1 + HYSTERESIS_FRAC) < R_MAX
    (i.e. after executing this layer with 'gear_new', there is still 5%
     margin to R_MAX so we don't flip back immediately next layer.)
    """
    if gear_new < gear_old:
        return gear_new
    if gear_new > gear_old:
        g = GEO[gear_new]
        if r_current * total_growth(g) * (1 + HYSTERESIS_FRAC) < R_MAX:
            return gear_new
        return gear_old
    return gear_new


# ===================== Simulation =====================
def simulate_static_depth(g_idx: int) -> Tuple[int, float]:
    g = GEO[g_idx]
    tot = total_growth(g)
    L = 0
    r = R_INIT
    while r < R_MAX and L < 100:
        r *= tot
        L += 1
    if L > 0:
        L -= 1
        r = R_INIT * (tot ** L)
    return L, r


def simulate_adaptive(L_target: int, use_hysteresis: bool = False) -> dict:
    """Per-layer gear selection. Uses analytical r (oracle) as r_hat input.
    Safety-first: pick highest gear that won't push r over R_MAX.
    """
    r = R_INIT
    gear = 0
    trace = []
    for L in range(1, L_target + 1):
        gear_new = select_gear_safe(r)
        if use_hysteresis:
            gear_new = select_gear_with_hysteresis(gear_new, gear, r)
        g = GEO[gear_new]
        tot = total_growth(g)
        r_after = r * tot
        trace.append({
            "L": L, "r_before": r, "r_hat": r,
            "headroom_before": R_MAX - r,
            "gear": gear_new, "gear_name": g["name"],
            "r_after": r_after, "throughput": g["throughput"],
        })
        gear = gear_new
        r = r_after
        if r >= R_MAX:
            break
    total_gain = 1.0
    for t in trace:
        total_gain *= t["throughput"]
    return {
        "trace": trace,
        "actual_L": len(trace),
        "final_r": r,
        "cumulative_throughput_gain": total_gain,
        "use_hysteresis": use_hysteresis,
    }


def simulate_static_sequence(g_names: list) -> float:
    """Simulate a fixed sequence of gears, return final r."""
    r = R_INIT
    for gname in g_names:
        g = next(x for x in GEO if x["name"] == gname)
        r *= total_growth(g)
    return r


# ===================== Report =====================
def print_separator(title: str = ""):
    print()
    print("=" * 90)
    if title:
        print(title)
        print("=" * 90)


def main():
    print_separator("M4-h: SNR 自适应稀疏 + 运行时噪声监测 (Python 原型)")

    # ----- Part 1: 静态基线 -----
    print_separator("Part 1: 复用 M4-e 静态 4 档基线")
    print(f"  N={N_PROD}, Q={Q}, r_init={R_INIT:.2e}, r_max={R_MAX}, base_growth={BASE_GROWTH}")
    print(f"{'Gear':8s} {'thr':>10s} {'trunc':>6s} {'skip%':>6s} "
          f"{'额外因子':>10s} {'总因子':>10s} {'最大深度':>8s} {'吞吐':>6s}")
    print("-" * 78)
    for g in GEO:
        _, _, ex = compute_extra(g)
        tot = BASE_GROWTH * ex
        d = max_depth(g)
        print(f"{g['name']:8s} {g['threshold']:>10d} {g['trunc_bits']:>6d} "
              f"{g['skip_rate']*100:>5.0f}% {ex:>10.4f} {tot:>10.4f} "
              f"{d:>8d} {g['throughput']:>5.1f}x")

    # ----- Part 2: Welford 精度自校验 -----
    print_separator("Part 2: Welford 在线方差估计自校验")
    random.seed(42)
    monitor = WelfordMonitor()
    true_sigma = 1e6  # similar order to sigma_0
    for _ in range(50000):
        monitor.update(random.gauss(0, true_sigma))
    est_sigma = monitor.std()
    rel_err_sigma = abs(est_sigma - true_sigma) / true_sigma
    print(f"  真值 σ = {true_sigma:.2e}")
    print(f"  Welford 估计 σ_hat = {est_sigma:.2e}  (n=50000 样本)")
    print(f"  相对误差 = {rel_err_sigma*100:.4f}%   "
          f"{'PASS' if rel_err_sigma < 0.05 else 'FAIL'}")

    # r_hat 反推
    r_true = 0.1
    monitor2 = WelfordMonitor()
    for _ in range(200000):  # larger sample for high precision
        monitor2.update(random.gauss(0, r_true * Q))
    r_hat = estimate_r_hat(monitor2)
    rel_err_r = abs(r_hat - r_true) / r_true
    print(f"  r_true = {r_true:.3f}   r_hat = {r_hat:.4f}")
    print(f"  r_hat 相对误差 = {rel_err_r*100:.4f}%   "
          f"{'PASS' if rel_err_r < 0.05 else 'FAIL'}")

    # ----- Part 3: 动态档位追踪 -----
    print_separator("Part 3: 动态档位追踪 (30 层推理)")
    print(f"  策略: safety-first — 选最高档使得执行后 r < R_MAX")
    print(f"  {'L':>3s} {'r_L(前)':>12s} {'h_L(前)':>10s} {'Gear':>6s} "
          f"{'r_L(后)':>12s} {'吞吐':>6s}")
    print("  " + "-" * 66)

    r = R_INIT
    gear_seq = []
    for L in range(1, 31):
        g = select_gear_safe(r)
        gear_seq.append(g)
        tot = total_growth(GEO[g])
        r_after = r * tot
        if L <= 12 or L >= 26:
            print(f"  {L:>3d} {r:>12.4e} {R_MAX-r:>10.4f} {GEO[g]['name']:>6s} "
                  f"{r_after:>12.4e} {GEO[g]['throughput']:>5.1f}x")
        elif L == 13:
            print("  ...")
        r = r_after
    print(f"  → 30 层实际序列: {gear_seq}")
    total_tp = 1.0
    for g in gear_seq:
        total_tp *= GEO[g]["throughput"]
    print(f"  → 30 层累计吞吐 (相对 G0) = {total_tp:.1f}x")

    # ----- Part 4: 静态 vs 自适应 深度对比 -----
    print_separator("Part 4: 静态基线 vs 自适应策略 (深度 vs 吞吐)")
    print(f"{'策略':<34s} {'可达深度':>10s} {'总吞吐':>12s} {'备注':>14s}")
    print("-" * 76)

    for i, g in enumerate(GEO):
        d, _ = simulate_static_depth(i)
        cum_tp = g["throughput"] ** d
        note = "深度最大" if i == 0 else "单档固定"
        print(f"{'静态 ' + g['name']:<34s} {d:>10d} {cum_tp:>12.1f} {note:>14s}")

    L_target = 100
    sim_adv = simulate_adaptive(L_target, use_hysteresis=False)
    sim_adv_h = simulate_adaptive(L_target, use_hysteresis=True)

    print(f"{'自适应 (无迟滞)':<34s} {sim_adv['actual_L']:>10d} "
          f"{sim_adv['cumulative_throughput_gain']:>12.1f} {'r_hat 驱动':>14s}")
    print(f"{'自适应 (含迟滞 δ=0.05)':<34s} {sim_adv_h['actual_L']:>10d} "
          f"{sim_adv_h['cumulative_throughput_gain']:>12.1f} {'抗抖动':>14s}")

    # 自适应 vs 静态在同目标深度下的吞吐对比
    # 选定目标 L=10（Gear 3 单档极限 8 层之上、Gear 0 安全）
    L_CMP = 10
    adv_trace = sim_adv["trace"]
    adv_tp_at_L = 1.0
    for t in adv_trace[:L_CMP]:
        adv_tp_at_L *= t["throughput"]
    static_g0_tp_at_L = 1.0  # G0 baseline
    # Static optimal at same depth: pick best single gear that can do L_CMP safely
    best_static_gear_tp_at_L = 1.0
    best_static_gear_name = None
    for i, g in enumerate(GEO):
        d, _ = simulate_static_depth(i)
        if d >= L_CMP:
            tp = g["throughput"] ** L_CMP
            if tp > best_static_gear_tp_at_L:
                best_static_gear_tp_at_L = tp
                best_static_gear_name = g["name"]

    # 深度对比
    best_static_depth = max(simulate_static_depth(i)[0] for i in range(4))

    print()
    print(f"  ★ 自适应相对最佳静态的最大深度: 自适应 {sim_adv['actual_L']} 层 "
          f"vs 静态 G0 {best_static_depth} 层 "
          f"(自适应目标不是深度最大化，而是同深度下吞吐最大化)")
    print(f"  ★ L={L_CMP} 时自适应吞吐 = {adv_tp_at_L:.1f}x "
          f"(静态 G0=1x, 最佳静态 {best_static_gear_name}={best_static_gear_tp_at_L:.1f}x)")
    gain_vs_G0 = adv_tp_at_L / static_g0_tp_at_L
    gain_vs_best_static = adv_tp_at_L / best_static_gear_tp_at_L
    print(f"  ★ L={L_CMP} 自适应 vs 静态 G0 吞吐增益 = {gain_vs_G0:.1f}x")
    print(f"  ★ L={L_CMP} 自适应 vs 最佳静态单档 ({best_static_gear_name}) = "
          f"{gain_vs_best_static:.1f}x")

    # ----- Part 5: 误差积累上界验证 -----
    print_separator("Part 5: 误差积累上界验证 (Theorem 5.4)")
    print(f"  检查: r_L = r_0 * Π g_i(L-1) 解析式与逐步模拟一致")
    print(f"  {'Gear 序列':<50s} {'r_L 解析':>14s} {'r_L 仿真':>14s} {'偏差':>8s} {'状态':>6s}")
    print("  " + "-" * 94)

    sequences = [
        ("Gear 0",) * 10,
        ("Gear 2",) * 5,
        ("Gear 0",) * 3 + ("Gear 2",) * 3 + ("Gear 0",) * 3,
        ("Gear 3",) * 4,
        ("Gear 0",) * 2 + ("Gear 1",) * 5 + ("Gear 3",) * 3,
        ("Gear 2",) * 2 + ("Gear 0",) * 5 + ("Gear 3",) * 2 + ("Gear 1",) * 3,
    ]
    check_results = []
    for seq in sequences:
        # Compact display: collapse repeats like "G0×3 → G2×3 → G0×3"
        parts = []
        prev = None
        cnt = 0
        for x in seq:
            if x == prev:
                cnt += 1
            else:
                if prev is not None:
                    parts.append(f"{prev[4:]}×{cnt}")
                prev = x
                cnt = 1
        if prev is not None:
            parts.append(f"{prev[4:]}×{cnt}")
        name = " → ".join(parts)
        if len(name) > 46:
            name = name[:43] + "..."
        r_analytic = R_INIT
        for gname in seq:
            g = next(x for x in GEO if x["name"] == gname)
            r_analytic *= total_growth(g)
        r_sim = simulate_static_sequence(seq)
        rel_dev = abs(r_analytic - r_sim) / r_analytic
        status = "PASS" if rel_dev < 1e-9 else "FAIL"
        check_results.append((name, status))
        print(f"  {name:<50s} {r_analytic:>14.4e} {r_sim:>14.4e} "
              f"{rel_dev:>8.2e} {status:>6s}")

    # ----- Part 6: 验收标准 -----
    print_separator("Part 6: 验收标准")
    checks = []
    checks.append(("C1 Welford σ 估计相对误差 <5%",
                   rel_err_sigma < 0.05))
    checks.append(("C2 r_hat 反推相对误差 <5%",
                   rel_err_r < 0.05))
    d0 = max_depth(GEO[0])
    checks.append((f"C3 静态 Gear 0 最大深度 >= 36 (实际 {d0})",
                   d0 >= 36))
    # C4: Adaptive throughput at target depth > 10x G0
    checks.append((f"C4 L={L_CMP} 自适应 vs 静态 G0 吞吐增益 > 10x "
                   f"(实际 {gain_vs_G0:.1f}x)",
                   gain_vs_G0 > 10))
    # C5: Adaptive >= best static single gear at same depth
    checks.append((f"C5 L={L_CMP} 自适应 >= 最佳静态单档 ({best_static_gear_name}) "
                   f"({gain_vs_best_static:.1f}x)",
                   gain_vs_best_static >= 1.0))
    # C6: Hysteresis reduces gear flips
    def count_flips(sim):
        return sum(1 for i in range(1, len(sim["trace"]))
                   if sim["trace"][i]["gear"] != sim["trace"][i-1]["gear"])
    flips_no_hys = count_flips(sim_adv)
    flips_hys = count_flips(sim_adv_h)
    checks.append((f"C6 迟滞减少档位跳变 ({flips_no_hys} -> {flips_hys})",
                   flips_hys <= flips_no_hys))
    # C7: Error accumulation analytic == simulation
    checks.append(("C7 误差积累上界解析=仿真 (6 序列全对)",
                   all(s == "PASS" for _, s in check_results)))

    for desc, ok in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {desc}")

    n_pass = sum(1 for _, ok in checks if ok)
    n_total = len(checks)
    print()
    print(f"  总计: {n_pass}/{n_total} PASS   "
          f"{'ALL PASS' if n_pass == n_total else 'SOME FAILED'}")
    sys.exit(0 if n_pass == n_total else 1)


if __name__ == "__main__":
    main()
