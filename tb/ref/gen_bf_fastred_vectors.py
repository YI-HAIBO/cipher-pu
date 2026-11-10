#!/usr/bin/env python3
"""
为 tb/tb_ntt_bf_fastred.sv 生成 fast-red 集成蝴蝶的参考向量。

输出（与 tb/ref 同目录）：
    bf_a.hex      : 每行一个 a ∈ [0, Q)（45 bit，纯十六进制）
    bf_b.hex      : 每行一个 b ∈ [0, Q)
    bf_omega.hex  : 每行一个 omega ∈ [0, Q)
    bf_a_exp.hex  : 每行一个 exp_a = (a + b*omega) % Q
    bf_b_exp.hex  : 每行一个 exp_b = (a - b*omega + Q) % Q

用例构成：
    1) 边界值（a=0, Q-1, b=0, Q-1, omega=1, ...）
    2) 随机 (a, b, omega) 三元组
    3) b*omega 恰好等于边界值的情况

注意：$readmemh 按十六进制解析，必须写 hex 字符串，不能写十进制。
      生成后立即回读校验，防止静默错误。
"""

import os
import random
import re

Q = 17592186175489          # 45 bit, = 2^44 + 131073
K = 44
C = Q - (1 << K)            # = 131073 = 2^17 + 1
WIDTH = 45

HERE = os.path.dirname(os.path.abspath(__file__))


def hex_word(v):
    """转成定宽十六进制字符串（无 0x 前缀）"""
    assert 0 <= v < (1 << WIDTH), (v, WIDTH)
    return format(v, f"0{((WIDTH + 3) // 4)}x")


def main():
    cases = []

    # ---- 1) 边界值三元组 ----
    edges_a = [0, 1, C - 1, C, Q - 1]
    edges_b = [0, 1, Q - 1]
    edges_w = [1, 2, C - 1, C, Q - 1]
    for a in edges_a:
        for b in edges_b:
            for w in edges_w:
                cases.append((a, b, w))

    # ---- 2) 随机三元组 ----
    rng = random.Random(20261003)
    for _ in range(500):
        cases.append((rng.randrange(Q), rng.randrange(Q), rng.randrange(Q)))

    # ---- 3) b*omega 恰好等于边界值 ----
    # b=1, omega=Q-1 → b*omega = Q-1 → prod_q = Q-1
    cases.append((Q - 1, 1, Q - 1))       # a + prod_q = 2Q-2, a - prod_q = 0
    # b=1, omega=1 → b*omega = 1
    cases.append((0, 1, 1))               # a + 1 = 1, a - 1 = Q-1
    cases.append((Q - 1, 1, 1))           # a + 1 = 0 (mod Q), a - 1 = Q-2
    # b=1, omega=C → b*omega = C
    cases.append((0, 1, C))
    cases.append((Q - 1, 1, C))

    cases = list(dict.fromkeys(cases))     # 去重保序

    a_path  = os.path.join(HERE, "bf_a.hex")
    b_path  = os.path.join(HERE, "bf_b.hex")
    w_path  = os.path.join(HERE, "bf_omega.hex")
    ae_path = os.path.join(HERE, "bf_a_exp.hex")
    be_path = os.path.join(HERE, "bf_b_exp.hex")

    def io_write(p, lines):
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")

    lines_a, lines_b, lines_w, lines_ae, lines_be = [], [], [], [], []
    for a, b, w in cases:
        prod_q = (b * w) % Q
        exp_a  = (a + prod_q) % Q
        exp_b  = (a - prod_q + Q) % Q
        lines_a.append(hex_word(a))
        lines_b.append(hex_word(b))
        lines_w.append(hex_word(w))
        lines_ae.append(hex_word(exp_a))
        lines_be.append(hex_word(exp_b))

    io_write(a_path,  lines_a)
    io_write(b_path,  lines_b)
    io_write(w_path,  lines_w)
    io_write(ae_path, lines_ae)
    io_write(be_path, lines_be)

    # 回读自检
    hex_re = re.compile(r"^[0-9a-fA-F]+$")
    for p, lines in [(a_path, lines_a), (b_path, lines_b),
                     (w_path, lines_w), (ae_path, lines_ae), (be_path, lines_be)]:
        with open(p, "r", encoding="utf-8") as f:
            rd = f.read().strip().split("\n")
        assert len(rd) == len(lines), f"{p}: len mismatch"
        for line in rd:
            assert hex_re.match(line.strip()), f"{p}: bad hex {line}"

    print(f"OK: {len(cases)} test vectors")
    print(f"  {a_path}")
    print(f"  {b_path}")
    print(f"  {w_path}")
    print(f"  {ae_path}")
    print(f"  {be_path}")


if __name__ == "__main__":
    main()
