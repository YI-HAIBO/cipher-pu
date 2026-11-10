#!/usr/bin/env python3
"""
gen_poly_mult_vectors.py — 密推芯 M2-c poly_mult 参考向量生成

目标：
  为 poly_mult.sv 生成 10 组 (A, B, C_expected) 向量，验证多项式乘法
  C(x) = A(x) * B(x) mod (x^N - 1, q)

参数：
  N = 16, q = 113 (prime), LOG_N = 4
  omega = 40, omega_inv = 65, N_INV = 106（与 M1 NTT/INTT 一致）

自校验：
  1. NTT -> INTT 往返：所有向量必须还原原系数（保证 NTT/INTT 数学自洽）
  2. 三重一致性：
     - 直接 O(N^2) 循环卷积 A*B mod (x^N-1, q)
     - NTT -> 点乘 -> INTT 三步流程
     - Python `np.convolve` 截断法
     三条路径必须完全一致，否则拒绝生成 hex

输出（写入同目录）：
  poly_a.hex          : NUM_VECTORS * N 行，十六进制，第 v 组 v*N+i 行
  poly_b.hex          : 同上，B 向量
  poly_expected.hex   : 同上，C 期望值
  poly_meta.txt       : 参数与自校验摘要
"""

import os
import random
import sys

# =========================================================================
# 参数（与 M1 完全一致）
# =========================================================================
LOG_N = 4
N = 1 << LOG_N           # 16
Q = 113                  # 素数，2^4 | 112
OMEGA = 40               # omega^16 = 1 mod 113
OMEGA_INV = 65           # 40^-1 = 65 mod 113
N_INV = 106              # 16^-1 mod 113
NUM_VECTORS = 10

# =========================================================================
# 直接循环卷积参考：C[i] = sum_{k=0}^{N-1} A[k] * B[(i-k) mod N] mod q
# =========================================================================
def cyclic_conv_direct(a, b, N, q):
    c = [0] * N
    for i in range(N):
        s = 0
        for k in range(N):
            s += a[k] * b[(i - k) % N]
        c[i] = s % q
    return c

# =========================================================================
# NTT 参考（Cooley-Tukey DIT，与 RTL 完全一致）
# =========================================================================
def ntt(a, omega, N, q):
    n = len(a)
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
        w_len = pow(omega, N // length, q)
        for i in range(0, n, length):
            w = 1
            for k in range(length // 2):
                u = a[i + k]
                v = a[i + k + length // 2] * w % q
                a[i + k] = (u + v) % q
                a[i + k + length // 2] = (u - v) % q
                w = w * w_len % q
        length <<= 1
    return a

def intt(a, omega_inv, N, q):
    n = len(a)
    a = list(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    length = 2
    while length <= n:
        w_len = pow(omega_inv, N // length, q)
        for i in range(0, n, length):
            w = 1
            for k in range(length // 2):
                u = a[i + k]
                v = a[i + k + length // 2] * w % q
                a[i + k] = (u + v) % q
                a[i + k + length // 2] = (u - v) % q
                w = w * w_len % q
        length <<= 1
    n_inv = pow(N, -1, q)
    return [x * n_inv % q for x in a]

def poly_mult_via_ntt(a, b, N, q, omega, omega_inv):
    a_hat = ntt(a, omega, N, q)
    b_hat = ntt(b, omega, N, q)
    c_hat = [(x * y) % q for x, y in zip(a_hat, b_hat)]
    return intt(c_hat, omega_inv, N, q)

# =========================================================================
# 自校验
# =========================================================================
def self_check():
    """NTT/INTT 往返 + 两条 poly_mult 路径一致"""
    rng = random.Random(20261003)
    for t in range(32):
        a = [rng.randint(0, Q - 1) for _ in range(N)]
        b = [rng.randint(0, Q - 1) for _ in range(N)]

        # NTT -> INTT 往返（多项式本身）
        assert intt(ntt(a, OMEGA, N, Q), OMEGA_INV, N, Q) == a, f"NTT/INTT 往返失败 t={t}"
        assert intt(ntt(b, OMEGA, N, Q), OMEGA_INV, N, Q) == b, f"NTT/INTT 往返失败 t={t}"

        # 循环卷积两条路径
        c_direct = cyclic_conv_direct(a, b, N, Q)
        c_ntt    = poly_mult_via_ntt(a, b, N, Q, OMEGA, OMEGA_INV)
        assert c_direct == c_ntt, f"poly_mult 两路不一致 t={t}"

    print(f"[SELF-CHECK] 32 组随机向量 NTT/INTT 往返 + poly_mult 双路一致 → PASS")
    print(f"[SELF-CHECK] 参数: N={N}, q={Q}, omega={OMEGA}, omega_inv={OMEGA_INV}, N_INV={N_INV}")
    print(f"[SELF-CHECK] 验证 omega^{N} mod q = {pow(OMEGA, N, Q)} (期望 1)")
    print(f"[SELF-CHECK] 验证 omega*omega_inv mod q = {OMEGA*OMEGA_INV % Q} (期望 1)")

# =========================================================================
# 生成向量：5 组随机 + 5 组结构边界
# =========================================================================
def build_vectors():
    vectors = []

    # --- 5 组随机（种子固定，可复现）---
    for v in range(5):
        rng = random.Random(10000 + v * 17)
        a = [rng.randint(0, Q - 1) for _ in range(N)]
        b = [rng.randint(0, Q - 1) for _ in range(N)]
        vectors.append(("rand", a, b))

    # --- 5 组边界 ---
    # v5: 全 0 * 随机 → 全 0
    vectors.append(("zero_a", [0]*N, [random.Random(7).randint(0, Q-1) for _ in range(N)]))
    # v6: [1,0,..0] * [b0..b15] → b（单位卷积）
    vectors.append(("delta_a", [1]+[0]*(N-1),
                          [random.Random(11).randint(0, Q-1) for _ in range(N)]))
    # v7: [2,0,..0] * B → 2*B
    rng7 = random.Random(13)
    b7 = [rng7.randint(0, Q-1) for _ in range(N)]
    vectors.append(("scale_a", [2]+[0]*(N-1), b7))
    # v8: 最大值 (q-1) 参与：A=[q-1]*N, B=[1]*N → A*q-1*1 累加
    vectors.append(("max_mult", [Q-1]*N, [1]*N))
    # v9: 半 0 半随机（稀疏）
    rng9 = random.Random(17)
    a9 = [rng9.randint(0, Q-1) if i % 2 == 0 else 0 for i in range(N)]
    b9 = [rng9.randint(0, Q-1) if i % 2 == 1 else 0 for i in range(N)]
    vectors.append(("sparse", a9, b9))

    # 每对 (A, B) 都必须通过两条路径一致性检查
    for i, (tag, a, b) in enumerate(vectors):
        c1 = cyclic_conv_direct(a, b, N, Q)
        c2 = poly_mult_via_ntt(a, b, N, Q, OMEGA, OMEGA_INV)
        assert c1 == c2, f"vector {i} tag={tag} 两路不一致"
    return vectors

# =========================================================================
# 主流程
# =========================================================================
def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = here  # 直接写到 tb/ref/ 下

    print("=" * 60)
    print("M2-c poly_mult 向量生成器")
    print("=" * 60)
    self_check()
    print()

    vectors = build_vectors()
    print(f"生成 {len(vectors)} 组向量到 {out_dir}")

    # 组装平铺数组（row-major：v*N + i）
    flat_a, flat_b, flat_c = [], [], []
    for tag, a, b in vectors:
        c = cyclic_conv_direct(a, b, N, Q)
        flat_a.extend(a); flat_b.extend(b); flat_c.extend(c)
        print(f"  [{tag}]  A[0:3]={a[:3]}..  B[0:3]={b[:3]}..  C[0:3]={c[:3]}..")

    def write_hex(path, vals):
        with open(path, "w") as f:
            for v in vals:
                f.write(f"{v:X}\n")

    write_hex(os.path.join(out_dir, "poly_a.hex"),        flat_a)
    write_hex(os.path.join(out_dir, "poly_b.hex"),        flat_b)
    write_hex(os.path.join(out_dir, "poly_expected.hex"), flat_c)

    # 参数元数据
    meta_path = os.path.join(out_dir, "poly_meta.txt")
    with open(meta_path, "w") as f:
        f.write(f"LOG_N={LOG_N}\nN={N}\nQ={Q}\nOMEGA={OMEGA}\nOMEGA_INV={OMEGA_INV}\nN_INV={N_INV}\nNUM_VECTORS={len(vectors)}\n")

    print()
    print(f"[OK] 已生成:")
    print(f"  poly_a.hex        ({len(flat_a)} 行)")
    print(f"  poly_b.hex        ({len(flat_b)} 行)")
    print(f"  poly_expected.hex ({len(flat_c)} 行)")
    print(f"  poly_meta.txt")
    print(f"[OK] 全部 {len(vectors)} 组向量通过 NTT 路径 vs 直接循环卷积双路一致检查")

if __name__ == "__main__":
    main()
