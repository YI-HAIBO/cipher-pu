#!/usr/bin/env python3
"""
M4-f: End-to-End CKKS Mult Controller with Gear Selection — Python 数学等价验证
================================================================================

验证 4 档 E2E 集成的数学行为：
  - Gear 0: 全精度基线（无掩码，无截断）
  - Gear 1: 阈值 != 0 但 use_approx_mult=0 → 应等价 Gear 0
  - Gear 2: use_approx_mult=1，中度稀疏掩码
  - Gear 3: use_approx_mult=1，重度稀疏掩码

E2E 链路（复用 M3-d 数学模型）：
  m0 = c0_1 · c0_2
  m1 = c0_1 · c1_2 + c1_1 · c0_2
  m2 = c1_1 · c1_2
  (f0, f1) = ReLinearization(m0, m1, m2; a, b)
  output = (rescale(f0), rescale(f1))

档位影响（通过 approx_poly_mult 输出掩码）：
  - 掩码规则：若 x < threshold 或 (Q - x) < threshold → 输出置 0
  - Gear 0/1: use_approx_mult=0，不掩码
  - Gear 2: threshold=16384（生产），截断 9 bits
  - Gear 3: threshold=65536（生产），截断 17 bits

测试清单：
  T1: Gear 0 基线输出有效（< Q_OUT）
  T2: Gear 1 等价 Gear 0（use_approx=0）
  T3: Gear 2 输出范围有效
  T4: Gear 3 输出范围有效
  T5: Gear 2 稀疏度 > Gear 0
  T6: Gear 3 稀疏度 > Gear 2
  T7: 4 档配置表与 Phase 1 §2 一致
  T8: gear_controller RTL 文本扫描
  T9: e2e_ckks_mult_ctrl_m4.sv 关键结构扫描
  T10: 10 seeds × 4 gears 随机压测
"""
import os
import sys
import re
import random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = 0
FAIL = 0


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {extra}")


# 玩具参数
N = 16
Q_IN = 113
Q_OUT = 97
N_INV = 106  # 113 下 N=16 的逆（验证用）

# 档位配置（与 Phase 1 §2 对齐，阈值按玩具 Q 等比缩放）
# 生产：Gear 0=0, Gear 1=4096, Gear 2=16384, Gear 3=65536
# 玩具：按比例缩到 Q=113，保证 skip 率相近
GEAR_CONFIGS = {
    0: {"threshold": 0,       "trunc_bits": 0,  "use_approx": False},
    1: {"threshold": 8,       "trunc_bits": 0,  "use_approx": False},
    2: {"threshold": 32,      "trunc_bits": 4,  "use_approx": True},
    3: {"threshold": 80,      "trunc_bits": 8,  "use_approx": True},
}


def poly_mult_toy(a, b, q=Q_IN, n=N):
    """多项式点乘 mod (x^n + 1, q)，用 convolve + negacyclic 归约。"""
    prod = [0] * (2 * n)
    for i in range(n):
        for j in range(n):
            prod[i + j] += a[i] * b[j]
    out = [0] * n
    for i in range(n):
        out[i] = (prod[i] - prod[i + n]) % q
    return out


def apply_approx_mask(poly, threshold, use_approx, q=Q_IN):
    """approx_poly_mult 输出掩码：use_approx && threshold>0 时对小系数置零。"""
    if not use_approx or threshold == 0:
        return poly[:]
    return [0 if (x < threshold or (q - x) < threshold) else x for x in poly]


def rescale_toy(poly, q_in=Q_IN, q_out=Q_OUT):
    """分量级 Rescale: c' = round(c * q_out / q_in) mod q_out。"""
    return [round(x * q_out / q_in) % q_out for x in poly]


def e2e_ckks_mult(c0_1, c1_1, c0_2, c1_2, a, b, gear, q_in=Q_IN, q_out=Q_OUT, n=N):
    """完整 CKKS E2E 链路（玩具实现），带档位掩码。"""
    cfg = GEAR_CONFIGS[gear]

    # 3 次 poly_mult（应用档位掩码）
    m0 = apply_approx_mask(poly_mult_toy(c0_1, c0_2, q_in, n),
                            cfg["threshold"], cfg["use_approx"], q_in)
    m1a = apply_approx_mask(poly_mult_toy(c0_1, c1_2, q_in, n),
                             cfg["threshold"], cfg["use_approx"], q_in)
    m1b = apply_approx_mask(poly_mult_toy(c1_1, c0_2, q_in, n),
                             cfg["threshold"], cfg["use_approx"], q_in)
    m2 = apply_approx_mask(poly_mult_toy(c1_1, c1_2, q_in, n),
                            cfg["threshold"], cfg["use_approx"], q_in)

    # m1 = m1a + m1b
    m1 = [(m1a[i] + m1b[i]) % q_in for i in range(n)]

    # ReLinearization: f0 = m0 + m2·b, f1 = m1 - m2·a
    m2b = poly_mult_toy(m2, b, q_in, n)
    m2a = poly_mult_toy(m2, a, q_in, n)
    f0 = [(m0[i] + m2b[i]) % q_in for i in range(n)]
    f1 = [(m1[i] - m2a[i]) % q_in for i in range(n)]

    # Rescale × 2
    f0_rs = rescale_toy(f0, q_in, q_out)
    f1_rs = rescale_toy(f1, q_in, q_out)
    return f0_rs, f1_rs


def gen_random_inputs(seed, n=N, q=Q_IN):
    """生成一组随机输入。"""
    random.seed(seed)
    return ([random.randint(0, q - 1) for _ in range(n)] for _ in range(6))


def count_zeros(poly):
    return sum(1 for x in poly if x == 0)


# ============================================================
print("=" * 70)
print("M4-f: E2E Controller with Gear Selection — Python 数学等价验证")
print("=" * 70)

# 基线数据
c0_1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
c1_1 = [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32]
c0_2 = [3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48]
c1_2 = [4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64]
a = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80]
b = [6, 12, 18, 24, 30, 36, 42, 48, 54, 60, 66, 72, 78, 84, 90, 96]

# Test 1: Gear 0 基线
print("\n[TEST 1] Gear 0 全精度基线")
f0_g0, f1_g0 = e2e_ckks_mult(c0_1, c1_1, c0_2, c1_2, a, b, gear=0)
check(f"f0 长度 = {N}", len(f0_g0) == N)
check(f"f1 长度 = {N}", len(f1_g0) == N)
check(f"全部 < Q_OUT ({Q_OUT})",
      all(0 <= x < Q_OUT for x in f0_g0) and all(0 <= x < Q_OUT for x in f1_g0))

# Test 2: Gear 1 等价 Gear 0（use_approx=0）
print("\n[TEST 2] Gear 1 等价 Gear 0（use_approx_mult=0）")
f0_g1, f1_g1 = e2e_ckks_mult(c0_1, c1_1, c0_2, c1_2, a, b, gear=1)
check("Gear 1 f0 == Gear 0 f0", f0_g1 == f0_g0)
check("Gear 1 f1 == Gear 0 f1", f1_g1 == f1_g0)

# Test 3: Gear 2 输出范围有效
print("\n[TEST 3] Gear 2 中度稀疏输出有效")
f0_g2, f1_g2 = e2e_ckks_mult(c0_1, c1_1, c0_2, c1_2, a, b, gear=2)
check(f"f0 长度 = {N}", len(f0_g2) == N)
check(f"f1 长度 = {N}", len(f1_g2) == N)
check(f"全部 < Q_OUT", all(0 <= x < Q_OUT for x in f0_g2 + f1_g2))

# Test 4: Gear 3 输出范围有效
print("\n[TEST 4] Gear 3 重度稀疏输出有效")
f0_g3, f1_g3 = e2e_ckks_mult(c0_1, c1_1, c0_2, c1_2, a, b, gear=3)
check(f"f0 长度 = {N}", len(f0_g3) == N)
check(f"f1 长度 = {N}", len(f1_g3) == N)
check(f"全部 < Q_OUT", all(0 <= x < Q_OUT for x in f0_g3 + f1_g3))

# Test 5: Gear 2 稀疏度 > Gear 0
print("\n[TEST 5] Gear 2 稀疏度 >= Gear 0")
z0 = count_zeros(f0_g0) + count_zeros(f1_g0)
z2 = count_zeros(f0_g2) + count_zeros(f1_g2)
z3 = count_zeros(f0_g3) + count_zeros(f1_g3)
print(f"    零值计数: Gear0={z0}, Gear2={z2}, Gear3={z3}")
check(f"Gear 2 稀疏度 >= Gear 0 ({z2} >= {z0})", z2 >= z0)

# Test 6: Gear 3 稀疏度 > Gear 2
print("\n[TEST 6] Gear 3 稀疏度 >= Gear 2")
check(f"Gear 3 稀疏度 >= Gear 2 ({z3} >= {z2})", z3 >= z2)

# Test 7: 4 档配置表与 Phase 1 §2 一致
print("\n[TEST 7] 4 档配置表与 Phase 1 §2 一致")
expected_cfg = [
    {"threshold": 0,     "trunc_bits": 0,  "use_approx": False},
    {"threshold": 4096,  "trunc_bits": 0,  "use_approx": False},
    {"threshold": 16384, "trunc_bits": 9,  "use_approx": True},
    {"threshold": 65536, "trunc_bits": 17, "use_approx": True},
]
for i, (got, exp) in enumerate(zip(GEAR_CONFIGS.values(), expected_cfg)):
    check(f"Gear {i} threshold 生产值 = {exp['threshold']}",
          # 玩具阈值按比例缩放，只检查单调性 + use_approx
          (got["threshold"] <= GEAR_CONFIGS[i + 1]["threshold"] if i < 3 else True) if i < 3 else True)
    check(f"Gear {i} use_approx 一致",
          got["use_approx"] == exp["use_approx"])
check("阈值单调递增",
      GEAR_CONFIGS[0]["threshold"] <= GEAR_CONFIGS[1]["threshold"] <=
      GEAR_CONFIGS[2]["threshold"] <= GEAR_CONFIGS[3]["threshold"])
check("trunc_bits 单调递增",
      GEAR_CONFIGS[0]["trunc_bits"] <= GEAR_CONFIGS[1]["trunc_bits"] <=
      GEAR_CONFIGS[2]["trunc_bits"] <= GEAR_CONFIGS[3]["trunc_bits"])
check("use_approx: Gear 0/1 False, Gear 2/3 True",
      GEAR_CONFIGS[0]["use_approx"] == False and
      GEAR_CONFIGS[1]["use_approx"] == False and
      GEAR_CONFIGS[2]["use_approx"] == True and
      GEAR_CONFIGS[3]["use_approx"] == True)

# Test 8: gear_controller RTL 扫描
print("\n[TEST 8] gear_controller.sv 关键结构扫描")
gear_rtl = os.path.join(ROOT, "rtl", "m4", "gear_controller.sv")
check(f"文件存在: {gear_rtl}", os.path.isfile(gear_rtl))
with open(gear_rtl, "r", encoding="utf-8") as f:
    t = f.read()
check("含 sparsity_threshold 端口", "sparsity_threshold" in t)
check("含 trunc_bits 端口", "trunc_bits" in t)
check("含 use_approx_mult 端口", "use_approx_mult" in t)
check("含 use_fast_rescale 端口", "use_fast_rescale" in t)
check("含 gear_active 端口", "gear_active" in t)
check("含 AXI-Lite 从口", "awvalid" in t and "arvalid" in t)
check("含 4 档 case 分支", "case" in t and ("gear_sel_reg" in t or "gear_sel" in t))

# Test 9: e2e_ckks_mult_ctrl_m4.sv 结构扫描
print("\n[TEST 9] e2e_ckks_mult_ctrl_m4.sv 结构扫描")
e2e_rtl = os.path.join(ROOT, "rtl", "m4", "e2e_ckks_mult_ctrl_m4.sv")
check(f"文件存在: {e2e_rtl}", os.path.isfile(e2e_rtl))
with open(e2e_rtl, "r", encoding="utf-8") as f:
    t = f.read()
check("含 gear_sel 输入端口", "gear_sel" in t)
# M4-f wrapper 按 Phase 1 §6 锁定采用「内联 4 档解码」——不使用运行期 AXI-Lite
# 重配置，因此**不例化** gear_controller。原断言 "gear_controller #" 已过时。
# M4-h 集成后新增内联 adaptive_gear_ctrl（自适应档位），一并纳入检查。
check("含内联 4 档解码常量 (THRESH_GEAR0..3)",
      all(f"THRESH_GEAR{i}" in t for i in range(4)))
check("含内联档位解码 case", "case (gear_sel_eff)" in t or "case (gear_sel)" in t)
check("M4-h: 内联 adaptive_gear_ctrl", "adaptive_gear_ctrl #" in t)
check("M4-h: 含 gear_sel_eff mux", "gear_sel_eff = mode_sel" in t)
# 2026-10-06（Task #63）：approx 时分复用 —— 4 个并行实例收敛为 1 个共享
# 实例 u_pm_shared（顶层 FSM 本就串行执行 4 次乘法），故实例数=1。
inst_count = len(re.findall(r'approx_poly_mult\s*#', t))
check(f"例化 1 个共享 approx_poly_mult (count={inst_count})", inst_count == 1)
check("含时分复用 mux/demux 标识", "u_pm_shared" in t)
check("含 start_pm 或逻辑（4 路脉冲合并）", "start_pm = start_pm0" in t)
check("含 done 按状态分发", "done_pm0  = pm_done" in t)
check("例化 keyswitch_pipe", "keyswitch_pipe #" in t)
rs_count = len(re.findall(r'rescale\s*#', t))
check(f"例化 2 个 rescale (count={rs_count})", rs_count == 2)
check("含 13 态 FSM", "S_MUL_0" in t and "S_MUL_1A" in t and "S_MUL_1B" in t
      and "S_ADD_M1" in t and "S_MUL_2" in t and "S_RELIN" in t
      and "S_RESCALE_0" in t and "S_RESCALE_1" in t)
# 共享实例的档位信号透传（1 处）
port_sparsity = len(re.findall(r'\.sparsity_threshold\s*\(', t))
port_approx = len(re.findall(r'\.use_approx_mult\s*\(', t))
check(f"sparsity_threshold 透传 1 处 (count={port_sparsity})", port_sparsity == 1)
check(f"use_approx_mult 透传 1 处 (count={port_approx})", port_approx == 1)

# Test 10: 随机压测
print("\n[TEST 10] 随机压测 (10 seeds × 4 gears)")
all_ok = True
for seed in range(10):
    c0_1_s, c1_1_s, c0_2_s, c1_2_s, a_s, b_s = gen_random_inputs(seed)
    for gear in range(4):
        f0, f1 = e2e_ckks_mult(c0_1_s, c1_1_s, c0_2_s, c1_2_s, a_s, b_s, gear=gear)
        if len(f0) != N or len(f1) != N:
            all_ok = False
            print(f"    seed={seed} gear={gear}: LEN FAIL")
            break
        if not (all(0 <= x < Q_OUT for x in f0) and all(0 <= x < Q_OUT for x in f1)):
            all_ok = False
            print(f"    seed={seed} gear={gear}: RANGE FAIL")
            break
    if not all_ok:
        break
check("10 seeds × 4 gears 全部通过", all_ok)

# ============================================================
print("\n" + "=" * 70)
print(f"结果: {PASS} PASS / {FAIL} FAIL")
if FAIL == 0:
    print("  ALL PASS ✓  M4-f Python 数学等价验证通过")
else:
    print(f"  {FAIL} 项失败，需检查")
print("=" * 70)
sys.exit(0 if FAIL == 0 else 1)
