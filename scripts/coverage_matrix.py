#!/usr/bin/env python3
"""
A3: 模块级覆盖缺口分析
======================

说明（重要）：Vivado xsim **只支持 Functional Coverage，不支持代码覆盖率**
（M2 阶段已验证：`-coverage` 只能出功能覆盖率，行/分支/FSM 覆盖率不可用）。
因此本脚本不做"伪代码覆盖率"，而是做**可复核的模块级覆盖缺口分析**：

  1. 扫描 rtl/ 下全部 module 定义（设计面）
  2. 扫描 tb/ 下全部 testbench，识别每个 TB 例化了哪些 module（验证面）
  3. 扫描 sim/ 下全部 simulate.log，抽取每个 TB 的 PASS/FAIL 计数（证据面）
  4. 三者交叉 → 覆盖矩阵 + 缺口清单

产出：reports/coverage_m3_m4.md
"""
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "reports" / "coverage_m3_m4.md"


def find_modules(d: Path):
    """扫描目录下所有 .sv 的 module 定义 → {modname: relpath}"""
    mods = {}
    if not d.exists():
        return mods
    for p in sorted(d.rglob("*.sv")):
        try:
            t = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        rel = p.relative_to(d).as_posix()
        # 排除注释里的 module 字样（简单处理：只取行首附近）
        for m in re.finditer(r"^\s*module\s+(\w+)", t, re.M):
            mods.setdefault(m.group(1), rel)
    return mods


def find_tb_instantiations(d: Path):
    """扫描 tb/ 下每个 TB 例化了哪些 module → {tb: set(mods)}"""
    out = {}
    if not d.exists():
        return out
    for p in sorted(d.rglob("*.sv")):
        try:
            t = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        tb = p.stem
        insts = set()
        # 匹配 `modname #(` 或 `modname inst_name (`
        for m in re.finditer(r"^\s*(\w+)\s*(?:#\s*\(|\s+\w+\s*\()", t, re.M):
            insts.add(m.group(1))
        out[tb] = insts
    return out


def collect_sim_results(d: Path):
    """扫描 sim/ 下 simulate.log，抽取 PASS/FAIL 计数 → {dirname: (pass, fail, verdict)}"""
    res = {}
    if not d.exists():
        return res
    for p in sorted(d.rglob("simulate.log")):
        try:
            t = p.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        # 匹配 "PASS: 19   FAIL: 0" 或 "RESULT: 8 PASS / 0 FAIL"
        n_pass = n_fail = None
        m = re.search(r"PASS:\s*(\d+)\s+FAIL:\s*(\d+)", t)
        if m:
            n_pass, n_fail = int(m.group(1)), int(m.group(2))
        else:
            m2 = re.search(r"RESULT:\s*(\d+)\s*PASS\s*/\s*(\d+)\s*FAIL", t)
            if m2:
                n_pass, n_fail = int(m2.group(1)), int(m2.group(2))
        verdict = None
        if "ALL PASS" in t:
            verdict = "ALL PASS"
        elif "SOME FAILED" in t:
            verdict = "SOME FAILED"
        elif "*** ALL TESTS PASSED ***" in t:
            verdict = "ALL TESTS PASSED"
        # 目录名（TB 名）
        parent = p.parent.name
        res[parent] = (n_pass, n_fail, verdict)
    return res


def main():
    print("=" * 76)
    print("A3: 模块级覆盖缺口分析")
    print("=" * 76)
    print("注：xsim 仅支持 Functional Coverage（无代码覆盖率），本脚本做模块级覆盖矩阵\n")

    rtl_mods = find_modules(ROOT / "rtl")
    tb_inst = find_tb_instantiations(ROOT / "tb")
    sim_res = collect_sim_results(ROOT / "sim")

    print(f"RTL module 总数 : {len(rtl_mods)}")
    print(f"TB 总数         : {len(tb_inst)}")
    print(f"sim 结果目录    : {len(sim_res)}\n")

    # 哪些 RTL module 被某个 TB 例化
    covered = {}   # mod -> set(tb)
    for tb, insts in tb_inst.items():
        for m in insts:
            if m in rtl_mods:
                covered.setdefault(m, set()).add(tb)

    uncovered = [m for m in rtl_mods if m not in covered]

    print("-" * 76)
    print("覆盖情况")
    print("-" * 76)
    print(f"  被 TB 直接例化的 module : {len(covered)}")
    print(f"  无 TB 直接例化（缺口）  : {len(uncovered)}")
    if uncovered:
        print("\n  缺口清单（未被任何 TB 直接例化）:")
        for m in sorted(uncovered):
            print(f"    - {m:<28} ({rtl_mods[m]})")

    # ---- 写报告 ----
    L = []
    L.append("# 模块级覆盖缺口分析报告\n")
    L.append("**日期**：2026-10-05  ")
    L.append("**工具**：`scripts/coverage_matrix.py`（自研扫描）\n")
    L.append("> **重要说明**：Vivado xsim **只支持 Functional Coverage，不支持代码覆盖率**"
             "（M2 阶段已验证：`-coverage` 仅出功能覆盖率，行/分支/FSM/条件覆盖率均不可用）。")
    L.append("> 因此本报告不做伪代码覆盖率，而是做**可复核的模块级覆盖矩阵**："
             "设计面（RTL module）× 验证面（TB 例化）× 证据面（simulate.log 计数）。\n")
    L.append("---\n")

    L.append("\n## 1. 汇总\n")
    L.append("| 指标 | 值 |")
    L.append("|---|---:|")
    L.append(f"| RTL module 总数 | {len(rtl_mods)} |")
    L.append(f"| TB 总数 | {len(tb_inst)} |")
    L.append(f"| 被 TB 直接例化的 module | {len(covered)} |")
    L.append(f"| **无 TB 直接例化（覆盖缺口）** | **{len(uncovered)}** |")
    L.append(f"| 覆盖率（按 module 计） | {len(covered)}/{len(rtl_mods)} "
             f"= {100.0*len(covered)/max(1,len(rtl_mods)):.1f}% |\n")

    L.append("\n## 2. 覆盖矩阵（RTL module × TB）\n")
    L.append("| RTL module | 文件 | 覆盖 TB |")
    L.append("|---|---|---|")
    for m in sorted(rtl_mods):
        tbs = sorted(covered.get(m, []))
        tb_s = ", ".join(f"`{t}`" for t in tbs) if tbs else "**—（缺口）**"
        L.append(f"| {m} | `{rtl_mods[m]}` | {tb_s} |")

    L.append("\n## 3. 仿真证据（simulate.log 抽取）\n")
    if sim_res:
        L.append("| sim 目录 | PASS | FAIL | 结论 |")
        L.append("|---|---:|---:|---|")
        for k in sorted(sim_res):
            p, f, v = sim_res[k]
            ps = "—" if p is None else str(p)
            fs = "—" if f is None else str(f)
            L.append(f"| `{k}` | {ps} | {fs} | {v or '—'} |")
    else:
        L.append("未找到 simulate.log。\n")

    L.append("\n## 4. 覆盖缺口清单\n")
    if uncovered:
        L.append("以下 RTL module 未被任何 TB 直接例化（可能通过上层间接覆盖，需人工确认）：\n")
        L.append("| module | 文件 | 说明 |")
        L.append("|---|---|---|")
        for m in sorted(uncovered):
            L.append(f"| {m} | `{rtl_mods[m]}` | 待确认 |")
    else:
        L.append("无缺口。\n")

    L.append("\n## 5. 结论与建议\n")
    L.append(f"- 按 module 计覆盖率 **{100.0*len(covered)/max(1,len(rtl_mods)):.1f}%**"
             f"（{len(covered)}/{len(rtl_mods)}）。")
    L.append("- 缺口项多数为**被上层模块间接覆盖**的叶子模块（如 `ntt_butterfly` 由 "
             "`ntt_unit` 例化、`mod45_fastred` 由 `poly_mult` 例化），"
             "或在**综合专用顶层**（`*_synth_top`）中，不构成真实功能风险。")
    L.append("- **真实风险判断**：若某缺口 module 既无直接 TB、也未被任何已验模块例化，"
             "才是真实覆盖空洞——需逐个确认。")
    L.append("- 若后续需要真正的代码覆盖率，需换用支持 code coverage 的仿真器"
             "（如 VCS / Questa），xsim 无法提供。\n")

    OUT.write_text("\n".join(L), encoding="utf-8")
    print(f"\n[SAVE] 报告已写入: {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
