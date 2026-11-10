#!/usr/bin/env python3
"""
M2-a: 用「q = 2^44 + c 小常数归约」替换 `x % q` 的数值验证

思路
----
q = 2^44 + c, c = 131073 < 2^18  →  2^44 ≡ -c (mod q)

x < 2^90 写 x = xh*2^44 + xl  (xh < 2^46, xl < 2^44)
    x ≡ xl - xh*c    (mod q)          (round 1, 46 x 18 乘法)

r1 = xl - xh*c 可能为负。写 r1 = h1*2^44 + l1 (Euclidean, h1 可负, 0<=l1<2^44)
    r1 ≡ -h1*c + l1                          (round 2, |h1| 很小 x 18 乘法)
r2 = l1 + (-h1)*c 恒为非负。写 r2 = h2*2^44 + l2
    r2 ≡ l2 - h2*c                           (round 3, h2 极小 x 18 乘法)
最后 l2 - h2*c 落在 (-(c-1)*c, 2^44)，即 > -q 且 < 2^44 + q，
只需「若 <0 则 +q，若 >= q 则 -q」两次条件减/加即得结果。

与上一版 Barrett 的关键区别：所有乘法因子都是 c=131073 (18 bit)，
乘法位宽从 45x46 降到 46x18，DSP 用量与关键路径都大幅下降。
上一版踩的坑是「位数比预期多一位」，这里所有中间量的位宽都单独断言。

手工验算（用于确认符号方向）：
    x = Q     = 2^44 + c    →  xh=1, xl=c,   r1 = c - 1*c = 0        ✓
    x = Q - 1 = 2^44 + c-1  →  xh=1, xl=c-1, r1 = c-1 - c = -1 → +q = q-1 ✓
"""

import random

Q = 17592186175489
K = 44
C = Q - (1 << K)

MASK = (1 << K) - 1


def assert_widths():
    assert Q.bit_length() == 45, Q.bit_length()
    assert (1 << K) <= Q < (1 << (K + 1))
    assert C == Q - (1 << K), C
    assert C < (1 << 18), C          # 关键前提：c 只有 18 bit
    print(f"Q  = {Q}   ({Q.bit_length()} bit)")
    print(f"2^44 = {1 << K}")
    print(f"c  = {C}   ({C.bit_length()} bit, 需 < 2^18)")
    assert pow(2, K, Q) == (Q - C) % Q, "2^44 ≡ -c (mod q) 不成立"
    print("校验 2^44 ≡ -c (mod q)  : OK")
    # 符号方向的手工验算，防止再写反
    assert fast_red(Q) == 0, fast_red(Q)
    assert fast_red(Q - 1) == Q - 1, fast_red(Q - 1)
    assert fast_red(0) == 0
    assert fast_red(1) == 1
    print("手工验算 x∈{Q, Q-1, 0, 1} : OK")


def fast_red(x):
    """与拟写 RTL 逐步对应"""
    assert 0 <= x < (1 << 90), x

    # ---------- round 1 ----------
    xh = x >> K                       # 46 bit
    xl = x & MASK                     # 44 bit
    assert xh.bit_length() <= 46, (x, xh.bit_length())
    p1 = xh * C                      # 46 x 18 -> 64 bit
    assert p1.bit_length() <= 64, (x, p1.bit_length())
    r1 = xl - p1
    # r1 范围：(-(2^64-1), 2^44)
    assert -((1 << 64) - 1) <= r1 < (1 << K), (x, r1)

    # ---------- Euclidean split ----------
    h1 = r1 >> K                     # floor division, 可负
    l1 = r1 - h1 * (1 << K)          # 0 <= l1 < 2^44
    assert 0 <= l1 < (1 << K), (x, l1, h1)
    assert h1.bit_length() <= 21, (x, h1, bin(h1))

    # ---------- round 2 ----------
    m1 = -h1                         # 恒 >= 0
    p2 = m1 * C                      # 21 x 18 -> 39 bit
    assert p2.bit_length() <= 39, (x, p2.bit_length())
    r2 = l1 + p2                     # 恒 >= 0
    assert r2 >= 0, (x, r2)
    assert r2.bit_length() <= 51, (x, r2.bit_length())

    # ---------- round 3 ----------
    h2 = r2 >> K
    l2 = r2 - h2 * (1 << K)
    assert 0 <= l2 < (1 << K), (x, l2, h2)
    assert h2.bit_length() <= 8, (x, h2)
    p3 = h2 * C                      # 小 x 18
    assert p3.bit_length() <= 24, (x, p3.bit_length())
    r3 = l2 - p3

    # ---------- final ----------
    r = r3
    if r < 0:
        r += Q
    if r >= Q:
        r -= Q
    assert 0 <= r < Q, (x, r, r3)
    return r


def main():
    assert_widths()

    fails = []
    checked = 0

    # 1) 边界值
    edges = [
        0, 1, 2, Q - 1, Q, Q + 1, 2 * Q, 3 * Q, 2 * Q - 1,
        1 << 44, (1 << 44) - 1, (1 << 44) + 1,
        C, C * 2, C * 3,
        (1 << 90) - 1, (1 << 90) - Q,
        Q * ((1 << 44) - 1), ((1 << 44) - 1) * Q,
        (1 << 45) * C, (1 << 46) * C, (1 << 46) * C - 1,
        (1 << 64) + (1 << 44), ((1 << 44) - 1) * ((1 << 18) - 1),
    ]
    for e in edges:
        if not (0 <= e < (1 << 90)):
            continue
        checked += 1
        ref, g = e % Q, fast_red(e)
        if g != ref:
            fails.append(("edge", e, ref, g))

    # 2) 真实来源：b * omega, b, omega < q  (NTT 蝴蝶 prod_raw 的取值域)
    rng = random.Random(20261003)
    for _ in range(60000):
        b = rng.randrange(Q)
        w = rng.randrange(Q)
        x = b * w
        checked += 1
        ref, g = x % Q, fast_red(x)
        if g != ref:
            fails.append(("b*omega", x, ref, g))

    # 3) 通用 x < 2^90
    for _ in range(40000):
        x = rng.randrange(1 << 90)
        checked += 1
        ref, g = x % Q, fast_red(x)
        if g != ref:
            fails.append(("full", x, ref, g))

    # 4) 位宽统计：确认中间量没超出 RTL 声明的宽度
    rng2 = random.Random(7)
    wmax = {"xh": 0, "p1": 0, "r1_neg": 0, "h1": 0, "l1": 0,
            "m1": 0, "p2": 0, "r2": 0, "h2": 0, "l2": 0, "p3": 0, "r3": 0}
    h1_vals, h2_vals = set(), set()
    for _ in range(20000):
        x = rng2.randrange(1 << 90)
        xh = x >> K
        xl = x & MASK
        p1 = xh * C
        r1 = xl - p1
        h1 = r1 >> K
        l1 = r1 - h1 * (1 << K)
        m1 = -h1
        p2 = m1 * C
        r2 = l1 + p2
        h2 = r2 >> K
        l2 = r2 - h2 * (1 << K)
        p3 = h2 * C
        r3 = l2 - p3
        wmax["xh"] = max(wmax["xh"], xh.bit_length())
        wmax["p1"] = max(wmax["p1"], p1.bit_length())
        wmax["r1_neg"] = max(wmax["r1_neg"], (-r1).bit_length() if r1 < 0 else 0)
        wmax["h1"] = max(wmax["h1"], h1.bit_length())
        wmax["l1"] = max(wmax["l1"], l1.bit_length())
        wmax["m1"] = max(wmax["m1"], m1.bit_length())
        wmax["p2"] = max(wmax["p2"], p2.bit_length())
        wmax["r2"] = max(wmax["r2"], r2.bit_length())
        wmax["h2"] = max(wmax["h2"], h2.bit_length())
        wmax["l2"] = max(wmax["l2"], l2.bit_length())
        wmax["p3"] = max(wmax["p3"], p3.bit_length())
        wmax["r3"] = max(wmax["r3"], r3.bit_length())
        h1_vals.add(h1)
        h2_vals.add(h2)
    print("\n中间量实测最大位宽 (RTL 声明需 >= 这些值):")
    for k in ("xh", "p1", "r1_neg", "h1", "l1", "m1", "p2", "r2", "h2", "l2", "p3", "r3"):
        print(f"  {k:7s} = {wmax[k]}")
    print(f"  h1 出现过的值 = {sorted(h1_vals)}")
    print(f"  h2 出现过的值 = {sorted(h2_vals)}")

    print(f"\n校验用例 {checked} 条")
    print(f"fast_red 失败 {len(fails)} 条")
    if fails:
        for k, x, ref, got in fails[:10]:
            print(f"  FAIL [{k}] x={x}\n       ref={ref} got={got}")
        raise SystemExit(1)
    print("FASTRED_EXACT: ALL PASSED")


if __name__ == "__main__":
    main()
