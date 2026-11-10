#!/usr/bin/env python3
"""
gen_ntt_reference.py — 密推芯 M1 NTT 参考模型
================================================

功能：
  生成 NTT/INTT 参考向量，用于验证 ntt_unit.sv 正确性。

参数：
  N = 2^LOG_N     : 多项式长度（M1 测试：N=16）
  q               : 素数模数（需满足 2^LOG_N | (q-1)）
  omega           : 原始 N 阶单位根（q 中满足 ω^N = 1）

M1 测试配置：
  N = 16, q = 113, LOG_N = 4
  omega = pow(g, (q-1)//N, q)  其中 g 是 q 的原始根

输出：
  tb/ref/ntt_input.mem   : 输入系数（每行一个）
  tb/ref/ntt_output.mem  : NTT 输出（每行一个）
  tb/ref/intt_output.mem : INTT 输出（验证往返）
"""

import sys
import os

# =========================================================================
# 参数配置
# =========================================================================
LOG_N = 4          # M1 测试：N=16
N = 1 << LOG_N     # 16
Q = 113            # 素数，2^4 | (113-1=112)
Q_WIDTH = 7        # 系数位宽（113 < 128 = 2^7）
NUM_VECTORS = 10   # 生成 10 组测试向量

# =========================================================================
# 找到 q 的原始根 g
# =========================================================================
def find_primitive_root(q):
    """找 q 的原始根（g 的阶为 q-1）"""
    # 分解 q-1
    factors = []
    temp = q - 1
    d = 2
    while d * d <= temp:
        if temp % d == 0:
            factors.append(d)
            while temp % d == 0:
                temp //= d
        d += 1
    if temp > 1:
        factors.append(temp)
    
    # 找原始根
    for g in range(2, q):
        is_gen = True
        for f in factors:
            if pow(g, (q-1)//f, q) == 1:
                is_gen = False
                break
        if is_gen:
            return g
    return None

# =========================================================================
# 计算 omega（原始 N 阶单位根）
# =========================================================================
g = find_primitive_root(Q)
print(f"Q = {Q}, g (primitive root) = {g}")

omega = pow(g, (Q-1)//N, Q)
print(f"N = {N}, omega (primitive N-th root) = {omega}")
print(f"Verify: omega^N mod q = {pow(omega, N, Q)} (should be 1)")

# =========================================================================
# NTT 实现（迭代 Cooley-Tukey DIT）
# =========================================================================
def ntt(a, omega, N, q):
    """NTT: 输入系数数组，返回 NTT 结果"""
    n = len(a)
    assert n == N
    a = list(a)
    
    # Bit-reversal permutation
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    
    # Butterfly
    length = 2
    while length <= n:
        w_len = pow(omega, N // length, q)  # ω^(N/length)
        for i in range(0, n, length):
            w = 1
            for k in range(length // 2):
                u = a[i + k]
                v = a[i + k + length//2] * w % q
                a[i + k] = (u + v) % q
                a[i + k + length//2] = (u - v) % q
                w = w * w_len % q
        length <<= 1
    
    return a

def intt(a, omega_inv, N, q):
    """INTT: 输入 NTT 结果，返回原系数（需末尾除以 N）"""
    n = len(a)
    assert n == N
    a = list(a)
    
    # Bit-reversal permutation
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    
    # Butterfly with omega^-1
    length = 2
    while length <= n:
        w_len = pow(omega_inv, N // length, q)
        for i in range(0, n, length):
            w = 1
            for k in range(length // 2):
                u = a[i + k]
                v = a[i + k + length//2] * w % q
                a[i + k] = (u + v) % q
                a[i + k + length//2] = (u - v) % q
                w = w * w_len % q
        length <<= 1
    
    # Scale by 1/N
    n_inv = pow(N, -1, q)  # Python 3.8+
    return [x * n_inv % q for x in a]

# =========================================================================
# 生成测试向量
# =========================================================================
output_dir = os.path.join(os.path.dirname(__file__), "ref")
if not os.path.exists(output_dir):
    os.makedirs(output_dir)

print(f"\n生成 {NUM_VECTORS} 组测试向量 (N={N}, q={Q})")
print(f"输出目录: {output_dir}\n")

for vec_idx in range(NUM_VECTORS):
    # 生成随机输入
    import random
    random.seed(42 + vec_idx)
    input_coeffs = [random.randint(0, Q-1) for _ in range(N)]
    
    # 计算 NTT
    ntt_result = ntt(input_coeffs, omega, N, Q)
    
    # 验证 INTT 往返
    omega_inv = pow(omega, -1, Q)
    intt_result = intt(ntt_result, omega_inv, N, Q)
    
    # 验证正确性
    assert input_coeffs == intt_result, f"INTT 往返失败 (vector {vec_idx})"
    
    # 写入文件
    input_file = os.path.join(output_dir, f"ntt_input_{vec_idx}.mem")
    output_file = os.path.join(output_dir, f"ntt_output_{vec_idx}.mem")
    intt_file = os.path.join(output_dir, f"intt_output_{vec_idx}.mem")
    
    with open(input_file, "w") as f:
        for c in input_coeffs:
            f.write(f"{c}\n")
    
    with open(output_file, "w") as f:
        for c in ntt_result:
            f.write(f"{c}\n")
    
    with open(intt_file, "w") as f:
        for c in intt_result:
            f.write(f"{c}\n")
    
    print(f"Vector {vec_idx}:")
    print(f"  Input:  {input_coeffs}")
    print(f"  NTT:    {ntt_result}")
    print(f"  INTT:   {intt_result}")
    print(f"  Files:  {os.path.basename(input_file)}, {os.path.basename(output_file)}")
    print()

print("✓ 参考向量生成完成，INTT 往返验证通过")
print(f"  omega = {omega}")
print(f"  omega_inv = {omega_inv}")
print(f"  N_inv (1/N mod q) = {pow(N, -1, Q)}")

# =========================================================================
# 生成综合参考文件（供 testbench 读取）
# =========================================================================
# 第一组向量作为默认测试向量
input_file = os.path.join(output_dir, "ntt_input.mem")
output_file = os.path.join(output_dir, "ntt_output.mem")
intt_file = os.path.join(output_dir, "intt_output.mem")

input_coeffs = [random.randint(0, Q-1) for _ in range(N)]
ntt_result = ntt(input_coeffs, omega, N, Q)

with open(input_file, "w") as f:
    for c in input_coeffs:
        f.write(f"{c}\n")

with open(output_file, "w") as f:
    for c in ntt_result:
        f.write(f"{c}\n")

print(f"\n综合参考文件:")
print(f"  {input_file}")
print(f"  {output_file}")
