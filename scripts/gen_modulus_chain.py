# -*- coding: utf-8 -*-
"""M3-a：生成 K 层 CKKS 模数链（modulus chain）。

用法：
    python gen_modulus_chain.py --k 4 --bits 45 --n 16384 --tag chain4
    python gen_modulus_chain.py --verify-only --chain-file rtl/m2/modulus_chain_chain4.json

输出：
    rtl/m2/modulus_chain_{tag}.json     模数链结构化描述
    rtl/m2/modulus_chain_{tag}.sv.h     SystemVerilog parameter 数组
    rtl/m2/modulus_chain_{tag}.txt      可读报告

约束：
    · 每个素数 qi 满足 2N | qi - 1（N=2^14 时 2^15 | qi - 1）
    · 每个素数 qi 是 bits 位素数
    · 各 qi 两两互素（不同素数天然互素）
    · qi > 2^(bits-1)，即 bits 位素数

fast-red 兼容性：
    q = 2^K + c 形式时 c 值记录下来。fast-red 归约要求 c 尽量小且
    结构简单（如 c = 2^k + 1 时可用 shift-and-add 单次实现）。
    本脚本按 c 值从小到大排序候选，优先使用结构最简单的素数。

设计约定（对齐 M3 设计文档 §5）：
    · 方案 A：K=4, N=2^14
    · c 允许变化（用户拍板允许）
    · 各 qi 独立生成 omega_table（用 gen_omega_tables.py 或本脚本子命令）
"""
from __future__ import annotations

import argparse
import io
import json
import math
import sys
from pathlib import Path


# ---------------------------------------------------------------- 素数与根
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
    """返回 p 的原根。因子分解循环另存 pm1 供指数使用。"""
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


# ---------------------------------------------------------------- 素数搜索
def find_next_prime(bits: int, cond: int, start: int) -> tuple[int, int]:
    """搜索从 start 开始的下一个 bits 位素数 q 满足 q % cond == 1。

    返回 (q, k)：q = k * cond + 1。
    """
    k = max(1, (start + cond - 1) // cond)
    for _ in range(5_000_000):
        q = k * cond + 1
        if q.bit_length() == bits and is_prime(q):
            return q, k
        k += 1
    raise RuntimeError(f"prime not found (bits={bits}, cond={cond}, start={start})")


def find_k_primes(k_chain: int, bits: int, cond: int,
                  prefer_small_c: bool = True,
                  c_target_max: int = (1 << 25)) -> list[dict]:
    """找 k_chain 个 bits 位素数，按 c 值从大到小排列（q₀ 最大）。

    CKKS 惯例：q₀ > q₁ > ... > p。q₀ 是"活跃层"（最先被 rescale 掉），
    p 是最小素数（辅助层）。

    prefer_small_c=True 时优先选 c = qi - 2^(bits-1) 较小的候选。
    """
    if k_chain < 1:
        return []
    base = 1 << (bits - 1)  # 例如 2^44

    # 先暴力搜前 k_chain*3 个满足条件的素数，然后按 c 值排序取前 k_chain 个
    found: list[tuple[int, int, int]] = []  # (q, c, k)
    cursor = base  # 从 base 开始搜
    while len(found) < k_chain * 3:
        q, k = find_next_prime(bits, cond, cursor)
        c = q - base
        found.append((q, c, k))
        cursor = q + 1  # 下一个从 q+1 开始

    # 按 c 值升序排序（取 c 最小的前 k_chain 个），再按 c 降序作为 q₀..q(K-1)
    found.sort(key=lambda x: x[1])
    picked = found[:k_chain]
    picked.sort(key=lambda x: -x[1])  # q₀ 最大

    result = []
    for q, c, kk in picked:
        g = primitive_root(q)
        omega = pow(g, (q - 1) // (cond // 2), q)  # N 阶根，omega = g^((q-1)/N)
        omega_inv = pow(omega, -1, q)
        N = cond // 2
        N_INV = pow(N, -1, q)
        result.append({
            "q": q,
            "q_bits": q.bit_length(),
            "c": c,
            "c_bits": c.bit_length() if c > 0 else 0,
            "k_in_search": kk,
            "primitive_root": g,
            "omega": omega,
            "omega_inv": omega_inv,
            "N": N,
            "N_INV": N_INV,
            "is_prime": is_prime(q),
            "cond_satisfied": (q - 1) % cond == 0,
            "omega_N_mod_q": pow(omega, N, q),
            "omega_inv_N_mod_q": pow(omega_inv, N, q),
            "omega_omega_inv_mod_q": (omega * omega_inv) % q,
            "N_N_INV_mod_q": (N * N_INV) % q,
        })
    return result


def check_chain_parity(chain: list[dict]) -> list[str]:
    """校验模数链互素（不同素数天然互素，但需保证所有素数不同）。"""
    qs = [x["q"] for x in chain]
    errs = []
    for i, qi in enumerate(qs):
        for j, qj in enumerate(qs):
            if i != j and qi == qj:
                errs.append(f"q[{i}] == q[{j}] = {qi}（模数链素数必须两两不同）")
    # 简单互素校验：两两 gcd == 1
    for i in range(len(qs)):
        for j in range(i + 1, len(qs)):
            g = math.gcd(qs[i], qs[j])
            if g != 1:
                errs.append(f"gcd(q[{i}], q[{j}]) = {g} != 1")
    return errs


# ---------------------------------------------------------------- 输出
def format_sv_header(tag: str, chain: list[dict]) -> str:
    lines = []
    lines.append(f"// modulus_chain_{tag}.sv.h")
    lines.append(f"// Auto-generated by scripts/gen_modulus_chain.py")
    lines.append(f"// CKKS modulus chain (K={len(chain)} primes)")
    lines.append(f"// N = {chain[0]['N']}  (N/2 twiddle table size)")
    lines.append(f"// -----------------------------------------------------------------")
    lines.append("")
    lines.append(f"`ifndef MODULUS_CHAIN_{tag.upper()}_SV_H")
    lines.append(f"`define MODULUS_CHAIN_{tag.upper()}_SV_H")
    lines.append("")
    for i, p in enumerate(chain):
        lines.append(f"// [{i}] q = {p['q']}  (c = {p['c']}, bits = {p['q_bits']})")
        lines.append(f"parameter logic [{p['q_bits']-1}:0] Q_VAL[{i}]    = {p['q']};")
        lines.append(f"parameter logic [{p['q_bits']-1}:0] OMEGA[{i}]   = {p['omega']};")
        lines.append(f"parameter logic [{p['q_bits']-1}:0] OMEGA_INV[{i}] = {p['omega_inv']};")
        lines.append(f"parameter logic [{p['q_bits']-1}:0] N_INV[{i}]   = {p['N_INV']};")
        lines.append("")
    lines.append(f"`endif // MODULUS_CHAIN_{tag.upper()}_SV_H")
    return "\n".join(lines) + "\n"


def format_txt_report(chain: list[dict], tag: str) -> str:
    lines = []
    lines.append(f"# CKKS modulus chain ({tag})")
    lines.append(f"# K = {len(chain)} primes")
    lines.append(f"# N = {chain[0]['N']}")
    lines.append(f"")
    lines.append(f"| # | q | bits | c | omega | omega_inv | N_INV |")
    lines.append(f"|---|---|------|---|-------|-----------|-------|")
    for i, p in enumerate(chain):
        lines.append(f"| {i} | {p['q']} | {p['q_bits']} | {p['c']} | "
                     f"{p['omega']} | {p['omega_inv']} | {p['N_INV']} |")
    lines.append(f"")
    lines.append(f"# 校验：")
    lines.append(f"#   is_prime:             all True?")
    lines.append(f"#   cond_satisfied:       all True?  (2N | qi-1)")
    lines.append(f"#   omega^N mod q == 1:   all True?")
    lines.append(f"#   omega_inv^N mod q == 1: all True?")
    lines.append(f"#   omega*omega_inv mod q == 1: all True?")
    lines.append(f"#   N * N_INV mod q == 1: all True?")
    lines.append(f"#   pairwise gcd == 1:    {check_chain_parity(chain)}")
    lines.append(f"")
    lines.append(f"# fast-red 兼容性分析：")
    for i, p in enumerate(chain):
        c = p["c"]
        if c > 0:
            # 检查 c 是否是 2^k + 1 形式
            is_mersenne_like = (c & (c - 1)) == 0  # c-1 是 2 的幂
            c_str = f"2^{int(math.log2(c - 1)) + 1} + 1" if is_mersenne_like and c > 1 else f"任意值"
            lines.append(f"#   [{i}] c = {c} = {c_str}  "
                         f"{'✓ shift-and-add 单次' if is_mersenne_like else '⚠ fast-red 需重参数化'}")
        else:
            lines.append(f"#   [{i}] c = 0  (q = 2^(bits-1))")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- 主流程
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=int, default=4, help="模数链长度 K（含 p 辅助层）")
    ap.add_argument("--bits", type=int, default=45, help="素数位宽（对齐 fast-red）")
    ap.add_argument("--n", type=int, default=16384, help="NTT 长度 N = 2^logN")
    ap.add_argument("--tag", default="chain4", help="输出文件后缀 tag")
    ap.add_argument("--outdir", default=None, help="输出目录（默认 rtl/m2/）")
    ap.add_argument("--chain-file", default=None, help="已有 chain JSON 文件，用于 verify-only")
    ap.add_argument("--verify-only", action="store_true", help="只校验不写文件")
    args = ap.parse_args()

    if args.n & (args.n - 1):
        print(f"[FAIL] N={args.n} 必须是 2 的幂", file=sys.stderr)
        return 2
    cond = 2 * args.n  # 2N 条件

    if args.chain_file:
        with io.open(args.chain_file, "r", encoding="utf-8") as f:
            chain = json.load(f)
    else:
        print(f"[INFO] 搜索 {args.k} 个 {args.bits}-bit 素数（2N | qi-1, N={args.n}）...")
        chain = find_k_primes(args.k, args.bits, cond)

    # 校验
    errs = check_chain_parity(chain)
    for i, p in enumerate(chain):
        if not p.get("is_prime"):
            errs.append(f"q[{i}] 不是素数")
        if not p.get("cond_satisfied"):
            errs.append(f"q[{i}] 不满足 2N | qi-1")
        if p.get("omega_N_mod_q") != 1:
            errs.append(f"q[{i}] omega^N mod q = {p['omega_N_mod_q']} != 1")
        if p.get("omega_inv_N_mod_q") != 1:
            errs.append(f"q[{i}] omega_inv^N mod q != 1")
        if p.get("omega_omega_inv_mod_q") != 1:
            errs.append(f"q[{i}] omega*omega_inv mod q != 1")
        if p.get("N_N_INV_mod_q") != 1:
            errs.append(f"q[{i}] N*N_INV mod q != 1")
    if errs:
        print(f"[FAIL] 校验失败：", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 3

    print(f"[OK] K={len(chain)} 素数模数链已生成并全部通过校验")
    for i, p in enumerate(chain):
        print(f"  [{i}] q = {p['q']}  (c = {p['c']}, {p['q_bits']}-bit)")

    if args.verify_only:
        print("[DONE] verify-only mode, no files written")
        return 0

    outdir = Path(args.outdir) if args.outdir else Path("rtl/m2")
    outdir.mkdir(parents=True, exist_ok=True)

    # JSON
    (outdir / f"modulus_chain_{args.tag}.json").write_text(
        json.dumps(chain, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    # SV.h
    (outdir / f"modulus_chain_{args.tag}.sv.h").write_text(
        format_sv_header(args.tag, chain), encoding="utf-8"
    )
    # TXT
    (outdir / f"modulus_chain_{args.tag}.txt").write_text(
        format_txt_report(chain, args.tag), encoding="utf-8"
    )

    print(f"[WRITE] {outdir / f'modulus_chain_{args.tag}.json'}")
    print(f"[WRITE] {outdir / f'modulus_chain_{args.tag}.sv.h'}")
    print(f"[WRITE] {outdir / f'modulus_chain_{args.tag}.txt'}")
    print(f"[DONE]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
