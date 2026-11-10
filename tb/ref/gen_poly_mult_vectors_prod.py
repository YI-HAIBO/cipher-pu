#!/usr/bin/env python3
"""
gen_poly_mult_vectors_prod.py — 密推芯 M2-c 生产配置向量生成（N=16, q=2^44+c）

目的：
  为 poly_mult 生产配置（N=16, Q_WIDTH=45, Q_VALUE=17592186175489,
  USE_FASTRED=1）生成 10 组 (A, B, C_expected) 向量。

数学前提（已由 scripts/_verify_poly_mult_prodconfig.py 验证）：
  q     = 17592186175489 = 2^44 + 131073 = 2^44 + (2^17 + 1)
  q - 1 = 2^17 * 134217729  → 含 2^17 因子，N=16=2^4 有 primitive root
  g     = 11（primitive root）
  omega = 17474076998581 = g^((q-1)/16) mod q
  omega_inv = 13203937673276 = omega^(-1) mod q
  N_INV = 16492674539521 = 16^(-1) mod q

自校验（三重）：
  1. NTT -> INTT 往返：所有向量必须还原原系数
  2. poly_mult 双路径一致：
     - 直接 O(N^2) 循环卷积
     - NTT -> 点乘 -> INTT
  3. 每条路径都必须一致，否则拒绝生成 hex

输出（写入同目录）：
  poly_a_prod.hex          : 160 行，45-bit 十六进制
  poly_b_prod.hex          : 160 行，45-bit 十六进制
  poly_expected_prod.hex   : 160 行，45-bit 十六进制
  poly_meta_prod.txt       : 参数与自校验摘要
"""

import os
import random
import sys

# =========================================================================
# 参数（生产配置，与 _verify_poly_mult_prodconfig.py 对齐）
# =========================================================================
LOG_N = 4
N = 1 << LOG_N                      # 16
C = (1 << 17) + 1                   # 131073
Q = (1 << 44) + C                   # 17592186175489
Q_WIDTH = 45
G = 11                              # primitive root
OMEGA = pow(G, (Q - 1) // N, Q)    # 17474076998581
OMEGA_INV = pow(OMEGA, -1, Q)      # 13203937673276
N_INV = pow(N, -1, Q)              # 16492674539521
NUM_VECTORS = 10

# =========================================================================
# 参考实现（NTT/INTT，与 RTL 完全对齐：Cooley-Tukey DIT）
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
    """直接 O(N^2) 循环卷积，ground truth"""
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
    rng = random.Random(20261003)
    for t in range(32):
        a = [rng.randrange(Q) for _ in range(N)]
        b = [rng.randrange(Q) for _ in range(N)]

        # NTT -> INTT 往返
        assert intt(ntt(a, OMEGA, N, Q), OMEGA_INV, N, Q) == a, \
            f"NTT/INTT 往返失败 a t={t}"
        assert intt(ntt(b, OMEGA, N, Q), OMEGA_INV, N, Q) == b, \
            f"NTT/INTT 往返失败 b t={t}"

        # 两条 poly_mult 路径一致
        c_direct = cyclic_conv_direct(a, b, N, Q)
        c_ntt = poly_mult_via_ntt(a, b, N, Q, OMEGA, OMEGA_INV)
        assert c_direct == c_ntt, f"poly_mult 两路不一致 t={t}"

    # 元数据验证
    assert pow(OMEGA, N, Q) == 1, "omega^N != 1"
    assert OMEGA * OMEGA_INV % Q == 1, "omega * omega_inv != 1"
    assert N * N_INV % Q == 1, "N * N_INV != 1"

    print(f"[SELF-CHECK] 32 组随机 NTT/INTT 往返 + poly_mult 双路一致 → PASS")
    print(f"[SELF-CHECK] q = {Q} (2^44 + {C})")
    print(f"[SELF-CHECK] omega = {OMEGA}")
    print(f"[SELF-CHECK] omega_inv = {OMEGA_INV}")
    print(f"[SELF-CHECK] N_INV = {N_INV}")

# =========================================================================
# 生成向量：6 组随机 + 4 组结构边界
# =========================================================================
def build_vectors():
    vectors = []

    # 6 组随机（种子固定，可复现）
    for v in range(6):
        rng = random.Random(20000 + v * 23)
        a = [rng.randrange(Q) for _ in range(N)]
        b = [rng.randrange(Q) for _ in range(N)]
        vectors.append(("rand", a, b))

    # v6: 全 0 * 随机 → 全 0
    vectors.append(("zero_a",
                    [0] * N,
                    [random.Random(101).randrange(Q) for _ in range(N)]))

    # v7: [1, 0, .., 0] * B → B（单位卷积）
    rng_v7 = random.Random(107)
    b_v7 = [rng_v7.randrange(Q) for _ in range(N)]
    vectors.append(("delta_a", [1] + [0] * (N - 1), b_v7))

    # v8: A=[q-1]*N, B=[1]*N → 循环卷积 A*B 每系数 = N * (q-1) mod q
    vectors.append(("max_mult", [Q - 1] * N, [1] * N))

    # v9: 稀疏 A、稀疏 B（各半零半随机）
    rng_v9 = random.Random(109)
    a_v9 = [rng_v9.randrange(Q) if i % 2 == 0 else 0 for i in range(N)]
    b_v9 = [rng_v9.randrange(Q) if i % 2 == 1 else 0 for i in range(N)]
    vectors.append(("sparse", a_v9, b_v9))

    # 每对 (A, B) 双路径一致性
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
    out_dir = here

    print("=" * 72)
    print("M2-c poly_mult 生产配置向量生成器 (N=16, q=2^44+c, USE_FASTRED=1)")
    print("=" * 72)
    self_check()
    print()

    vectors = build_vectors()
    print(f"生成 {len(vectors)} 组向量到 {out_dir}")

    flat_a, flat_b, flat_c = [], [], []
    for tag, a, b in vectors:
        c = cyclic_conv_direct(a, b, N, Q)
        flat_a.extend(a); flat_b.extend(b); flat_c.extend(c)
        print(f"  [{tag:8s}] A[0:2]={a[:2]}..  C[0:2]={c[:2]}..")

    def write_hex(path, vals):
        """45-bit 十六进制，宽度补到 Q_WIDTH"""
        with open(path, "w") as f:
            for v in vals:
                assert 0 <= v < Q, f"value {v} out of [0, {Q})"
                # 用 %X 让 hex 不带前缀，Vivado $readmemh 需要
                f.write(f"{v:X}\n")

    write_hex(os.path.join(out_dir, "poly_a_prod.hex"),        flat_a)
    write_hex(os.path.join(out_dir, "poly_b_prod.hex"),        flat_b)
    write_hex(os.path.join(out_dir, "poly_expected_prod.hex"), flat_c)

    # 参数元数据
    meta_path = os.path.join(out_dir, "poly_meta_prod.txt")
    with open(meta_path, "w") as f:
        f.write(f"LOG_N={LOG_N}\nN={N}\nQ_WIDTH={Q_WIDTH}\nQ={Q}\n")
        f.write(f"OMEGA={OMEGA}\nOMEGA_INV={OMEGA_INV}\nN_INV={N_INV}\n")
        f.write(f"NUM_VECTORS={len(vectors)}\nUSE_FASTRED=1\n")

    print()
    print(f"[OK] 已生成:")
    print(f"  poly_a_prod.hex         ({len(flat_a)} 行)")
    print(f"  poly_b_prod.hex         ({len(flat_b)} 行)")
    print(f"  poly_expected_prod.hex  ({len(flat_c)} 行)")
    print(f"  poly_meta_prod.txt")
    print(f"[OK] 全部 {len(vectors)} 组向量通过 NTT 路径 vs 直接循环卷积双路一致检查")

if __name__ == "__main__":
    main()
