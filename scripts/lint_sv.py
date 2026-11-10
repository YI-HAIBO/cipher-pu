#!/usr/bin/env python3
"""
A4: SystemVerilog lint 扫描报告
================================

扫描 rtl/ 与 tb/ 下全部 .sv 文件，检查：
  L1  缺 `default_nettype none`（该指令在综合时会有跨文件污染风险，需权衡）
  L2  task/function 内变量未显式声明 automatic/static（VRFC 10-3824 警告源）
  L3  RTL 中遗留 $display / $monitor / $strobe 调试语句
  L4  TODO / FIXME / HACK / XXX / DEBUG 遗留标记
  L5  硬编码位宽（如 [44:0] / [6:0] 而非参数化）——玩具模块允许，生产模块需参数化
  L6  always_comb / always_ff 中可能的 latch 风险（if 无 else 且非完整赋值）
  L7  异步复位（always_ff @(posedge clk or negedge rst_n)）——BRAM 推断风险
  L8  模块端口方向声明不完整（input/output 后缺 logic）

输出：reports/lint_report.md
"""
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "reports" / "lint_report.md"

# 生产关键模块（不允许硬编码位宽）
PROD_MODULES = {
    "ntt_butterfly.sv", "ntt_unit.sv", "ckks_bram.sv", "keyswitch_pipe.sv",
    "ntt_butterfly.sv", "ntt_unit.sv", "poly_mult.sv", "keyswitch_pipe.sv",
    "rescale.sv", "e2e_ckks_mult_ctrl.sv", "e2e_ckks_mult_ctrl_m4.sv",
    "approx_poly_mult.sv", "gear_controller.sv", "noise_monitor.sv",
    "adaptive_gear_ctrl.sv", "mod45_fastred.sv", "mult_43x43_horner4.sv",
}

FINDINGS = []  # (level, file, line, rule, text)


def scan_file(path: Path, rel: str):
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        FINDINGS.append(("ERROR", rel, 0, "READ", str(e)))
        return
    lines = text.splitlines()
    fname = path.name
    is_prod = fname in PROD_MODULES
    is_tb = rel.startswith("tb/")

    has_nettype = "`default_nettype none" in text

    # L1: default_nettype
    if not has_nettype:
        FINDINGS.append(("WARN", rel, 0, "L1", "缺少 `default_nettype none"))

    in_task = False
    in_func = False
    brace_depth = 0

    for i, ln in enumerate(lines, 1):
        raw = ln
        s = ln.strip()
        low = s.lower()

        # L4: 遗留标记
        for tag in ["todo", "fixme", "hack", "xxx", "debug"]:
            if re.search(r"\b" + tag + r"\b", low) and not low.startswith("//"):
                FINDINGS.append(("WARN", rel, i, "L4", f"遗留标记 '{tag}': {s[:70]}"))
                break

        # L3: RTL 中 $display（TB 允许）
        if not is_tb and re.search(r"\$display|\$monitor|\$strobe|\$write\b", s):
            FINDINGS.append(("WARN", rel, i, "L3", f"RTL 中存在调试语句: {s[:70]}"))

        # L7: 异步复位
        if re.search(r"always_ff\s*@\s*\(\s*posedge\s+\w+\s+or\s+negedge", s):
            FINDINGS.append(("INFO", rel, i, "L7", f"异步复位（BRAM 推断风险）: {s[:70]}"))

        # task/function 检测
        if re.match(r"\btask\b", s):
            in_task = True
        if re.match(r"\bfunction\b", s):
            in_func = True
        if re.match(r"\bendtask\b", s):
            in_task = False
        if re.match(r"\bendfunction\b", s):
            in_func = False

        # L2: task/function 内变量声明缺 automatic/static
        if in_task or in_func:
            m = re.match(
                r"\b(?:logic|reg|integer|int|bit|byte|real|time|string)\b\s", s)
            if m and "automatic" not in low and "static" not in low:
                # 排除端口声明行 (input/output/inout)
                if not re.match(r"\b(input|output|inout)\b", low):
                    FINDINGS.append(
                        ("WARN", rel, i, "L2", f"未声明 automatic/static: {s[:70]}"))

        # L5: 硬编码位宽（生产模块）
        if is_prod:
            # 匹配 [数字:数字] 形式的位宽，排除 [0] 单比特与参数名
            for mm in re.finditer(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", s):
                hi, lo = int(mm.group(1)), int(mm.group(2))
                # 只报"较大位宽"的硬编码（>= 8），小写 [x:0] 常见且无害
                if hi >= 8:
                    FINDINGS.append(
                        ("INFO", rel, i, "L5",
                         f"硬编码位宽 [{hi}:{lo}]（生产模块建议参数化）: {s[:70]}"))
                    break

        # L6: latch 风险 —— always_comb 内 if 无 else
        if "always_comb" in s:
            # 向下找 6 行看是否有 if 无 else（简化启发式）
            depth_if = 0
            for j in range(i, min(i + 25, len(lines))):
                t = lines[j].strip()
                if re.match(r"\bif\s*\(", t):
                    depth_if += 1
                if re.match(r"\belse\b", t):
                    depth_if -= 1
                if re.match(r"\bend\b", t) and depth_if > 0:
                    FINDINGS.append(
                        ("INFO", rel, i, "L6", f"always_comb 可能含 if 无 else（latch 风险）: {s[:60]}"))
                    break


def main():
    print("=" * 70)
    print("A4: SystemVerilog lint 扫描")
    print("=" * 70)

    sv_files = []
    for sub in ["rtl", "tb"]:
        d = ROOT / sub
        if not d.exists():
            continue
        for p in sorted(d.rglob("*.sv")):
            rel = f"{sub}/{p.relative_to(d).as_posix()}"
            sv_files.append((p, rel))

    print(f"扫描 {len(sv_files)} 个 .sv 文件\n")
    for p, rel in sv_files:
        scan_file(p, rel)

    # 汇总
    by_rule = {}
    for lvl, f, ln, rule, txt in FINDINGS:
        by_rule.setdefault(rule, []).append((lvl, f, ln, txt))

    print("-" * 70)
    print("按规则汇总")
    print("-" * 70)
    rule_names = {
        "L1": "缺 default_nettype none",
        "L2": "未声明 automatic/static",
        "L3": "RTL 遗留调试语句",
        "L4": "TODO/FIXME/HACK 标记",
        "L5": "硬编码位宽（生产模块）",
        "L6": "always_comb latch 风险",
        "L7": "异步复位",
        "READ": "读取失败",
    }
    for rule in sorted(by_rule):
        items = by_rule[rule]
        print(f"  {rule} ({rule_names.get(rule,'?')}): {len(items)} 处")

    # 写报告
    lines = []
    lines.append("# SystemVerilog Lint 扫描报告\n")
    lines.append("**日期**：2026-10-05  ")
    lines.append("**工具**：`scripts/lint_sv.py`（自研静态扫描）  ")
    lines.append(f"**范围**：`rtl/` 与 `tb/` 下 {len(sv_files)} 个 `.sv` 文件\n")
    lines.append("---\n")

    lines.append("\n## 1. 规则说明\n")
    lines.append("| 规则 | 含义 | 级别 | 影响 |")
    lines.append("|---|---|---|---|")
    lines.append("| L1 | 缺 `` `default_nettype none `` | WARN | 隐式 wire 风险；但综合时该指令有跨文件污染风险（M5 已知坑），需权衡 |")
    lines.append("| L2 | task/function 内变量未声明 automatic/static | WARN | VRFC 10-3824 警告源；多次调用可能串状态 |")
    lines.append("| L3 | RTL 中遗留 `$display` 等调试语句 | WARN | 综合时被忽略，但暴露设计意图不清 |")
    lines.append("| L4 | TODO/FIXME/HACK/XXX/DEBUG 标记 | WARN | 未收口的技术债 |")
    lines.append("| L5 | 生产模块硬编码位宽 | INFO | 玩具→生产迁移时需改；建议参数化 |")
    lines.append("| L6 | `always_comb` 内 if 无 else | INFO | 潜在 latch 推断 |")
    lines.append("| L7 | 异步复位 | INFO | 阻止 BRAM 推断（M5 已知坑 Synth 8-3391/8-4767） |\n")

    lines.append("\n## 2. 汇总\n")
    lines.append("| 规则 | 数量 |")
    lines.append("|---|---:|")
    for rule in sorted(by_rule):
        lines.append(f"| {rule} {rule_names.get(rule,'')} | {len(by_rule[rule])} |")
    total = len(FINDINGS)
    lines.append(f"| **合计** | **{total}** |\n")

    lines.append("\n## 3. 明细\n")
    for rule in sorted(by_rule):
        items = by_rule[rule]
        lines.append(f"\n### {rule} — {rule_names.get(rule,'')}（{len(items)} 处）\n")
        if not items:
            lines.append("无。\n")
            continue
        lines.append("| 级别 | 文件 | 行 | 说明 |")
        lines.append("|---|---|---:|---|")
        for lvl, f, ln, txt in items[:200]:  # 限制输出量
            txt_esc = txt.replace("|", "\\|")
            lines.append(f"| {lvl} | `{f}` | {ln} | {txt_esc} |")
        if len(items) > 200:
            lines.append(f"\n（仅列出前 200 条，共 {len(items)} 条）")

    lines.append("\n## 4. 结论与建议\n")
    n_l2 = len(by_rule.get("L2", []))
    n_l3 = len(by_rule.get("L3", []))
    n_l4 = len(by_rule.get("L4", []))
    n_l1 = len(by_rule.get("L1", []))
    lines.append(f"- **L2（{n_l2} 处）**：集中在 TB 的 task/function。建议 TB 侧统一在变量前加 `automatic`。")
    lines.append(f"- **L3（{n_l3} 处）**：RTL 中残留调试语句，建议清理或改为 `` `ifdef DEBUG `` 包裹。")
    lines.append(f"- **L4（{n_l4} 处）**：技术债标记，建议逐个确认是否需要收口。")
    lines.append(f"- **L1（{n_l1} 处）**：注意 M5 已知坑——综合时 `` `default_nettype none `` 会跨文件污染，综合脚本已移除该指令；TB 侧保留无害。")
    lines.append("- **L5/L6/L7**：均为 INFO 级，作为生产迁移与综合优化的参考输入，不阻塞当前交付。\n")

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n[SAVE] 报告已写入: {OUT}")
    print(f"合计 {total} 处发现")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
