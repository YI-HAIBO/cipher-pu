"""M3-d 端到端密文乘法 testbench 向量生成器。

玩具配置：N=16, Q_IN=113, Q_OUT=97
生成 3 组随机向量
输出：
    tb/ref/tb_e2e_c0_1.hex
    tb/ref/tb_e2e_c1_1.hex
    tb/ref/tb_e2e_c0_2.hex
    tb/ref/tb_e2e_c1_2.hex
    tb/ref/tb_e2e_a.hex
    tb/ref/tb_e2e_b.hex
    tb/ref/tb_e2e_f0.hex  (期望输出)
    tb/ref/tb_e2e_f1.hex  (期望输出)
"""

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REF_DIR = ROOT / "tb" / "ref"

N = 16
Q_IN = 113
Q_OUT = 97
Q_WIDTH = 7
SCALE_BITS = 6  # log2(64) for toy
NUM_TESTS = 3

REF_DIR.mkdir(parents=True, exist_ok=True)


def poly_add(a, b, q):
    return [(x + y) % q for x, y in zip(a, b)]


def poly_sub(a, b, q):
    return [(x - y) % q for x, y in zip(a, b)]


def poly_mult(a, b, q):
    """玩具循环卷积 mod (x^N - 1, q)（与 poly_mult.sv 硬件一致）。

    玩具配置 q=113, N=16, omega=40：Z_113 无 32 阶本原单位根，
    poly_mult.sv 硬件天然落在循环环 Z_q[x]/(x^N - 1) 中。本参考
    必须用同环（正循环卷积），否则与 DUT 相差扭绞因子无法对齐。
    生产配置 q_i = 2^44 + c_i 与 2^(2N) | (q_i - 1) 成立时才走 CKKS 负循环。
    """
    n = len(a)
    result = [0] * n
    for i in range(n):
        for j in range(n):
            k = (i + j) % n
            result[k] = (result[k] + a[i] * b[j]) % q
    return result


def rescale(s, q_in, q_out, scale_bits):
    """玩具 Rescale：s' = round(s * q_out / (q_in * 2^scale_bits)) mod q_out"""
    scale = 1 << scale_bits
    val = (s * q_out + q_in // 2) // (q_in * scale)
    return val % q_out


def e2e_mult(c0_1, c1_1, c0_2, c1_2, a, b, q_in, q_out, scale_bits):
    """端到端密文乘法。"""
    # Step 1: 3 次 poly_mult
    m0 = poly_mult(c0_1, c0_2, q_in)
    m1a = poly_mult(c0_1, c1_2, q_in)
    m1b = poly_mult(c1_1, c0_2, q_in)
    m1 = poly_add(m1a, m1b, q_in)
    m2 = poly_mult(c1_1, c1_2, q_in)

    # Step 2: ReLinearization
    e2a = poly_mult(m2, a, q_in)
    e2b = poly_mult(m2, b, q_in)
    f0 = poly_add(m0, e2b, q_in)
    f1 = poly_sub(m1, e2a, q_in)

    # Step 3: Rescale
    f0_prime = [rescale(x, q_in, q_out, scale_bits) for x in f0]
    f1_prime = [rescale(x, q_in, q_out, scale_bits) for x in f1]

    return f0_prime, f1_prime


def write_hex(path, vec):
    with open(path, "w") as f:
        for v in vec:
            f.write(f"{v:0{Q_WIDTH}x}\n")


def main():
    print(f"生成 E2E testbench 向量：N={N}, Q_IN={Q_IN}, Q_OUT={Q_OUT}")
    print(f"SCALE_BITS={SCALE_BITS}, NUM_TESTS={NUM_TESTS}")

    rng = random.Random(42)

    c0_1_all, c1_1_all = [], []
    c0_2_all, c1_2_all = [], []
    a_all, b_all = [], []
    f0_all, f1_all = [], []

    for t in range(NUM_TESTS):
        # 生成 2 个密文
        c0_1 = [rng.randrange(Q_IN) for _ in range(N)]
        c1_1 = [rng.randrange(Q_IN) for _ in range(N)]
        c0_2 = [rng.randrange(Q_IN) for _ in range(N)]
        c1_2 = [rng.randrange(Q_IN) for _ in range(N)]

        # 生成 keyswitch key
        a = [rng.randrange(Q_IN) for _ in range(N)]
        s = [rng.randrange(Q_IN) for _ in range(N)]
        e_ks = [rng.randrange(10) for _ in range(N)]
        b = poly_add(poly_mult(a, s, Q_IN), e_ks, Q_IN)

        # 执行端到端乘法
        f0_prime, f1_prime = e2e_mult(
            c0_1, c1_1, c0_2, c1_2, a, b, Q_IN, Q_OUT, SCALE_BITS
        )

        c0_1_all.extend(c0_1)
        c1_1_all.extend(c1_1)
        c0_2_all.extend(c0_2)
        c1_2_all.extend(c1_2)
        a_all.extend(a)
        b_all.extend(b)
        f0_all.extend(f0_prime)
        f1_all.extend(f1_prime)

        print(f"  Test {t}: c0_1[0]={c0_1[0]}, c0_2[0]={c0_2[0]}, "
              f"f0'[0]={f0_prime[0]}, f1'[0]={f1_prime[0]}")

    # 写入文件
    files = [
        ("tb_e2e_c0_1.hex", c0_1_all),
        ("tb_e2e_c1_1.hex", c1_1_all),
        ("tb_e2e_c0_2.hex", c0_2_all),
        ("tb_e2e_c1_2.hex", c1_2_all),
        ("tb_e2e_a.hex", a_all),
        ("tb_e2e_b.hex", b_all),
        ("tb_e2e_f0.hex", f0_all),
        ("tb_e2e_f1.hex", f1_all),
    ]

    for name, vec in files:
        path = REF_DIR / name
        write_hex(path, vec)
        print(f"写入：{name} ({len(vec)} 项)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
