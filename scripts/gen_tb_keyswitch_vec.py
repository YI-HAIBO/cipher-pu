"""M3-c KeySwitch rotation=0 (ReLinearization) 玩具配置 testbench 向量生成器。

玩具配置：N=16, Q=113
生成 5 组随机向量（减少以加快仿真）
输出：
    tb/ref/tb_keyswitch_e0.hex
    tb/ref/tb_keyswitch_e1.hex
    tb/ref/tb_keyswitch_e2.hex
    tb/ref/tb_keyswitch_a.hex
    tb/ref/tb_keyswitch_b.hex
    tb/ref/tb_keyswitch_f0.hex  (期望输出)
    tb/ref/tb_keyswitch_f1.hex  (期望输出)
"""

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REF_DIR = ROOT / "tb" / "ref"

N = 16
Q = 113
Q_WIDTH = 7
NUM_TESTS = 5

REF_DIR.mkdir(parents=True, exist_ok=True)


def poly_add(a, b, q):
    return [(x + y) % q for x, y in zip(a, b)]


def poly_sub(a, b, q):
    return [(x - y) % q for x, y in zip(a, b)]


def poly_mult(a, b, q):
    """玩具循环卷积 mod (x^N - 1, q)（与 poly_mult.sv 硬件一致）。

    玩具配置 q=113, N=16, omega=40：40^16 = 1 mod 113，且 32 | (q-1) 不成立，
    因此 Z_113 中不存在 32 阶本原单位根，无法做 CKKS 标准的负循环卷积
    （mod x^N + 1）。poly_mult.sv 硬件按 NTT 用 ω=40 实现，天然落在
    循环环 Z_q[x]/(x^N - 1) 中。本参考必须用同环（正循环卷积），
    否则与 DUT 相差一整层扭绞因子，无法对齐。
    """
    n = len(a)
    result = [0] * n
    for i in range(n):
        for j in range(n):
            k = (i + j) % n
            result[k] = (result[k] + a[i] * b[j]) % q
    return result


def write_hex(path, vec):
    with open(path, "w") as f:
        for v in vec:
            f.write(f"{v:0{Q_WIDTH}x}\n")


def main():
    print(f"生成 KeySwitch testbench 向量：N={N}, Q={Q}")
    print(f"NUM_TESTS={NUM_TESTS}")

    rng = random.Random(42)

    e0_all, e1_all, e2_all = [], [], []
    a_all, b_all = [], []
    f0_all, f1_all = [], []

    for t in range(NUM_TESTS):
        # 生成 3 元素密文
        e0 = [rng.randrange(Q) for _ in range(N)]
        e1 = [rng.randrange(Q) for _ in range(N)]
        e2 = [rng.randrange(Q) for _ in range(N)]

        # 生成 keyswitch key：a 随机，b = a*s + e_ks（s 随机，e_ks 小）
        a = [rng.randrange(Q) for _ in range(N)]
        s = [rng.randrange(Q) for _ in range(N)]
        e_ks = [rng.randrange(10) for _ in range(N)]  # 小误差
        b = poly_add(poly_mult(a, s, Q), e_ks, Q)

        # 计算期望输出
        e2a = poly_mult(e2, a, Q)
        e2b = poly_mult(e2, b, Q)
        f0 = poly_add(e0, e2b, Q)
        f1 = poly_sub(e1, e2a, Q)

        e0_all.extend(e0)
        e1_all.extend(e1)
        e2_all.extend(e2)
        a_all.extend(a)
        b_all.extend(b)
        f0_all.extend(f0)
        f1_all.extend(f1)

        print(f"  Test {t}: e0[0]={e0[0]}, e1[0]={e1[0]}, e2[0]={e2[0]}, "
              f"a[0]={a[0]}, b[0]={b[0]}, f0[0]={f0[0]}, f1[0]={f1[0]}")

    # 写入文件
    files = [
        ("tb_keyswitch_e0.hex", e0_all),
        ("tb_keyswitch_e1.hex", e1_all),
        ("tb_keyswitch_e2.hex", e2_all),
        ("tb_keyswitch_a.hex", a_all),
        ("tb_keyswitch_b.hex", b_all),
        ("tb_keyswitch_f0.hex", f0_all),
        ("tb_keyswitch_f1.hex", f1_all),
    ]

    for name, vec in files:
        path = REF_DIR / name
        write_hex(path, vec)
        print(f"写入：{name} ({len(vec)} 项)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
