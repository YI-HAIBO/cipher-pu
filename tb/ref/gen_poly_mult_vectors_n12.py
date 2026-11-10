#!/usr/bin/env python3
"""
gen_poly_mult_vectors_n12.py — 密推芯 N=2^12 生产配置向量生成（N=4096, q3）

目的：
  为 poly_mult 在 N=2^12 降级路径（Q_WIDTH=45, Q_VALUE=q3=17592186175489,
  USE_FASTRED=1）生成 (A, B, C_expected) 向量 + omega/omega_inv twiddle 表。

数学前提（硬件约定：标准正循环 DIT 蝶蝶 a'=a+b·ω, b'=a−b·ω）：
  q     = 17592186175489 = 2^44 + 131073 = 2^44 + (2^17 + 1)   （q3）
  q - 1 = 2^17 * 134217729  → 2-adic valuation = 17 ≥ 13 = LOG_N+1
  g     = 11（模 q 的本原根）
  omega = g^((q-1)/N) mod q   ← N 次单位根（omega^N = 1），硬件做正循环 NTT 用
  omega_inv = omega^(-1) mod q
  N_INV = N^(-1) mod q = 17587891208161

  注：CKKS 负循环需要的 2N 次本原根 psi = g^((q-1)/2N) = 15163019180936（满足
  psi^N = -1）。本硬件 NTT 引擎走正循环，故仿真用 omega = psi^2 mod q。

自校验（三重，沿用 gen_poly_mult_vectors_prod.py）：
  1. NTT -> INTT 往返还原
  2. 直接 O(N^2) 循环卷积 == NTT -> 点乘 -> INTT
  3. omega^N = 1 / omega*omega_inv = 1 / N*N_INV = 1

输出（写入同目录）：
  poly_a_n12.hex / poly_b_n12.hex / poly_expected_n12.hex   （NUM_VECTORS*N 行）
  omega_n12.hex / omega_inv_n12.hex                          （N/2 行）
  poly_meta_n12.txt                                          （参数摘要）
"""

import os
import random
import sys

# =========================================================================
# 参数（N=2^12 降级路径，q3 统一）
# =========================================================================
LOG_N = 12
N = 1 << LOG_N                      # 4096
C = (1 << 17) + 1                   # 131073
Q = (1 << 44) + C                   # 17592186175489 = q3
Q_WIDTH = 45
G = 11                              # primitive root mod q3
PSI = pow(G, (Q - 1) // (2 * N), Q)     # 2N 次本原根（CKKS 负循环用）
OMEGA = pow(PSI, 2, Q)                  # N 次单位根（硬件正循环用）
OMEGA_INV = pow(OMEGA, -1, Q)
N_INV = pow(N, -1, Q)
NUM_VECTORS = 4                     # N=4096 仿真较慢，4 组足够回归


# =========================================================================
# 参考实现（与 RTL 完全对齐：Cooley-Tukey DIT 正循环）
# =========================================================================
def bit_rev_perm(a, n):
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
    return a


def ntt(a, omega, N, q):
    a = bit_rev_perm(a, N)
    length = 2
    while length <= N:
        w_len = pow(omega, N // length, q)
        for i in range(0, N, length):
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
    a = bit_rev_perm(a, N)
    length = 2
    while length <= N:
        w_len = pow(omega_inv, N // length, q)
        for i in range(0, N, length):
            w = 1
            for k in range(length // 2):
                u = a[i + k]
                v = a[i + k + length // 2] * w % q
                a[i + k] = (u + v) % q
                a[i + k + length // 2] = (u - v + q) % q
                w = w * w_len % q
        length <<= 1
    n_inv = pow(N, -1, q)
    return [x * n_inv % q for x in a]


def poly_mult_via_ntt(a, b, N, q, omega, omega_inv):
    a_hat = ntt(a, omega, N, q)
    b_hat = ntt(b, omega, N, q)
    c_hat = [(x * y) % q for x, y in zip(a_hat, b_hat)]
    return intt(c_hat, omega_inv, N, q)


def cyclic_conv_direct(a, b, N, q):
    c = [0] * N
    for i in range(N):
        s = 0
        for k in range(N):
            s += a[k] * b[(i - k) % N]
        c[i] = s % q
    return c


# =========================================================================
# 自校验
# =========================================================================
def self_check():
    rng = random.Random(20261006)
    for t in range(4):
        a = [rng.randrange(Q) for _ in range(N)]
        b = [rng.randrange(Q) for _ in range(N)]
        assert intt(ntt(a, OMEGA, N, Q), OMEGA_INV, N, Q) == a, f"往返失败 a t={t}"
        c_direct = cyclic_conv_direct(a, b, N, Q)
        c_ntt = poly_mult_via_ntt(a, b, N, Q, OMEGA, OMEGA_INV)
        assert c_direct == c_ntt, f"poly_mult 两路不一致 t={t}"

    assert pow(OMEGA, N, Q) == 1, "omega^N != 1"
    assert OMEGA * OMEGA_INV % Q == 1, "omega * omega_inv != 1"
    assert N * N_INV % Q == 1, "N * N_INV != 1"
    assert PSI * PSI % Q == OMEGA, "psi^2 != omega"

    print(f"[SELF-CHECK] 4 组 NTT/INTT 往返 + poly_mult 双路一致 -> PASS")
    print(f"[SELF-CHECK] q = {Q} (2^44 + {C})")
    print(f"[SELF-CHECK] psi(2N 根) = {PSI}")
    print(f"[SELF-CHECK] omega(N 根) = {OMEGA}")
    print(f"[SELF-CHECK] omega_inv  = {OMEGA_INV}")
    print(f"[SELF-CHECK] N_INV      = {N_INV}")


# =========================================================================
# 生成向量：2 组随机 + 2 组结构边界
# =========================================================================
def build_vectors():
    vectors = []

    for v in range(2):
        rng = random.Random(30000 + v * 23)
        a = [rng.randrange(Q) for _ in range(N)]
        b = [rng.randrange(Q) for _ in range(N)]
        vectors.append((f"rand{v}", a, b))

    # 单位卷积：A=[1,0,..,0] * B -> B
    rng_v2 = random.Random(207)
    vectors.append(("delta_a", [1] + [0] * (N - 1),
                    [rng_v2.randrange(Q) for _ in range(N)]))

    # 稀疏 A、稀疏 B（各半零半随机，贴合稀疏近似推理场景）
    rng_v3 = random.Random(209)
    a_v3 = [rng_v3.randrange(Q) if i % 2 == 0 else 0 for i in range(N)]
    b_v3 = [rng_v3.randrange(Q) if i % 2 == 1 else 0 for i in range(N)]
    vectors.append(("sparse", a_v3, b_v3))

    for i, (tag, a, b) in enumerate(vectors):
        c1 = cyclic_conv_direct(a, b, N, Q)
        c2 = poly_mult_via_ntt(a, b, N, Q, OMEGA, OMEGA_INV)
        assert c1 == c2, f"vector {i} tag={tag} 两路不一致"
    return vectors


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = here

    print("=" * 72)
    print(f"poly_mult N=2^12 降级路径向量生成器 (N={N}, q=q3, USE_FASTRED=1)")
    print("=" * 72)
    self_check()
    print()

    vectors = build_vectors()
    print(f"生成 {len(vectors)} 组向量到 {out_dir}")

    flat_a, flat_b, flat_c = [], [], []
    for tag, a, b in vectors:
        c = cyclic_conv_direct(a, b, N, Q)
        flat_a.extend(a)
        flat_b.extend(b)
        flat_c.extend(c)
        print(f"  [{tag:8s}] A[0:2]={a[:2]}..  C[0:2]={c[:2]}..")

    def write_hex(path, vals):
        with open(path, "w") as f:
            for v in vals:
                assert 0 <= v < Q, f"value {v} out of [0, {Q})"
                f.write(f"{v:X}\n")

    write_hex(os.path.join(out_dir, "poly_a_n12.hex"), flat_a)
    write_hex(os.path.join(out_dir, "poly_b_n12.hex"), flat_b)
    write_hex(os.path.join(out_dir, "poly_expected_n12.hex"), flat_c)

    # twiddle 表：omega_table[k] = omega^k, k = 0..N/2-1
    omega_tab = [pow(OMEGA, k, Q) for k in range(N // 2)]
    omega_inv_tab = [pow(OMEGA_INV, k, Q) for k in range(N // 2)]
    write_hex(os.path.join(out_dir, "omega_n12.hex"), omega_tab)
    write_hex(os.path.join(out_dir, "omega_inv_n12.hex"), omega_inv_tab)

    with open(os.path.join(out_dir, "poly_meta_n12.txt"), "w") as f:
        f.write(f"LOG_N={LOG_N}\nN={N}\nQ_WIDTH={Q_WIDTH}\nQ={Q}\n")
        f.write(f"PSI={PSI}\nOMEGA={OMEGA}\nOMEGA_INV={OMEGA_INV}\nN_INV={N_INV}\n")
        f.write(f"NUM_VECTORS={len(vectors)}\nUSE_FASTRED=1\n")

    print()
    print(f"[OK] 已生成:")
    print(f"  poly_a_n12.hex         ({len(flat_a)} 行)")
    print(f"  poly_b_n12.hex         ({len(flat_b)} 行)")
    print(f"  poly_expected_n12.hex  ({len(flat_c)} 行)")
    print(f"  omega_n12.hex          ({len(omega_tab)} 行)")
    print(f"  omega_inv_n12.hex      ({len(omega_inv_tab)} 行)")
    print(f"  poly_meta_n12.txt")
    print(f"[OK] 全部 {len(vectors)} 组向量通过双路一致性检查")


if __name__ == "__main__":
    main()
