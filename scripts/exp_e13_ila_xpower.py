#!/usr/bin/env python3
"""
E13: ILA 仿真抓取 + XPower 功耗分析
=====================================

步骤：
  1. 跑 e2e 仿真 + VCD 活动记录（run_sim_e2e_saif.py）
  2. XPower 分析：默认活动率 vs VCD 驱动（run_xpower_saif.tcl）
  3. 生成对比报告

输出：
  - reports/experiments/e13_ila_xpower.json
  - reports/experiments/e13_ila_xpower.md
  - reports/power/e2e_au25p_n12_vcd/e2e_power_vcd.rpt
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "reports" / "experiments"
VIVADO_BIN = os.environ.get("VIVADO_BIN", "vivado")
VIVADO = Path(VIVADO_BIN)
VIVADO_BAT = VIVADO / "vivado.bat"


def _parse_power_report(rpt_path):
    """从 XPower report 中提取关键功耗数据。"""
    result = {
        "total_power_w": None,
        "dynamic_w": None,
        "static_w": None,
        "confidence": None,
        "activity_file": None,
        "components": {},
    }
    if not rpt_path.exists():
        return result

    text = rpt_path.read_text(encoding="utf-8", errors="replace")

    # Total On-Chip Power
    m = re.search(r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)", text)
    if m:
        result["total_power_w"] = float(m.group(1))

    # Dynamic
    m = re.search(r"Dynamic \(W\)\s*\|\s*([\d.]+)", text)
    if m:
        result["dynamic_w"] = float(m.group(1))

    # Static
    m = re.search(r"Device Static \(W\)\s*\|\s*([\d.]+)", text)
    if m:
        result["static_w"] = float(m.group(1))

    # Confidence
    m = re.search(r"Confidence Level\s*\|\s*(\w+)", text)
    if m:
        result["confidence"] = m.group(1)

    # Activity file
    m = re.search(r"Simulation Activity File\s*\|\s*(\S+)", text)
    if m:
        result["activity_file"] = m.group(1)

    # Components (from On-Chip Components table)
    comp_pattern = re.compile(
        r"\|\s*(\w[\w\s]*?)\s*\|\s*([\d.]+)\s*\|\s*(\d+)\s*\|\s*(\S+)\s*\|\s*([\d.]+)\s*\|"
    )
    for m in comp_pattern.finditer(text):
        name = m.group(1).strip()
        power = float(m.group(2))
        used = int(m.group(3))
        result["components"][name] = {"power_w": power, "used": used}

    return result


def _run_vivado(tcl_script, label):
    """Run Vivado in batch mode with given TCL script (via .bat wrapper)."""
    print(f"\n{'='*60}")
    print(f"Running: {label}")
    print(f"TCL: {tcl_script}")
    print(f"{'='*60}")

    t0 = time.time()
    # 用 .bat 包装器避免 cmd.exe 引号嵌套问题
    bat_path = ROOT / "_tmp_vivado_run.bat"
    cmd_str = (
        f'@echo off\r\n'
        f'"{VIVADO_BAT}" -mode batch -source "{tcl_script}"\r\n'
        f'exit %%ERRORLEVEL%%'
    )
    bat_path.write_text(cmd_str, encoding="cp936")

    r = subprocess.run(
        ["cmd.exe", "/c", str(bat_path)],
        cwd=str(ROOT),
        capture_output=True,
        timeout=600,
    )
    elapsed = time.time() - t0

    out = (r.stdout or b"").decode("utf-8", errors="replace") + \
          (r.stderr or b"").decode("utf-8", errors="replace")

    print(f"  退出码: {r.returncode}, 耗时: {elapsed:.1f}s")
    tail = out[-3000:] if len(out) > 3000 else out
    print(tail)

    return r.returncode, out, elapsed


def main():
    print("=" * 60)
    print("E13: ILA 仿真抓取 + XPower 功耗分析")
    print("=" * 60)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # ---- Step 1: 仿真 + VCD ----
    print("\n[Step 1/3] 运行 e2e 仿真 + VCD 活动记录...")
    sim_script = ROOT / "scripts" / "run_sim_e2e_saif.py"
    sim_py = sys.executable
    r = subprocess.run(
        [sim_py, str(sim_script)],
        cwd=str(ROOT),
        capture_output=True,
        timeout=600,
    )
    sim_out = (r.stdout or b"").decode("utf-8", errors="replace") + \
              (r.stderr or b"").decode("utf-8", errors="replace")
    print(sim_out[-2000:] if len(sim_out) > 2000 else sim_out)
    if r.returncode != 0:
        print(f"FAIL: 仿真步骤失败 (rc={r.returncode})")
        return 1
    print("PASS: 仿真 + VCD")

    # ---- Step 2: XPower with VCD ----
    print("\n[Step 2/3] 运行 XPower 功耗分析（默认 vs VCD）...")
    tcl_script = ROOT / "scripts" / "run_xpower_saif.tcl"
    rc, xpower_out, elapsed = _run_vivado(tcl_script, "XPower VCD analysis")
    if rc != 0:
        print(f"FAIL: XPower 失败 (rc={rc})")
        return 1
    print("PASS: XPower")

    # ---- Step 3: 解析报告 + 生成对比 ----
    print("\n[Step 3/3] 解析功耗报告 + 生成对比...")

    power_dir = ROOT / "reports" / "power" / "e2e_au25p_n12_vcd"
    default_rpt = power_dir / "e2e_power_default.rpt"
    vcd_rpt = power_dir / "e2e_power_vcd.rpt"

    default_power = _parse_power_report(default_rpt)
    vcd_power = _parse_power_report(vcd_rpt)

    # 计算差异
    comparison = {}
    if default_power["total_power_w"] and vcd_power["total_power_w"]:
        comparison["total_power_delta_w"] = round(
            vcd_power["total_power_w"] - default_power["total_power_w"], 4
        )
        comparison["total_power_delta_pct"] = round(
            (vcd_power["total_power_w"] - default_power["total_power_w"])
            / default_power["total_power_w"] * 100, 2
        )
    if default_power["dynamic_w"] and vcd_power["dynamic_w"]:
        comparison["dynamic_delta_w"] = round(
            vcd_power["dynamic_w"] - default_power["dynamic_w"], 4
        )
        comparison["dynamic_delta_pct"] = round(
            (vcd_power["dynamic_w"] - default_power["dynamic_w"])
            / default_power["dynamic_w"] * 100, 2
        )

    # 保存 JSON
    output = {
        "experiment": "E13: ILA 仿真抓取 + XPower 功耗分析",
        "method": "VCD activity recording from e2e simulation + XPower report_power -simdata",
        "design": "e2e_ckks_mult_ctrl_m4",
        "device": "xcau25p-ffvb676-1-e",
        "n": 16,
        "simulation_time_ns": 500000,
        "vcd_file": str(ROOT / "sim" / "tb_e2e_saif_minimal" / "e2e.vcd"),
        "default_activity_power": default_power,
        "vcd_driven_power": vcd_power,
        "comparison": comparison,
    }

    json_path = OUT_DIR / "e13_ila_xpower.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"  JSON: {json_path}")

    # 生成 MD
    md_path = OUT_DIR / "e13_ila_xpower.md"
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# E13: ILA 仿真抓取 + XPower 功耗分析\n\n")
        f.write("## 方法\n\n")
        f.write("- 仿真：`tb_e2e_saif_minimal`（N=16, Q=113/97, 完整密文乘法流程）\n")
        f.write("- VCD 记录：TB 内 `$dumpfile` / `$dumpvars`，仿真时间 500,000 ns\n")
        f.write("- 功耗分析：`report_power -simdata <vcd>` 对比默认活动率\n")
        f.write("- 器件：xcau25p-ffvb676-1-e\n\n")

        f.write("## 功耗对比\n\n")
        f.write("| 指标 | 默认活动率 | VCD 驱动 | 差异 |\n")
        f.write("|------|-----------|---------|------|\n")

        for label, key in [
            ("总功耗 (W)", "total_power_w"),
            ("动态功耗 (W)", "dynamic_w"),
            ("静态功耗 (W)", "static_w"),
        ]:
            dv = default_power.get(key)
            sv = vcd_power.get(key)
            if dv is not None and sv is not None:
                delta = sv - dv
                f.write(f"| {label} | {dv:.4f} | {sv:.4f} | {delta:+.4f} |\n")
            elif dv is not None:
                f.write(f"| {label} | {dv:.4f} | N/A | N/A |\n")

        f.write("\n")
        f.write(f"- 默认 Confidence: {default_power.get('confidence', 'N/A')}\n")
        f.write(f"- VCD Confidence: {vcd_power.get('confidence', 'N/A')}\n")

        if comparison:
            f.write("\n## 差异分析\n\n")
            if "total_power_delta_pct" in comparison:
                f.write(f"- 总功耗差异: {comparison['total_power_delta_w']:+.4f} W "
                        f"({comparison['total_power_delta_pct']:+.2f}%)\n")
            if "dynamic_delta_pct" in comparison:
                f.write(f"- 动态功耗差异: {comparison['dynamic_delta_w']:+.4f} W "
                        f"({comparison['dynamic_delta_pct']:+.2f}%)\n")
            f.write("- VCD 驱动功耗反映真实切换活动，置信度更高\n")
            f.write("- 默认活动率通常偏保守（假设 50% 切换），VCD 提供真实值\n")

        f.write("\n## 详细报告\n\n")
        f.write(f"- 默认: `reports/power/e2e_au25p_n12_vcd/e2e_power_default.rpt`\n")
        f.write(f"- VCD: `reports/power/e2e_au25p_n12_vcd/e2e_power_vcd.rpt`\n")

    print(f"  MD: {md_path}")
    print("\n完成 ✓")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())