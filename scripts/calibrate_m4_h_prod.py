#!/usr/bin/env python3
"""
M4-h.2 生产参数标定
====================

从 verify_m4_h_adaptive.py 已锁定的生产参数出发（N=2^14, Q=2^44+131073,
R_INIT=1/2^24, R_MAX=0.5），把自适应档位控制器的 3 个阈值（THRESH_G1/G2/G3）
标定到 Q_WIDTH=45 的整数能量域，并计算 noise_monitor 的 ACC_W/SQ_W 位宽要求。

标定方法：
  1. 每档 r_critical(g) = R_MAX / total_growth(g)   (下一层 r 仍 < R_MAX 的上限)
  2. 对应能量阈值 E(g) = (r_critical * Q)^2         (E[s^2] = sigma^2)
  3. 阈值排序：Gear 3 阈值最小（能量最低），Gear 0 阈值最大

安全 margin：把每个阈值向下乘 0.9（避免边界误选高档）

输出：
  - 生产参数表（Markdown）
  - 4 档 r_critical / E 阈值 / total_growth / max_depth
  - ACC_W / SQ_W 位宽要求
  - 玩具 vs 生产对照表
"""
import math
import sys
from typing import Tuple

# ==== 生产参数（与 verify_m4_h_adaptive.py 对齐）====
N_PROD = 2 ** 14
Q_PROD = 2 ** 44 + 131073
Q_WIDTH = 45
R_INIT = 1.0 / (1 << 24)
R_MAX = 0.5
BASE_GROWTH = 1.55
SIGMA_0 = Q_PROD * R_INIT  # = 2^20 = 1048576

# 4 档配置
GEO = [
    {"name": "Gear 0", "threshold": 0,     "trunc_bits": 0,  "use_approx": False, "skip_rate": 0.00, "throughput": 1.0},
    {"name": "Gear 1", "threshold": 4096,  "trunc_bits": 0,  "use_approx": False, "skip_rate": 0.15, "throughput": 1.3},
    {"name": "Gear 2", "threshold": 16384, "trunc_bits": 9,  "use_approx": True,  "skip_rate": 0.30, "throughput": 2.0},
    {"name": "Gear 3", "threshold": 65536, "trunc_bits": 17, "use_approx": True,  "skip_rate": 0.50, "throughput": 3.0},
]

# 安全 margin：把每个阈值向下收缩 10%（避免边界 r 恰好在临界点时误选高档）
SAFETY_FRAC = 0.9


def compute_extra(g: dict):
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
        return 10 ** 6
    return int(math.log(R_MAX / R_INIT) / math.log(tot))


def r_critical(g: dict) -> float:
    """下一层 r 仍 < R_MAX 的上限：r_crit = R_MAX / total_growth"""
    return R_MAX / total_growth(g)


def energy_threshold(g: dict) -> int:
    """能量阈值 E = (r_crit * Q)^2 * safety_margin"""
    e = (r_critical(g) * Q_PROD) ** 2
    return int(e * SAFETY_FRAC)


def bits_needed(v: int) -> int:
    """计算 v 需要的最小位宽"""
    if v <= 0:
        return 1
    return v.bit_length()


def main():
    print("=" * 78)
    print("M4-h.2 生产参数标定")
    print("=" * 78)
    print(f"  N             = 2^14 = {N_PROD}")
    print(f"  Q             = 2^44 + 131073 = {Q_PROD}")
    print(f"  Q_WIDTH       = {Q_WIDTH}")
    print(f"  R_INIT        = 2^-24 = {R_INIT:.6e}")
    print(f"  R_MAX         = {R_MAX}")
    print(f"  BASE_GROWTH   = {BASE_GROWTH}")
    print(f"  SIGMA_0       = Q * R_INIT = {SIGMA_0:.6e}")
    print(f"  SAFETY_FRAC   = {SAFETY_FRAC}")

    print()
    print("-" * 78)
    print("各档总增长率、最大深度、能量阈值")
    print("-" * 78)
    print(f"  {'Gear':<8} {'growth':>10} {'depth':>6} {'r_crit':>10} {'E_th':>18} {'bits':>5}")
    print("-" * 78)
    for g in GEO:
        tg = total_growth(g)
        md = max_depth(g)
        rc = r_critical(g)
        et = energy_threshold(g)
        b = bits_needed(et)
        print(f"  {g['name']:<8} {tg:>10.4f} {md:>6} {rc:>10.5f} {et:>18d} {b:>5}")

    # ==== 阈值排序（THRESH_G1 / G2 / G3）====
    print()
    print("-" * 78)
    print("自适应档位控制器阈值映射（energy_q2 < THRESH_Gx → 选对应 gear）")
    print("-" * 78)
    # THRESH_G3 < THRESH_G2 < THRESH_G1（能量越小，档位越高）
    thresh_g3 = energy_threshold(GEO[3])  # 最小，触发 Gear 3
    thresh_g2 = energy_threshold(GEO[2])
    thresh_g1 = energy_threshold(GEO[1])
    print(f"  THRESH_G3 = {thresh_g3}  ({bits_needed(thresh_g3)} bits)  → energy < 此值选 Gear 3")
    print(f"  THRESH_G2 = {thresh_g2}  ({bits_needed(thresh_g2)} bits)  → energy < 此值选 Gear 2")
    print(f"  THRESH_G1 = {thresh_g1}  ({bits_needed(thresh_g1)} bits)  → energy < 此值选 Gear 1")
    print(f"  (energy >= THRESH_G1 时选 Gear 0)")

    # ==== 位宽计算 ====
    print()
    print("-" * 78)
    print("noise_monitor 位宽要求")
    print("-" * 78)
    sq_w = 2 * Q_WIDTH  # s^2 位宽
    log_n = math.log2(N_PROD)
    acc_w = sq_w + int(log_n) + 1  # sum(s^2) 位宽 + 1 bit 保余量
    print(f"  SQ_W  = 2 * Q_WIDTH           = {sq_w} bit   (s^2 位宽)")
    print(f"  LOG_N = log2(N_PROD)          = {log_n:.1f}")
    print(f"  ACC_W = SQ_W + LOG_N + 1      = {acc_w} bit   (sum of s^2 位宽)")
    print(f"  能量输出 (energy_q2 = acc/n)  = SQ_W = {sq_w} bit")
    print(f"  阈值位宽 (max(THRESH_G*))    = {max(bits_needed(thresh_g1), bits_needed(thresh_g2), bits_needed(thresh_g3))} bit")

    # ==== 玩具 vs 生产对照 ====
    print()
    print("-" * 78)
    print("玩具 vs 生产 阈值对照表")
    print("-" * 78)
    print(f"  {'参数':<20} {'玩具 (M4-h 已跑)':<25} {'生产 (本标定)'}")
    print(f"  {'-'*20} {'-'*25} {'-'*25}")
    print(f"  {'THRESH_G1':<20} {500:<25} {thresh_g1}")
    print(f"  {'THRESH_G2':<20} {200:<25} {thresh_g2}")
    print(f"  {'THRESH_G3':<20} {50:<25}  {thresh_g3}")
    print(f"  {'ACC_W':<20} {64:<25} {acc_w}")
    print(f"  {'SQ_W':<20} {15:<25} {sq_w}")
    print(f"  {'Q_WIDTH':<20} {7:<25} {Q_WIDTH}")
    print(f"  {'N':<20} {16:<25} {N_PROD}")

    # ==== 64-bit 溢出检查 ====
    print()
    print("-" * 78)
    print("64-bit 溢出检查（adaptive_gear_ctrl 默认 ACC_W=64）")
    print("-" * 78)
    for name, v in [("THRESH_G3", thresh_g3), ("THRESH_G2", thresh_g2), ("THRESH_G1", thresh_g1)]:
        if v >= (1 << 64):
            print(f"  ⚠ {name} = {v} 超过 64-bit 上限 (1.844e19)，需要 ACC_W >= {bits_needed(v)}")
        else:
            print(f"  ✓ {name} = {v} 可放入 64-bit")

    # ==== 推荐配置 ====
    print()
    print("-" * 78)
    print("推荐生产配置")
    print("-" * 78)
    rec_acc_w = max(acc_w, max(bits_needed(thresh_g1), bits_needed(thresh_g2), bits_needed(thresh_g3))) + 1
    print(f"  ACC_W      = {rec_acc_w}  (累加器位宽)")
    print(f"  SQ_W       = {sq_w}  (平方位宽)")
    print(f"  THRESH_G1  = {thresh_g1}  ({bits_needed(thresh_g1)} bits)")
    print(f"  THRESH_G2  = {thresh_g2}  ({bits_needed(thresh_g2)} bits)")
    print(f"  THRESH_G3  = {thresh_g3}  ({bits_needed(thresh_g3)} bits)")

    # ==== 保存参数为 header 供后续脚本引用 ====
    out_dir = str(Path(__file__).resolve().parent)
    param_path = out_dir + "\\m4_h_prod_params.py"
    with open(param_path, "w", encoding="utf-8") as f:
        f.write("# Auto-generated by calibrate_m4_h_prod.py — do not edit\n")
        f.write(f"N_PROD = 2 ** 14\n")
        f.write(f"Q_PROD = 2 ** 44 + 131073\n")
        f.write(f"Q_WIDTH = {Q_WIDTH}\n")
        f.write(f"R_INIT = 1.0 / (1 << 24)\n")
        f.write(f"R_MAX = {R_MAX}\n")
        f.write(f"BASE_GROWTH = {BASE_GROWTH}\n")
        f.write(f"SIGMA_0 = Q_PROD * R_INIT  # = {SIGMA_0:.6e}\n")
        f.write(f"ACC_W = {rec_acc_w}\n")
        f.write(f"SQ_W = {sq_w}\n")
        f.write(f"THRESH_G1 = {thresh_g1}\n")
        f.write(f"THRESH_G2 = {thresh_g2}\n")
        f.write(f"THRESH_G3 = {thresh_g3}\n")
        f.write(f"SAFETY_FRAC = {SAFETY_FRAC}\n")
    print()
    print(f"[SAVE] 生产参数已写入: {param_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
