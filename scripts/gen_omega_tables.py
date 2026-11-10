# -*- coding: utf-8 -*-
"""生成 NTT twiddle factor 表（omega_table / omega_inv_table）。

用法：
    # 玩具配置（N=16, q=113, omega=40）
    python gen_omega_tables.py --n 16 --q 113 --omega 40 --tag toy

    # 生产配置（N=2^14, q=2^44+131073, omega 由 g=11 推导）
    python gen_omega_tables.py --n 16384 --q 17592186175489 --primitive-root 11 --tag prod

    # 只验证不写文件
    python gen_omega_tables.py --n 16 --q 113 --omega 40 --verify-only

输出（默认写到 rtl/m2/）：
    omega_table_{tag}.sv.h         — SystemVerilog parameter 数组头文件（可直接 `include）
    omega_table_{tag}.hex         — RAM 初始化 hex（NTT）
    omega_inv_table_{tag}.hex     — RAM 初始化 hex（INTT）
    omega_table_{tag}.verify.txt  — 自校验结果

校验（生成器强制通过才写文件）：
    1. omega^N mod q == 1              （N 阶单位根）
    2. omega^k * omega_inv^k mod q == 1 对所有 k（正逆对偶）
    3. omega_inv = omega^{-1} mod q
    4. (NTT ∘ INTT) = identity，对随机多项式验证

设计约定（对齐 rtl/m1/ntt_unit.sv 第 68-69 行接口）：
    omega_table     [0:N/2-1]  # ω^k，k=0..N/2-1
    omega_inv_table [0:N/2-1]  # (ω^{-1})^k，k=0..N/2-1
"""
from __future__ import annotations

import argparse
import io
import math
import os
import random
import sys
from pathlib import Path


# ---------------------------------------------------------------- Miller-Rabin
def is_prime(n: int, rounds=(2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)) -> bool:
    if n < 2:
        return False
    for p in rounds:
        if n % p == 0:
            return n == p
    d, s = n - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    for a in rounds:
        x = pow(a, d, n)
        if x == 1 or x == n - 1:
            continue
        for _ in range(s - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def primitive_root(p: int) -> int:
    """返回 p 的原根。"""
    pm1 = p - 1
    n = pm1
    fset: set[int] = set()
    d = 2
    while d * d <= n:
        while n % d == 0:
            n //= d
            fset.add(d)
        d += 1
    if n > 1:
        fset.add(n)
    for g in range(2, p):
        if all(pow(g, pm1 // f, p) != 1 for f in fset):
            return g
    raise RuntimeError("no primitive root found")


# ---------------------------------------------------------------- 数学定义
def derive_omega(q: int, N: int, primitive_root: int | None) -> int:
    """推导 ω = g^{(q-1)/N} mod q，要求 N | q-1 且 N = 2^k。"""
    if N & (N - 1):
        raise ValueError(f"N={N} 必须是 2 的幂")
    if (q - 1) % N != 0:
        raise ValueError(f"N={N} 不能整除 q-1={q-1}，NTT 要求 N | q-1")
    if primitive_root is None:
        primitive_root = primitive_root(q)
    return pow(primitive_root, (q - 1) // N, q)


def generate_table(omega: int, q: int, N: int) -> list[int]:
    """生成 omega_table[0..N/2-1] = omega^k mod q。

    注意：ntt_unit 只用到 k = 0..N/2-1 的 twiddle factor
    （Cooley-Tukey DIT 每 stage 的 twiddle 指数最大为 N/2-1）。
    """
    half = N // 2
    table = [1] * half
    for k in range(1, half):
        table[k] = table[k - 1] * omega % q
    return table


# ---------------------------------------------------------------- 校验
def verify(n: int, q: int, omega: int, omega_inv: int,
           omega_table: list[int], omega_inv_table: list[int]) -> list[str]:
    """生成器强制校验，失败任一条即抛异常。"""
    errs: list[str] = []
    log2n = n.bit_length() - 1
    if (1 << log2n) != n:
        errs.append(f"N={n} 不是 2 的幂")
    if n & (n - 1):
        errs.append(f"N={n} 不是 2 的幂")
    if (q - 1) % n != 0:
        errs.append(f"N={n} 不能整除 q-1={q-1}")
    if not is_prime(q):
        errs.append(f"q={q} 不是素数")

    # 1. omega^N mod q == 1
    if pow(omega, n, q) != 1:
        errs.append(f"omega^N mod q = {pow(omega, n, q)} != 1")
    # 2. omega_inv == omega^{-1} mod q
    if (omega * omega_inv) % q != 1:
        errs.append(f"omega*omega_inv mod q = {(omega * omega_inv) % q} != 1")
    # 3. omega^k * omega_inv^k mod q == 1 对所有 k
    for k, (o, oi) in enumerate(zip(omega_table, omega_inv_table)):
        if (o * oi) % q != 1:
            errs.append(f"table[{k}]: omega^{k} * omega_inv^{k} mod q = {(o * oi) % q} != 1")
            if len(errs) > 5:
                break

    # 4. (NTT ∘ INTT) = identity（随机多项式，3 组）
    rng = random.Random(0xC77)
    N_INV = pow(n, -1, q)
    omega_inv = pow(omega, -1, q)
    for trial in range(3):
        a = [rng.randint(0, q - 1) for _ in range(n)]
        # NTT (DIT)
        a_hat = _ntt_dit(a, omega, q)
        # INTT (DIF) with N^{-1}
        rec = _intt_dif(a_hat, omega_inv, N_INV, q)
        if rec != a:
            errs.append(f"round-trip trial {trial} mismatch")
            break

    return errs


def _ntt_dit(a: list[int], omega: int, q: int) -> list[int]:
    """Cooley-Tukey DIT，与 ntt_unit 及 tb/ref/gen_ntt_reference.py 对齐。

    关键：每 stage 的 twiddle 基是 ω^(N/length) 不是 ω^1；w 累乘 w_len，
    不是每次都 pow(omega, k)。
    """
    n = len(a)
    a = list(a)
    # bit-reversal permutation（增量版，避免 log2n 循环）
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    # butterfly
    length = 2
    while length <= n:
        w_len = pow(omega, n // length, q)
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


def _intt_dif(a_hat: list[int], omega_inv: int, N_INV: int, q: int) -> list[int]:
    """逆 NTT = 用 omega^{-1} 做 DIT，最后乘 N^{-1}。"""
    n = len(a_hat)
    a = list(a_hat)
    # bit-reversal permutation
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    # butterfly with omega_inv
    length = 2
    while length <= n:
        w_len = pow(omega_inv, n // length, q)
        for i in range(0, n, length):
            w = 1
            for k in range(length // 2):
                u = a[i + k]
                v = a[i + k + length // 2] * w % q
                a[i + k] = (u + v) % q
                a[i + k + length // 2] = (u - v) % q
                w = w * w_len % q
        length <<= 1
    return [x * N_INV % q for x in a]


# ---------------------------------------------------------------- 输出
def format_sv_header(tag: str, Q_WIDTH: int, q: int, omega: int, omega_inv: int,
                     omega_table: list[int], omega_inv_table: list[int]) -> str:
    """生成 SystemVerilog `include 头文件（parameter 数组形式）。"""
    n = len(omega_table) * 2
    lines = []
    lines.append(f"// omega_table_{tag}.sv.h")
    lines.append(f"// Auto-generated by scripts/gen_omega_tables.py")
    lines.append(f"// N={n} (2^{n.bit_length()-1})  q={q}  ({Q_WIDTH}-bit prime)")
    lines.append(f"// omega={omega}   omega_inv={omega_inv}")
    lines.append(f"// omega^{n} mod q = 1 (verified)")
    lines.append(f"// omega*omega_inv mod q = 1 (verified)")
    lines.append(f"// Table size: N/2 = {n // 2} entries")
    lines.append(f"// -----------------------------------------------------------------")
    lines.append("")
    lines.append(f"`ifndef OMEGA_TABLE_{tag.upper()}_SV_H")
    lines.append(f"`define OMEGA_TABLE_{tag.upper()}_SV_H")
    lines.append("")
    lines.append(f"parameter logic [{Q_WIDTH-1}:0] omega_table [{n//2-1}:0] = '({', '.join(str(x) for x in omega_table)});")
    lines.append("")
    lines.append(f"parameter logic [{Q_WIDTH-1}:0] omega_inv_table [{n//2-1}:0] = '({', '.join(str(x) for x in omega_inv_table)});")
    lines.append("")
    lines.append(f"`endif // OMEGA_TABLE_{tag.upper()}_SV_H")
    return "\n".join(lines) + "\n"


def format_hex(values: list[int], width: int) -> str:
    """生成 hex 文件（每行一个值，无零填充前缀，xsim $readmemh 兼容）。"""
    pad = width // 4 + (1 if width % 4 else 0)
    return "".join(f"{v:0{pad}x}\n" for v in values)


# ---------------------------------------------------------------- 主流程
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=16, help="NTT 长度 2^k")
    ap.add_argument("--q", type=int, default=113, help="素数模 q")
    ap.add_argument("--omega", type=int, default=None, help="N 阶单位根；缺省则从 g 推导")
    ap.add_argument("--primitive-root", type=int, default=None, dest="primitive_root",
                    help="primitive root g；未提供 --omega 时用于推导")
    ap.add_argument("--tag", default="default", help="输出文件后缀 tag")
    ap.add_argument("--outdir", default=None, help="输出目录（默认 rtl/m2/）")
    ap.add_argument("--verify-only", action="store_true", help="只校验不写文件")
    args = ap.parse_args()

    N, q = args.n, args.q
    if N & (N - 1):
        print(f"[FAIL] N={N} 必须是 2 的幂", file=sys.stderr)
        return 2

    if args.omega is None:
        omega = derive_omega(q, N, args.primitive_root)
    else:
        omega = args.omega % q

    omega_inv = pow(omega, -1, q)
    N_INV = pow(N, -1, q)

    omega_table = generate_table(omega, q, N)
    omega_inv_table = generate_table(omega_inv, q, N)

    errs = verify(N, q, omega, omega_inv, omega_table, omega_inv_table)
    if errs:
        print(f"[FAIL] 校验失败：", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 3

    Q_WIDTH = q.bit_length()
    print(f"[OK] N={N}  q={q}  ({Q_WIDTH}-bit prime)")
    print(f"[OK] omega={omega}   omega_inv={omega_inv}   N_INV={N_INV}")
    print(f"[OK] omega^N mod q = 1")
    print(f"[OK] omega*omega_inv mod q = 1")
    print(f"[OK] omega^k * omega_inv^k mod q = 1  for all k in [0, {N//2})")
    print(f"[OK] (NTT ∘ INTT) = identity  on 3 random polynomials")

    if args.verify_only:
        print("[DONE] verify-only mode, no files written")
        return 0

    outdir = Path(args.outdir) if args.outdir else Path("rtl/m2")
    outdir.mkdir(parents=True, exist_ok=True)

    # .sv.h 头文件
    sv_h = outdir / f"omega_table_{args.tag}.sv.h"
    sv_h.write_text(
        format_sv_header(args.tag, Q_WIDTH, q, omega, omega_inv, omega_table, omega_inv_table),
        encoding="utf-8",
    )

    # hex 文件（RAM 初始化）
    (outdir / f"omega_table_{args.tag}.hex").write_text(
        format_hex(omega_table, Q_WIDTH), encoding="utf-8"
    )
    (outdir / f"omega_inv_table_{args.tag}.hex").write_text(
        format_hex(omega_inv_table, Q_WIDTH), encoding="utf-8"
    )

    # 校验报告
    verify_lines = [
        f"# omega_table_{args.tag} verification report",
        f"# Generated by scripts/gen_omega_tables.py",
        f"",
        f"N           = {N}    (2^{N.bit_length()-1})",
        f"q           = {q}    ({Q_WIDTH}-bit prime, is_prime=True)",
        f"(q-1) % N   = {(q-1) % N}   (0 = NTT feasible)",
        f"omega       = {omega}",
        f"omega_inv   = {omega_inv}",
        f"N_INV       = {N_INV}",
        f"",
        f"# omega^N mod q:",
        f"    = {pow(omega, N, q)}   (expected 1)   [{'OK' if pow(omega, N, q) == 1 else 'FAIL'}]",
        f"# omega*omega_inv mod q:",
        f"    = {(omega * omega_inv) % q}   (expected 1)   [{'OK' if (omega * omega_inv) % q == 1 else 'FAIL'}]",
        f"# N * N_INV mod q:",
        f"    = {(N * N_INV) % q}   (expected 1)   [{'OK' if (N * N_INV) % q == 1 else 'FAIL'}]",
        f"",
        f"# Table size: {len(omega_table)} entries (indices 0..{len(omega_table)-1})",
        f"# Round-trip NTT ∘ INTT: PASS on 3 random polynomials",
        f"",
        f"# First 8 entries of omega_table:",
    ]
    for k, v in enumerate(omega_table[:8]):
        verify_lines.append(f"  [{k:3d}] = {v}")
    verify_lines.append(f"# ... (total {len(omega_table)} entries)")
    (outdir / f"omega_table_{args.tag}.verify.txt").write_text(
        "\n".join(verify_lines) + "\n", encoding="utf-8"
    )

    print(f"[WRITE] {sv_h}")
    print(f"[WRITE] {outdir / f'omega_table_{args.tag}.hex'}")
    print(f"[WRITE] {outdir / f'omega_inv_table_{args.tag}.hex'}")
    print(f"[WRITE] {outdir / f'omega_table_{args.tag}.verify.txt'}")
    print(f"[DONE]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
