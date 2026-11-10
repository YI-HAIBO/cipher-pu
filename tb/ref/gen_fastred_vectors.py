#!/usr/bin/env python3
"""
为 tb/tb_mod45_fastred.sv 生成快归约的参考向量。

输出（与 tb/ref 同目录）：
    fastred_in.hex   : 每行一个 x（90 bit，最高位起，纯十六进制）
    fastred_out.hex  : 每行一个 x % Q（45 bit，纯十六进制）

用例构成：
    1) 边界值（x=0, Q-1, Q, 2^44-1, 2^44, 2^90-1, ...）
    2) b * omega（NTT 蝴蝶真实取值域，b, omega ∈ [0, Q)）
    3) 通用 x < 2^90 伪随机

注意：$readmemh 按十六进制解析，必须写 str(x)[15:]，不能写十进制。
      生成后立即回读校验，防止静默错误。
"""

import os
import random

Q = 17592186175489          # 45 bit，= 2^44 + 131073
K = 44
C = Q - (1 << K)            # = 131073 = 2^17 + 1
SHIFT = 90

HERE = os.path.dirname(os.path.abspath(__file__))


def hex_word(v, bits):
    """转成定宽十六进制字符串（无 0x 前缀，无填充空格）"""
    assert 0 <= v < (1 << bits), (v, bits)
    return format(v, f"0{((bits + 3) // 4)}x")


def main():
    cases = []

    # ---- 1) 边界值 ----
    edges = [
        0, 1, 2,
        (1 << K) - 1, 1 << K, (1 << K) + 1,
        C, C * 2, C * 3,
        Q - 1, Q, Q + 1, 2 * Q - 1, 2 * Q, 3 * Q,
        (1 << 45) * C, (1 << 46) * C, (1 << 46) * C - 1,
        (1 << 63) + (1 << 44),
        ((1 << 44) - 1) * ((1 << 18) - 1),
        (1 << 90) - 1, (1 << 90) - 2, (1 << 90) - Q,
    ]
    for e in edges:
        if 0 <= e < (1 << SHIFT):
            cases.append(e)

    # ---- 2) b * omega（NTT 蝴蝶真实取值域）----
    rng = random.Random(20261003)
    for _ in range(500):
        b = rng.randrange(Q)
        w = rng.randrange(Q)
        cases.append(b * w)

    # ---- 3) 通用 x < 2^90 ----
    for _ in range(500):
        cases.append(rng.randrange(1 << SHIFT))

    # ---- 4) 专门打 fast-red 的中间量断言边界 ----
    # r1 恰好 = 0 / r2 恰好落在 2^44 上 / h2 恰好 = 1
    for extra in [C, Q, 2 * Q - C, (1 << 44) - 1, (1 << 44) + C,
                  ((1 << 44) + C) * C, ((1 << 44) - 1) * C]:
        if 0 <= extra < (1 << SHIFT):
            cases.append(extra)

    cases = list(dict.fromkeys(cases))          # 去重保序
    assert all(0 <= v < (1 << SHIFT) for v in cases)

    inp_path = os.path.join(HERE, "fastred_in.hex")
    out_path = os.path.join(HERE, "fastred_out.hex")

    with open(inp_path, "w", encoding="ascii") as fi, \
         open(out_path, "w", encoding="ascii") as fo:
        for v in cases:
            fi.write(hex_word(v, SHIFT) + "\n")
            fo.write(hex_word(v % Q, 45) + "\n")

    # ---- 回读自检：确保真的是十六进制、行数一致、期望值正确 ----
    with open(inp_path, "r", encoding="ascii") as f:
        lines_in = [ln.strip() for ln in f if ln.strip()]
    with open(out_path, "r", encoding="ascii") as f:
        lines_out = [ln.strip() for ln in f if ln.strip()]
    assert len(lines_in) == len(lines_out) == len(cases), (len(lines_in), len(cases))
    bad = 0
    for i, (xi, ri) in enumerate(zip(lines_in, lines_out)):
        xi_u = int(xi, 16)
        ri_u = int(ri, 16)
        if xi_u != cases[i] or ri_u != (cases[i] % Q):
            bad += 1
            if bad <= 3:
                print(f"  MISMATCH @{i}: wrote x={xi_u} r={ri_u}, want r={cases[i] % Q}")
    assert bad == 0, f"{bad} 条向量回读失败"

    print(f"生成 {len(cases)} 组用例 ->")
    print(f"  {inp_path}")
    print(f"  {out_path}")
    print(f"  回读自检 0 失败（x 与 x%Q 均按十六进制复核）")


if __name__ == "__main__":
    main()
