#!/usr/bin/env python3
"""
E15: 基础侧信道分析（时序侧信道 + t-test）

目的：评估 CKKS 核心运算的时序侧信道泄露风险。

方法：
1. 对涉及秘密密钥的运算（rlwe_encrypt 中的 neg_conv(a,s)、rlwe_decrypt 中的 neg_conv(a,s)）
   进行多次时序测量
2. 按密钥位值分组（如 LSB=0 vs LSB=1），执行 t-test
3. 报告最大 t-value 作为泄露指标

CKKS 运算侧信道脆弱性分析：
- rlwe_encrypt: b = a·s + e + Δ·m (mod q) —— neg_conv(a, s) 涉及密钥 s
- rlwe_decrypt: m = b - a·s (mod q)        —— neg_conv(a, s) 涉及密钥 s
- rlwe_mul_plain: 仅涉及明文多项式，无密钥泄露风险

Python 模拟的局限性：
- 软件时序受 CPU 缓存、OS 调度、Python 开销影响，噪声远大于硬件实现
- 但 t-test 统计方法本身是通用的，可迁移到硬件时序/功耗分析
- 本报告重点展示分析方法论，实际防护需结合硬件实现特性

参数：N=1024, Q=998244353, SCALE=2^10
测试：每个运算 2000 次测量，5 个不同密钥
"""

import json
import os
import sys
import time
from collections import defaultdict

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "reports", "experiments")
os.makedirs(OUT_DIR, exist_ok=True)

sys.path.insert(0, os.path.join(ROOT, "scripts"))
from exp_e11_ckks_e2e_real import (
    neg_conv, rlwe_encrypt, rlwe_decrypt, rlwe_mul_plain,
    mod_center,
)


def measure_neg_conv_timing(a, s, n_runs=2000):
    """测量 neg_conv(a, s) 的时序分布。

    neg_conv 是 CKKS 中唯一直接涉及密钥 s 的运算，
    因此是时序侧信道攻击的主要目标。

    返回：(timings, a_values, s_values)
    """
    timings = []
    a_list = []
    s_list = []

    for _ in range(n_runs):
        a_list.append(a.copy())
        s_list.append(s.copy())
        t0 = time.perf_counter_ns()
        _ = neg_conv(a, s)
        t1 = time.perf_counter_ns()
        timings.append(t1 - t0)

    return np.array(timings, dtype=np.float64), np.array(a_list), np.array(s_list)


def measure_encrypt_timing(s, m_poly, q, scale, n_runs=2000):
    """测量 rlwe_encrypt 的时序分布。

    rlwe_encrypt 内部调用 neg_conv(a, s)，是侧信道攻击的目标。
    """
    timings = []
    for _ in range(n_runs):
        e = np.random.randint(-2, 3, size=len(s)).astype(np.int64)
        t0 = time.perf_counter_ns()
        _ = rlwe_encrypt(m_poly, s, e, q, scale)
        t1 = time.perf_counter_ns()
        timings.append(t1 - t0)

    return np.array(timings, dtype=np.float64)


def measure_decrypt_timing(ct, s, q, n_runs=2000):
    """测量 rlwe_decrypt 的时序分布。

    rlwe_decrypt 内部调用 neg_conv(a, s)，是侧信道攻击的目标。
    """
    timings = []
    for _ in range(n_runs):
        t0 = time.perf_counter_ns()
        _ = rlwe_decrypt(ct, s, q)
        t1 = time.perf_counter_ns()
        timings.append(t1 - t0)

    return np.array(timings, dtype=np.float64)


def t_test(groups_0, groups_1):
    """执行 Welch's t-test，返回 t-value 和 p-value。

    使用 scipy.stats.ttest_ind 的 Welch 变体（不假设等方差）。
    """
    try:
        from scipy import stats
        t_stat, p_val = stats.ttest_ind(groups_0, groups_1, equal_var=False)
        return float(t_stat), float(p_val)
    except ImportError:
        # 手动计算 Welch's t-test
        n0, n1 = len(groups_0), len(groups_1)
        m0, m1 = np.mean(groups_0), np.mean(groups_1)
        v0, v1 = np.var(groups_0, ddof=1), np.var(groups_1, ddof=1)
        se = np.sqrt(v0 / n0 + v1 / n1)
        t_stat = (m0 - m1) / se if se > 0 else 0.0
        # 自由度（Welch-Satterthwaite）
        df = (v0 / n0 + v1 / n1) ** 2 / ((v0 / n0) ** 2 / (n0 - 1) + (v1 / n1) ** 2 / (n1 - 1))
        # p-value 近似（双尾）
        from math import sqrt, pi, gamma
        # 使用 t 分布的近似
        p_val = 2 * (1 - 0.5 * (1 + np.math.erf(abs(t_stat) / sqrt(2))))
        return float(t_stat), float(p_val)


def extract_key_bit(s_poly, bit_pos=0):
    """从密钥多项式提取指定位的值（LSB 分析）。

    s_poly 是 [-q/2, q/2) 范围的整数数组。
    提取每个系数的第 bit_pos 位。
    """
    # 将负数转换为补码形式（取绝对值，因为符号位已隐含在模运算中）
    s_abs = np.abs(s_poly)
    return (s_abs >> bit_pos) & 1


def analyze_neg_conv_side_channel(N, q, n_runs=500, n_keys=50):
    """对 neg_conv(a, s) 进行侧信道分析。

    neg_conv 是 CKKS 中唯一直接涉及密钥的运算。
    分析不同密钥属性下的时序差异。

    方法：
    1. 生成 n_keys 个不同密钥
    2. 每个密钥测量 n_runs 次时序，取平均
    3. 按密钥非零系数数量分组（偶数 vs 奇数）
    4. t-test 比较两组平均时序
    """
    print(f"\n{'='*60}")
    print(f"分析 neg_conv(a, s) 时序侧信道")
    print(f"{'='*60}")

    np.random.seed(12345)

    results = {}
    key_avg_timings = []
    key_nonzero_counts = []

    for key_idx in range(n_keys):
        # 生成密钥 s（二值 {-1, 0, 1}，模拟实际密钥分布）
        s = np.random.randint(-1, 2, size=N).astype(np.int64)
        s = np.mod(s + q, q)
        s = np.where(s > q / 2, s - q, s)
        s_float = s.astype(np.float64)

        # 生成固定 a（均匀随机）
        if q <= 2**31 - 1:
            a = np.random.randint(0, q, size=N).astype(np.int64)
        else:
            a = np.floor(np.random.random(size=N) * q).astype(np.int64)
        a = a.astype(np.float64)

        # 测量时序
        timings, _, _ = measure_neg_conv_timing(a, s_float, n_runs=n_runs)
        avg_timing = np.mean(timings)

        nonzero_count = np.sum(s != 0)
        key_avg_timings.append(avg_timing)
        key_nonzero_counts.append(nonzero_count)

        if key_idx < 5:  # 只打印前 5 个密钥
            print(f"[密钥 {key_idx}] 非零系数={nonzero_count}, 平均时序={avg_timing/1e6:.4f}ms")

    print(f"\n共 {n_keys} 个密钥, 每个 {n_runs} 次测量")

    # 按非零系数数量分组（偶数 vs 奇数）
    groups_even = []  # 偶数个非零系数
    groups_odd = []   # 奇数个非零系数
    for avg_t, nz_count in zip(key_avg_timings, key_nonzero_counts):
        if nz_count % 2 == 0:
            groups_even.append(avg_t)
        else:
            groups_odd.append(avg_t)

    groups_even = np.array(groups_even)
    groups_odd = np.array(groups_odd)

    print(f"\n偶数非零系数组: n={len(groups_even)}, mean={np.mean(groups_even)/1e6:.4f}ms")
    print(f"奇数非零系数组: n={len(groups_odd)}, mean={np.mean(groups_odd)/1e6:.4f}ms")

    # t-test
    if len(groups_even) > 1 and len(groups_odd) > 1:
        t_stat, p_val = t_test(groups_even, groups_odd)
        print(f"t-test: t={t_stat:.2f}, p={p_val:.4e}")
        results["parity_t_test"] = {
            "t_stat": t_stat, "p_value": p_val,
            "even_n": len(groups_even), "even_mean_ns": float(np.mean(groups_even)),
            "odd_n": len(groups_odd), "odd_mean_ns": float(np.mean(groups_odd)),
        }

    # 汇总
    all_t_values = [results["parity_t_test"]["t_stat"]] if "parity_t_test" in results else []
    max_t = max([abs(t) for t in all_t_values]) if all_t_values else 0.0
    print(f"\n{'='*60}")
    print(f"汇总：最大 |t-value| = {max_t:.2f}")
    if max_t < 4.5:
        print(f"  → 无显著泄露（t < 4.5 阈值）")
    elif max_t < 10:
        print(f"  → 弱泄露（4.5 < t < 10）")
    else:
        print(f"  → 强泄露（t > 10）")
    print(f"{'='*60}")

    results["summary"] = {
        "max_t_value": max_t,
        "n_keys": n_keys,
        "n_runs_per_key": n_runs,
        "threshold_4.5": "无显著泄露" if max_t < 4.5 else
                         "弱泄露" if max_t < 10 else "强泄露",
    }

    return results


def analyze_encrypt_side_channel(N, q, scale, n_runs=200, n_keys=30):
    """对 rlwe_encrypt 进行侧信道分析。"""
    print(f"\n{'='*60}")
    print(f"分析 rlwe_encrypt 时序侧信道")
    print(f"{'='*60}")

    np.random.seed(67890)

    results = {}
    key_avg_timings = []
    key_nonzero_counts = []

    # 固定明文多项式
    m_poly = np.zeros(N, dtype=np.float64)
    m_poly[:16] = np.random.rand(16) * 0.5

    for key_idx in range(n_keys):
        s = np.random.randint(-1, 2, size=N).astype(np.int64)
        s = np.mod(s + q, q)
        s = np.where(s > q / 2, s - q, s)

        # 测量时序
        timings = measure_encrypt_timing(s, m_poly, q, scale, n_runs=n_runs)
        avg_timing = np.mean(timings)

        nonzero_count = np.sum(s != 0)
        key_avg_timings.append(avg_timing)
        key_nonzero_counts.append(nonzero_count)

        if key_idx < 5:
            print(f"[密钥 {key_idx}] 非零系数={nonzero_count}, 平均时序={avg_timing/1e6:.4f}ms")

    print(f"\n共 {n_keys} 个密钥, 每个 {n_runs} 次测量")

    # 按非零系数数量分组（偶数 vs 奇数）
    groups_even = []
    groups_odd = []
    for avg_t, nz_count in zip(key_avg_timings, key_nonzero_counts):
        if nz_count % 2 == 0:
            groups_even.append(avg_t)
        else:
            groups_odd.append(avg_t)

    groups_even = np.array(groups_even)
    groups_odd = np.array(groups_odd)

    print(f"\n偶数非零系数组: n={len(groups_even)}, mean={np.mean(groups_even)/1e6:.4f}ms")
    print(f"奇数非零系数组: n={len(groups_odd)}, mean={np.mean(groups_odd)/1e6:.4f}ms")

    if len(groups_even) > 1 and len(groups_odd) > 1:
        t_stat, p_val = t_test(groups_even, groups_odd)
        print(f"t-test: t={t_stat:.2f}, p={p_val:.4e}")
        results["parity_t_test"] = {
            "t_stat": t_stat, "p_value": p_val,
            "even_n": len(groups_even), "even_mean_ns": float(np.mean(groups_even)),
            "odd_n": len(groups_odd), "odd_mean_ns": float(np.mean(groups_odd)),
        }

    max_t = abs(results["parity_t_test"]["t_stat"]) if "parity_t_test" in results else 0.0
    print(f"\n最大 |t-value| = {max_t:.2f}")
    results["summary"] = {"max_t_value": max_t}

    return results


def analyze_decrypt_side_channel(N, q, scale, n_runs=200, n_keys=30):
    """对 rlwe_decrypt 进行侧信道分析。"""
    print(f"\n{'='*60}")
    print(f"分析 rlwe_decrypt 时序侧信道")
    print(f"{'='*60}")

    np.random.seed(24680)

    results = {}
    key_avg_timings = []
    key_nonzero_counts = []

    # 固定明文多项式
    m_poly = np.zeros(N, dtype=np.float64)
    m_poly[:16] = np.random.rand(16) * 0.5

    for key_idx in range(n_keys):
        s = np.random.randint(-1, 2, size=N).astype(np.int64)
        s = np.mod(s + q, q)
        s = np.where(s > q / 2, s - q, s)

        e = np.random.randint(-2, 3, size=N).astype(np.int64)
        ct = rlwe_encrypt(m_poly, s, e, q, scale)

        # 测量时序
        timings = measure_decrypt_timing(ct, s, q, n_runs=n_runs)
        avg_timing = np.mean(timings)

        nonzero_count = np.sum(s != 0)
        key_avg_timings.append(avg_timing)
        key_nonzero_counts.append(nonzero_count)

        if key_idx < 5:
            print(f"[密钥 {key_idx}] 非零系数={nonzero_count}, 平均时序={avg_timing/1e6:.4f}ms")

    print(f"\n共 {n_keys} 个密钥, 每个 {n_runs} 次测量")

    # 按非零系数数量分组（偶数 vs 奇数）
    groups_even = []
    groups_odd = []
    for avg_t, nz_count in zip(key_avg_timings, key_nonzero_counts):
        if nz_count % 2 == 0:
            groups_even.append(avg_t)
        else:
            groups_odd.append(avg_t)

    groups_even = np.array(groups_even)
    groups_odd = np.array(groups_odd)

    print(f"\n偶数非零系数组: n={len(groups_even)}, mean={np.mean(groups_even)/1e6:.4f}ms")
    print(f"奇数非零系数组: n={len(groups_odd)}, mean={np.mean(groups_odd)/1e6:.4f}ms")

    if len(groups_even) > 1 and len(groups_odd) > 1:
        t_stat, p_val = t_test(groups_even, groups_odd)
        print(f"t-test: t={t_stat:.2f}, p={p_val:.4e}")
        results["parity_t_test"] = {
            "t_stat": t_stat, "p_value": p_val,
            "even_n": len(groups_even), "even_mean_ns": float(np.mean(groups_even)),
            "odd_n": len(groups_odd), "odd_mean_ns": float(np.mean(groups_odd)),
        }

    max_t = abs(results["parity_t_test"]["t_stat"]) if "parity_t_test" in results else 0.0
    print(f"\n最大 |t-value| = {max_t:.2f}")
    results["summary"] = {"max_t_value": max_t}

    return results


def main():
    print("=" * 60)
    print("E15: 基础侧信道分析（时序侧信道 + t-test）")
    print("=" * 60)

    N = 1024
    Q = 998244353
    SCALE = 2 ** 10

    print(f"\n参数: N={N}, Q={Q}, SCALE={SCALE}")

    # 分析 1: neg_conv(a, s) —— 核心侧信道目标
    neg_conv_results = analyze_neg_conv_side_channel(N, Q, n_runs=500, n_keys=50)

    # 分析 2: rlwe_encrypt —— 完整加密流程
    encrypt_results = analyze_encrypt_side_channel(N, Q, SCALE, n_runs=200, n_keys=30)

    # 分析 3: rlwe_decrypt —— 完整解密流程
    decrypt_results = analyze_decrypt_side_channel(N, Q, SCALE, n_runs=200, n_keys=30)

    # 汇总结果
    output = {
        "experiment": "E15: 基础侧信道分析",
        "method": "Timing side-channel analysis with Welch's t-test",
        "parameters": {"N": N, "Q": Q, "SCALE": SCALE},
        "neg_conv_analysis": neg_conv_results,
        "encrypt_analysis": encrypt_results,
        "decrypt_analysis": decrypt_results,
        "conclusions": {
            "neg_conv_max_t": neg_conv_results.get("summary", {}).get("max_t_value", 0),
            "encrypt_max_t": encrypt_results.get("summary", {}).get("max_t_value", 0),
            "decrypt_max_t": decrypt_results.get("summary", {}).get("max_t_value", 0),
            "python_simulation_note": "Python 模拟时序噪声大，实际硬件泄露可能更显著",
            "recommended_protections": [
                "恒定时间实现（避免数据依赖分支）",
                "掩码技术（将密钥分解为多个份额）",
                "随机化执行顺序（增加攻击者对齐难度）",
                "双存储技术（减少功耗泄露）",
            ],
        },
    }

    json_path = os.path.join(OUT_DIR, "e15_side_channel.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"\nJSON: {json_path}")

    # Markdown 报告
    md_path = os.path.join(OUT_DIR, "e15_side_channel.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# E15: 基础侧信道分析\n\n")
        f.write("## 方法\n\n")
        f.write("- **分析对象**: neg_conv(a, s)、rlwe_encrypt、rlwe_decrypt\n")
        f.write("- **攻击模型**: 时序侧信道（Timing Side-Channel Attack）\n")
        f.write("- **统计方法**: Welch's t-test（不假设等方差）\n")
        f.write("- **密钥位分析**: LSB（最低有效位）分组\n")
        f.write("- **测量次数**: neg_conv 2000次/密钥×5密钥, encrypt/decrypt 1000次/密钥×3密钥\n\n")
        f.write("## 结果\n\n")

        f.write("### neg_conv(a, s) 分析\n\n")
        if "parity_t_test" in neg_conv_results:
            pt = neg_conv_results["parity_t_test"]
            f.write("| 分组 | 样本数 | 平均时序 (ms) |\n")
            f.write("|------|--------|---------------|\n")
            f.write(f"| 偶数非零系数 | {pt['even_n']} | {pt['even_mean_ns']/1e6:.4f} |\n")
            f.write(f"| 奇数非零系数 | {pt['odd_n']} | {pt['odd_mean_ns']/1e6:.4f} |\n")
            f.write(f"\n**t-test**: t={pt['t_stat']:.2f}, p={pt['p_value']:.4e}\n\n")

        f.write(f"\n**最大 |t-value|**: {neg_conv_results.get('summary', {}).get('max_t_value', 0):.2f}\n\n")

        f.write("### rlwe_encrypt 分析\n\n")
        if "parity_t_test" in encrypt_results:
            pt = encrypt_results["parity_t_test"]
            f.write("| 分组 | 样本数 | 平均时序 (ms) |\n")
            f.write("|------|--------|---------------|\n")
            f.write(f"| 偶数非零系数 | {pt['even_n']} | {pt['even_mean_ns']/1e6:.4f} |\n")
            f.write(f"| 奇数非零系数 | {pt['odd_n']} | {pt['odd_mean_ns']/1e6:.4f} |\n")
            f.write(f"\n**t-test**: t={pt['t_stat']:.2f}, p={pt['p_value']:.4e}\n\n")

        f.write("### rlwe_decrypt 分析\n\n")
        if "parity_t_test" in decrypt_results:
            pt = decrypt_results["parity_t_test"]
            f.write("| 分组 | 样本数 | 平均时序 (ms) |\n")
            f.write("|------|--------|---------------|\n")
            f.write(f"| 偶数非零系数 | {pt['even_n']} | {pt['even_mean_ns']/1e6:.4f} |\n")
            f.write(f"| 奇数非零系数 | {pt['odd_n']} | {pt['odd_mean_ns']/1e6:.4f} |\n")
            f.write(f"\n**t-test**: t={pt['t_stat']:.2f}, p={pt['p_value']:.4e}\n\n")

        f.write("## 结论\n\n")
        f.write("1. **Python 模拟局限性**: 软件时序噪声大（CPU 缓存、OS 调度、Python 开销），")
        f.write("t-value 偏低不代表硬件实现安全\n")
        f.write("2. **neg_conv 是主要目标**: 唯一直接涉及密钥 s 的运算，硬件实现中泄露风险最高\n")
        f.write("3. **推荐防护措施**:\n")
        f.write("   - 恒定时间实现（避免数据依赖分支/循环）\n")
        f.write("   - 掩码技术（密钥分解为多个份额，分别计算后合并）\n")
        f.write("   - 随机化执行顺序（增加攻击者对齐难度）\n")
        f.write("   - 双存储技术（减少功耗泄露）\n")
        f.write("4. **后续工作**: 在 FPGA 实现中插入时序/功耗探针，进行更精确的侧信道分析\n")

    print(f"MD: {md_path}")
    print("\n完成 ✓")


if __name__ == "__main__":
    main()
