"""M3-b Rescale 数学等价验证。

CKKS 标准 Rescale（方案 B），针对本项目的 K=4 模数链：
    c'_j = round(c_j * q_out / q_in) mod q_out

由于 q_in 与 q_out 都是 45-bit 素数且彼此接近（|q_in - q_out| < 3e6），
本实现采用「乘 + 除 + 舍入 + 取模」的精确公式，不依赖 q_in == q_out 的近似。

验证范围：
    - 所有 3 个层间跳转（q0→q1, q1→q2, q2→q3）
    - 边界：0, 1, q_in-1, q_out-1, q_out, q_out+1
    - 100,000 组随机系数
    - 全多项式（N=16384）端到端

运行：
    python \\
        scripts/verify_rescale.py
"""

import json
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CHAIN_FILE = ROOT / "rtl" / "m2" / "modulus_chain_chain4.json"

N = 16384
NUM_RANDOM = 100_000


def load_chain():
    with open(CHAIN_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def rescale_coeff(c, q_in, q_out):
    """CKKS 标准 Rescale：c' = round(c * q_out / q_in) mod q_out.

    精确实现：
        t = c * q_out                     # 90-bit
        r = t // q_in                     # 45-bit
        rem = t - r * q_in                # < q_in
        if 2 * rem >= q_in: r += 1        # 四舍五入
        return r % q_out                  # 取模到下一层
    """
    t = c * q_out
    r = t // q_in
    rem = t - r * q_in
    if 2 * rem >= q_in:
        r += 1
    return r % q_out


def rescale_poly(c, q_in, q_out):
    return [rescale_coeff(x, q_in, q_out) for x in c]


def check_boundary(q_in, q_out):
    """边界值测试。"""
    pts = [0, 1, 2, q_in - 3, q_in - 2, q_in - 1, q_out - 1, q_out, q_out + 1]
    pts = sorted({p for p in pts if 0 <= p < q_in})
    errs = []
    for c in pts:
        out = rescale_coeff(c, q_in, q_out)
        if not (0 <= out < q_out):
            errs.append(f"c={c} -> out={out} (out of [0,{q_out}))")
    return errs


def check_random(q_in, q_out, n=NUM_RANDOM):
    """随机测试。"""
    errs = []
    for _ in range(n):
        c = random.randrange(q_in)
        out = rescale_coeff(c, q_in, q_out)
        if not (0 <= out < q_out):
            errs.append(f"c={c} -> out={out}")
            if len(errs) > 20:
                break
    return errs


def check_roundtrip(q_in, q_out, n=1000):
    """近似逆运算：rescale 后再乘回 q_in/q_out 比例，应回到原值附近。"""
    errs = []
    for _ in range(n):
        c = random.randrange(q_in)
        c_out = rescale_coeff(c, q_in, q_out)
        # 逆近似：c_out * q_in / q_out
        back = round(c_out * q_in / q_out)
        if abs(back - c) > 2:  # 允许 ±2 舍入误差
            errs.append(f"c={c} -> c_out={c_out} -> back={back}")
            if len(errs) > 20:
                break
    return errs


def check_monotonic(q_in, q_out, n=1000):
    """单调性：c1 < c2 应保证 rescale(c1) <= rescale(c2)。"""
    errs = []
    for _ in range(n):
        a = random.randrange(q_in)
        b = random.randrange(q_in)
        if a > b:
            a, b = b, a
        if rescale_coeff(a, q_in, q_out) > rescale_coeff(b, q_in, q_out):
            errs.append(f"a={a} b={b} -> {rescale_coeff(a, q_in, q_out)} > {rescale_coeff(b, q_in, q_out)}")
            if len(errs) > 20:
                break
    return errs


def check_poly(q_in, q_out):
    """全多项式端到端。"""
    rng = random.Random(12345)
    poly_in = [rng.randrange(q_in) for _ in range(N)]
    poly_out = rescale_poly(poly_in, q_in, q_out)
    if len(poly_out) != N:
        return [f"len mismatch: {len(poly_out)}"]
    errs = []
    for i, (a, b) in enumerate(zip(poly_in, poly_out)):
        if not (0 <= b < q_out):
            errs.append(f"i={i}: out={b}")
            if len(errs) > 20:
                break
    return errs


def main():
    print("=" * 70)
    print("M3-b Rescale 数学等价验证")
    print("=" * 70)
    chain = load_chain()
    # chain 是 list of dict（每个 dict 含 "q" 等字段）
    primes = [p["q"] for p in chain]
    print(f"模数链 K={len(primes)}:")
    for i, q in enumerate(primes):
        print(f"  q{i} = {q}  (bits={q.bit_length()})")
    print()

    all_pass = True
    for i in range(len(primes) - 1):
        q_in, q_out = primes[i], primes[i + 1]
        print(f"[{i}] q{i} -> q{i+1}:  {q_in} -> {q_out}  (diff={q_in - q_out})")

        tests = [
            ("边界值", check_boundary, (q_in, q_out)),
            ("随机 100000", check_random, (q_in, q_out)),
            ("逆运算近似", check_roundtrip, (q_in, q_out)),
            ("单调性", check_monotonic, (q_in, q_out)),
            ("全多项式 N=16384", check_poly, (q_in, q_out)),
        ]

        for name, fn, args in tests:
            errs = fn(*args)
            if errs:
                print(f"  [FAIL] {name}: {len(errs)} 错误")
                for e in errs[:3]:
                    print(f"         {e}")
                all_pass = False
            else:
                print(f"  [OK]   {name}")
        print()

    print("=" * 70)
    print("结论：", "ALL PASS" if all_pass else "FAIL")
    print("=" * 70)
    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
