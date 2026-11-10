#!/usr/bin/env python3
"""
run_synth_prod_blocks.py — 生产配置分模块 DCP 综合驱动

Phase 1: OOC 综合 3 个叶子子模块（approx_poly_mult / keyswitch_pipe / rescale）
        → export_dcp + report_utilization + report_timing_summary
Phase 2: (可选) 顶层集成综合，读入 DCP（未来工作）

用法：
    python run_synth_prod_blocks.py                # 跑完 3 个子模块
    python run_synth_prod_blocks.py --aggregate    # 仅解析已有报告
    python run_synth_prod_blocks.py --only <mod>   # 只跑指定子模块

预计耗时：
    approx_poly_mult: 20-40 min（含 2 NTT + 40 RAMB36E1）
    keyswitch_pipe:   30-60 min（含 2× poly_mult + 80 RAMB36E1）
    rescale:          5-15 min（自包含）
"""
import os
import re
import subprocess
import sys
import time
import json
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIVADO_BAT = Path(os.environ.get("VIVADO_BAT", "vivado"))
TCL = ROOT / "scripts/run_synth_prod_blocks.tcl"

# --- 生产参数（与 TCL 保持一致；q3 统一后 2026-10-06）---
Q_IN = 17592186175489    # q3
Q_OUT = 17592186372097   # q1


def mod_inv(a, m):
    """a^-1 mod m（扩展欧几里得）"""
    g, x, _ = _egcd(a % m, m)
    assert g == 1, f"{a} 与 {m} 不互素"
    return x % m


def _egcd(a, b):
    if b == 0:
        return (a, 1, 0)
    g, x, y = _egcd(b, a % b)
    return (g, y, x - (a // b) * y)


# N^-1 mod q3 @ 各 LOG_N（自动算；N=2^14 值 = 17591112433657 与项目原值一致）
def n_inv_for(log_n):
    return mod_inv(1 << log_n, Q_IN)


# 运行配置（--log-n 覆盖）
LOG_N = 14
OUT_DIR = ROOT / "reports/synth/prod_blocks_au25p"
LOG_FILE = OUT_DIR / "synth_prod_blocks.log"

# 每个子模块在生产 E2E 中的实例数（用于聚合面积）
# 2026-10-06（Task #63）：approx 时分复用后 4 个并行实例收敛为 1 个共享实例，
# 故 approx_poly_mult 实例数 4 → 1。
INSTANCES = {
    "approx_poly_mult": 1,   # u_pm_shared（原 u_pm0/pm1a/pm1b/pm2）
    "keyswitch_pipe":   1,   # u_ksw
    "rescale":          2,   # u_rescale_0, u_rescale_1
}

# 2026-10-06（Task #63）：顶层直接综合实测（含 FSM/缓冲/路由），
# 存在时优先作为 E2E 面积权威值，子模块累加仅作交叉验证。
E2E_TOP = "e2e_ckks_mult_ctrl_m4"

MODULES = list(INSTANCES.keys())


def run_vivado(phase_arg="", timeout_s=14400):
    """调用 Vivado 执行 Tcl 脚本。timeout 4 小时保底。"""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("=" * 60)
    print(f"分模块 DCP 综合 (Phase 1)")
    print(f"Vivado: {VIVADO_BAT}")
    print(f"TCL:    {TCL}")
    print(f"Log:    {LOG_FILE}")
    if phase_arg:
        print(f"Only:   {phase_arg}")
    print(f"开始时间: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"超时:     {timeout_s/60:.0f} 分钟")
    print("=" * 60)

    t0 = time.time()
    # 通过环境变量传递单块模式（-tclargs 在 Vivado batch 模式下不可靠）
    env = os.environ.copy()
    if phase_arg:
        env["SYNTH_ONLY"] = phase_arg
    env["PROD_LOG_N"] = str(LOG_N)
    env["PROD_N_INV"] = str(n_inv_for(LOG_N))
    env["PROD_OUT_DIR"] = str(OUT_DIR)

    cmd = [str(VIVADO_BAT), "-mode", "batch",
           "-source", str(TCL),
           "-nojournal",
           "-log", str(LOG_FILE)]

    # 注意：不能直接用 subprocess.run(timeout=...)。
    # vivado.bat 会派生 detached 的 vivado.exe；超时 kill 只杀到 bat 外壳，
    # 而 run() 内部的 process.wait() 会一直阻塞到 vivado.exe 自己跑完，
    # 导致"超时 4 分钟却实际等了 27 分钟 + 误报 exit -1"（DCP 其实已写完）。
    # 这里用 communicate() + 短二次等待，超时后最多多等 60 s。
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, shell=False
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout_s)
            rc = proc.returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                stdout, stderr = proc.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
                stdout, stderr = proc.communicate()
            rc = -1
            timed_out = True
            print(f"  !! Vivado 超过 {timeout_s}s 未返回，已终止（DCP 可能不完整，需重跑）")
        tail = (stdout or b"")[-3000:].decode("utf-8", errors="replace")
        if timed_out:
            tail = f"TIMEOUT after {timeout_s}s\n--- tail ---\n" + tail
    except FileNotFoundError as e:
        print(f"  ERROR: 找不到 {cmd[0]}: {e}")
        return -1

    elapsed = time.time() - t0
    print(f"\n[{elapsed/60:.1f} min] Vivado exit code: {rc}")
    print(f"\n--- log tail ---\n{tail}")
    return rc


def parse_util_rpt(rpt_path: Path):
    """解析 report_utilization 报告（2026.1 表格格式 | Site Type | Used | ... | Available | Util% |）"""
    if not rpt_path.exists():
        return None
    txt = rpt_path.read_bytes().decode("utf-8", errors="replace")
    result = {}

    # 2026.1 表格格式：| Slice LUTs* | 295604 | 0 | 0 | 134600 | 219.62 |
    # 也兼容旧格式：Slice LUTs : N / M
    # UltraScale+ 器件（xcau25p）行名不同：CLB LUTs* / CLB Registers（2026-10-06 实测）
    patterns = {
        "Slice LUTs": r"\|\s*(?:Slice|CLB) LUTs\*?\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
        "Slice Registers": r"\|\s*(?:Slice|CLB) Registers\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
        "LUT as Memory": r"\|\s*LUT as Memory\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
        "F7 Muxes": r"\|\s*F7 Muxes\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
        "DSPs": r"\|\s*DSPs\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
        "Block RAM Tile": r"\|\s*Block RAM Tile\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
        "Block RAM Tile 36Kb": r"\|\s*RAMB36/FIFO\*?\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
        "URAMs": r"\|\s*URAMs?\s*\|\s*([\d,]+)\s*\|\s*[\d,]+\s*\|\s*[\d,]+\s*\|\s*([\d,]+)\s*\|",
    }

    for name, pat in patterns.items():
        m = re.search(pat, txt, re.DOTALL)
        if m:
            used = int(m.group(1).replace(",", ""))
            total = int(m.group(2).replace(",", ""))
            result[name] = (used, total)

    # 兼容旧格式（冒号分隔）
    if not result:
        for pat in ["Slice LUTs", "Slice Registers", "DSPs",
                    "Block RAM Tile", "Block RAM Tile 36Kb"]:
            m = re.search(rf"{re.escape(pat)}\s*:\s*([\d,]+)\s*/\s*([\d,]+)", txt)
            if m:
                result[pat] = (int(m.group(1).replace(",", "")),
                               int(m.group(2).replace(",", "")))

    # WNS（从 timing summary 或 util 报告中抽）
    wns_m = re.search(rf"WNS\s*\(ns\)\s*:\s*(-?[\d.]+)", txt)
    if wns_m:
        result["WNS(ns)"] = float(wns_m.group(1))
    else:
        # 2026.1 timing 报告表格格式：-23.805  -172954.344
        wns_m2 = re.search(rf"WNS\(ns\)\s+TNS\(ns\).*?(-?[\d.]+)\s+(-?[\d.]+)", txt, re.DOTALL)
        if wns_m2:
            result["WNS(ns)"] = float(wns_m2.group(1))

    return result if result else None


def parse_timing_rpt(rpt_path: Path):
    """从 report_timing_summary 抽 WNS/TNS（2026.1 表格格式）"""
    if not rpt_path.exists():
        return None
    txt = rpt_path.read_bytes().decode("utf-8", errors="replace")

    # 2026.1 表格格式：WNS(ns) TNS(ns) ... 然后数据行 -23.805 -172954.344
    wns = None
    tns = None

    # 2026.1 首选：从 "Setup : N Failing Endpoints, Worst Slack X ns, Total Violation Y ns" 一次性拿 WNS+TNS
    setup_m = re.search(
        r"Setup\s*:\s*(\d+)\s+Failing Endpoints,\s+Worst Slack\s+(-?[\d.]+)ns,\s+Total Violation\s+(-?[\d.]+)ns",
        txt,
    )
    if setup_m:
        wns = float(setup_m.group(2))
        tns = float(setup_m.group(3))

    # 备用：从 "Worst Slack" 文本提取 WNS（若未走 Setup 分支）
    if wns is None:
        m = re.search(rf"Worst Slack\s+(-?[\d.]+)ns", txt)
        if m:
            wns = float(m.group(1))

    # 备用：从表头后的数据行提取 WNS+TNS
    if wns is None or tns is None:
        m = re.search(
            rf"WNS\(ns\)\s+TNS\(ns\).*?\n[^\n]*\n\s*([-\d.]+)\s+([-\d.]+)",
            txt, re.DOTALL
        )
        if m:
            if wns is None:
                wns = float(m.group(1))
            tns = float(m.group(2))

    # 备用：Setup 行单独抽 TNS（"Total Violation X ns" 是 TNS）
    if tns is None:
        tv_m = re.search(r"Setup\s*:\s*\d+\s+Failing Endpoints[^,]*,\s+[^,]*,\s+Total Violation\s+(-?[\d.]+)ns", txt)
        if tv_m:
            tns = float(tv_m.group(1))

    # 备用：旧格式 WNS(ns) : -23.805
    if wns is None:
        wns_m = re.search(rf"WNS\s*\(ns\)\s*:\s*(-?[\d.]+)", txt)
        if wns_m:
            wns = float(wns_m.group(1))

    return {
        "WNS(ns)": wns,
        "TNS(ns)": tns,
    }


def aggregate():
    """聚合所有子模块报告 → 论文可用面积/时序摘要。"""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("\n" + "=" * 60)
    print("生产综合：分模块资源聚合")
    print("=" * 60)

    summary = {"modules": {}, "total_estimated": {}}
    total_lut = total_ff = total_dsp = total_bram36 = total_uram = 0
    worst_wns = 0.0
    worst_wns_mod = None

    for mod, n_inst in INSTANCES.items():
        util_path = OUT_DIR / f"{mod}_util.rpt"
        timing_path = OUT_DIR / f"{mod}_timing.rpt"
        dcp_path = OUT_DIR / f"{mod}.dcp"

        util = parse_util_rpt(util_path)
        timing = parse_timing_rpt(timing_path)
        if util is None:
            print(f"  [MISS] {mod}: utilization report 不存在")
            continue

        summary["modules"][mod] = {
            "instances_in_e2e": n_inst,
            "dcp_exists": dcp_path.exists(),
            "dcp_size_mb": round(dcp_path.stat().st_size / 1e6, 2) if dcp_path.exists() else None,
            "utilization": util,
            "timing": timing,
        }

        # 抽关键数字
        lut_used = util.get("Slice LUTs", (0, 0))[0]
        ff_used = util.get("Slice Registers", (0, 0))[0]
        lutmem_used = util.get("LUT as Memory", (0, 0))[0]
        f7_used = util.get("F7 Muxes", (0, 0))[0]
        dsp_used = util.get("DSPs", (0, 0))[0]
        bram_used = util.get("Block RAM Tile 36Kb", util.get("Block RAM Tile", (0, 0)))[0]
        uram_used = util.get("URAMs", (0, 0))[0]
        wns = (timing or {}).get("WNS(ns)") or 0.0

        print(f"\n  {mod}  (×{n_inst} 实例 in E2E)")
        print(f"    LUT:      {lut_used:,}   (LUT as Memory {lutmem_used:,})")
        print(f"    FF:       {ff_used:,}")
        print(f"    F7 Mux:   {f7_used:,}")
        print(f"    DSP:      {dsp_used:,}")
        print(f"    BRAM36:   {bram_used:,}")
        print(f"    URAM:     {uram_used:,}")
        print(f"    WNS:      {wns:+.3f} ns")

        # 累加（按实例数）
        total_lut += lut_used * n_inst
        total_ff += ff_used * n_inst
        total_dsp += dsp_used * n_inst
        total_bram36 += bram_used * n_inst
        total_uram += uram_used * n_inst
        if wns < worst_wns or worst_wns_mod is None:
            worst_wns = wns
            worst_wns_mod = mod

    # 汇总（子模块资源之和 = 顶层资源下界）
    # xcau25p-ffvb676-1-e 容量（2026-10-06 修正：取自本器件 report_utilization 的
    # "Available" 列实测值，非官方规格书数字——实测明显小于规格书）：
    #   CLB LUTs 141,000 / CLB Registers 282,000 / DSP 1,200 /
    #   Block RAM Tile 300（RAMB36E2）/ URAM 0（本器件无 URAM 行）
    #   F7 Muxes 108,480 / F8 Muxes 54,240
    XCAP = {
        "LUT":    141_000,
        "FF":     282_000,
        "DSP":      1_200,
        "BRAM36":     300,
        "URAM":         0,
    }

    # ------------------------------------------------------------------
    # 2026-10-06（Task #63）：顶层 e2e_ckks_mult_ctrl_m4 直接综合实测
    # ------------------------------------------------------------------
    e2e_util = parse_util_rpt(OUT_DIR / f"{E2E_TOP}_util.rpt")
    e2e_timing = parse_timing_rpt(OUT_DIR / f"{E2E_TOP}_timing.rpt")
    e2e_dcp = OUT_DIR / f"{E2E_TOP}.dcp"
    e2e_meas = None
    if e2e_util is not None:
        e2e_meas = {
            "LUT": e2e_util.get("Slice LUTs", (0, 0))[0],
            "FF": e2e_util.get("Slice Registers", (0, 0))[0],
            "LUT_as_Memory": e2e_util.get("LUT as Memory", (0, 0))[0],
            "F7": e2e_util.get("F7 Muxes", (0, 0))[0],
            "DSP": e2e_util.get("DSPs", (0, 0))[0],
            "BRAM36": e2e_util.get("Block RAM Tile 36Kb",
                                    e2e_util.get("Block RAM Tile", (0, 0)))[0],
            "WNS(ns)": (e2e_timing or {}).get("WNS(ns)"),
            "dcp_size_mb": round(e2e_dcp.stat().st_size / 1e6, 2)
                           if e2e_dcp.exists() else None,
        }
        print("\n" + "=" * 60)
        print(f"顶层实测：{E2E_TOP}（含 FSM / 顶层缓冲 / 路由，TDM 后）")
        print("=" * 60)
        print(f"  LUT:      {e2e_meas['LUT']:,}   (LUT as Memory {e2e_meas['LUT_as_Memory']:,})")
        print(f"  FF:       {e2e_meas['FF']:,}")
        print(f"  F7 Mux:   {e2e_meas['F7']:,}")
        print(f"  DSP:      {e2e_meas['DSP']:,}")
        print(f"  BRAM36:   {e2e_meas['BRAM36']:,}")
        print(f"  WNS:      {(e2e_meas['WNS(ns)'] if e2e_meas['WNS(ns)'] is not None else float('nan')):+.3f} ns")
        lut_pct = e2e_meas['LUT'] / XCAP["LUT"] * 100
        print(f"  LUT 利用率: {e2e_meas['LUT']:,} / {XCAP['LUT']:,} = {lut_pct:.1f}%")
        summary["e2e_top_measured"] = e2e_meas

    print("\n" + "=" * 60)
    print(f"生产 E2E 面积估算（子模块实例资源累加）")
    print("=" * 60)
    print(f"  1× approx_poly_mult + 1× keyswitch_pipe + 2× rescale  (TDM 后)")
    print(f"  （顶层实测存在时，以顶层实测为准；本列仅作交叉验证）")
    print(f"")
    print(f"  {'资源':<15} {'估算用量':>12} {'xcau25p 容量':>16} {'利用率':>10}")
    print(f"  {'-'*15} {'-'*12} {'-'*16} {'-'*10}")
    for name, cap in XCAP.items():
        est = {"LUT": total_lut, "FF": total_ff, "DSP": total_dsp,
               "BRAM36": total_bram36, "URAM": total_uram}[name]
        pct = (est / cap * 100) if cap else 0
        print(f"  {name:<15} {est:>12,} {cap:>16,} {pct:>9.1f}%")

    print(f"\n  Worst WNS: {worst_wns:+.3f} ns  (来自 {worst_wns_mod or '无模块综合'})")
    if worst_wns_mod is None:
        print(f"  → 尚未有子模块综合成功，请重新跑综合")
    elif worst_wns > 0:
        print(f"  → 生产时序可行: ✓ (WNS > 0)")
    else:
        print(f"  → 生产时序不满足: ✗ (WNS ≤ 0，需 P&R 收敛或降频)")

    # 落盘 JSON
    summary["total_estimated"] = {
        "LUT": total_lut,
        "FF": total_ff,
        "DSP": total_dsp,
        "BRAM36Kb": total_bram36,
        "URAM": total_uram,
        "worst_WNS_ns": worst_wns,
        "worst_WNS_module": worst_wns_mod,
        "note": "子模块实例资源累加，未含顶层 FSM/缓冲/路由开销（估计 +5-15%）",
    }
    summary_path = OUT_DIR / "aggregate_prod_area.json"
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print(f"\n  摘要: {summary_path}")
    return summary


def main():
    global LOG_N, OUT_DIR, LOG_FILE
    ap = argparse.ArgumentParser()
    ap.add_argument("--aggregate", action="store_true", help="仅解析报告（不跑综合）")
    ap.add_argument("--only", type=str, help="只跑指定子模块：approx_poly_mult/keyswitch_pipe/rescale")
    ap.add_argument("--timeout", type=int, default=14400, help="总超时秒数（默认 4h）")
    ap.add_argument("--log-n", type=int, default=14,
                    help="LOG_N（N=2^LOG_N）。默认 14；降 N 路径用 12（N=4096）")
    args = ap.parse_args()

    LOG_N = args.log_n
    suffix = "" if LOG_N == 14 else f"_n{LOG_N}"
    OUT_DIR = ROOT / f"reports/synth/prod_blocks_au25p{suffix}"
    LOG_FILE = OUT_DIR / "synth_prod_blocks.log"
    print(f"配置：LOG_N={LOG_N} (N={1 << LOG_N})，N_INV={n_inv_for(LOG_N)}，"
          f"输出目录 {OUT_DIR.name}")

    if args.aggregate:
        aggregate()
        return 0

    rc = run_vivado(phase_arg=args.only or "", timeout_s=args.timeout)
    # 综合完后聚合
    aggregate()
    return rc


if __name__ == "__main__":
    sys.exit(main())
