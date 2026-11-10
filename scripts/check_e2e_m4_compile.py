#!/usr/bin/env python3
"""
e2e_ckks_mult_ctrl_m4 wrapper 编译检查（M4-h 集成后回归）
=========================================================

目的：
  验证 M4-h 在 wrapper 中新增 mode_sel / energy_q2_ext / flush_valid_ext /
  hysteresis_en / manual_gear / manual_en 6 个端口和 5 个参数后，
  wrapper + 现有 TB 仍能通过 xvlog + xelab，保证对既有 8 档 E2E 测试
  无接口级回归。

流程（cmd.exe /c + .bat 包装器，绕过 Bash shim 限制）：
  1. xvlog 编译 DUT + TB
  2. xelab elaboration
  3. 不跑 xsim（耗时且已有 8 PASS 记录），仅检查 elaboration 成功。
"""
import os
import sys
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIM_DIR = ROOT / "sim" / "tb_e2e_ckks_mult_ctrl_m4_smoke2"
VIVADO = Path(os.environ.get("VIVADO_BIN", "vivado"))
XVLOG = VIVADO / "xvlog.bat"
XELAB = VIVADO / "xelab.bat"

# 全量 RTL 依赖（与既有 tb_e2e_ckks_mult_ctrl_m4 一致，含 M4-h 新增模块）
RTL_FILES = [
    ROOT / "rtl" / "m1" / "mult_43x43_horner4.sv",
    ROOT / "rtl" / "m2" / "mod45_fastred.sv",
    ROOT / "rtl" / "m1" / "ntt_butterfly.sv",
    ROOT / "rtl" / "m1" / "ntt_mem_tdp_prod.sv",
ROOT / "rtl" / "m1" / "ntt_unit.sv",
    ROOT / "rtl" / "m1" / "ckks_bram.sv",
    ROOT / "rtl" / "m2" / "poly_mult.sv",
    ROOT / "rtl" / "m3" / "keyswitch_pipe.sv",
    ROOT / "rtl" / "m3" / "rescale.sv",
    ROOT / "rtl" / "m4" / "approx_poly_mult.sv",
    ROOT / "rtl" / "m4" / "gear_controller.sv",
    ROOT / "rtl" / "m4" / "noise_monitor.sv",
    ROOT / "rtl" / "m4" / "adaptive_gear_ctrl.sv",
    ROOT / "rtl" / "m4" / "e2e_ckks_mult_ctrl_m4.sv",
    ROOT / "tb" / "tb_e2e_ckks_mult_ctrl_m4.sv",
]

def _run_cmd(cwd, exe, args):
    """用 cmd.exe /c 调 .bat 包装器，捕获 stdout+stderr 和退出码。"""
    exe_s = str(exe).replace(" ", '" "')
    args_s = " ".join(str(a).replace(" ", '" "') for a in args)
    bat = cwd / "_tmp_run.bat"
    cmd = f"@echo off\n{exe_s} {args_s}\nexit %%ERRORLEVEL%%"
    bat.write_text(cmd, encoding="cp936")
    r = subprocess.run(
        ["cmd.exe", "/c", str(bat)],
        cwd=str(cwd),
        capture_output=True,
        text=True,
    )
    return r.returncode, (r.stdout or "") + (r.stderr or "")

def main():
    print("=" * 60)
    print("e2e_ckks_mult_ctrl_m4 wrapper 编译冒烟测试")
    print("=" * 60)
    SIM_DIR.mkdir(parents=True, exist_ok=True)

    # ---- Step 1: xvlog ----
    print("\nStep 1: xvlog 编译全部 RTL + TB")
    args = ["-sv", "-L", "xil_defaultlib", "-log", "xvlog.log"]
    for f in RTL_FILES:
        if not f.exists():
            print(f"  WARN: missing {f}")
        else:
            args.append(str(f))
    rc, out = _run_cmd(SIM_DIR, XVLOG, args)
    print(out[-2500:] if len(out) > 2500 else out)
    if rc != 0:
        print(f"FAIL: xvlog rc={rc}")
        return 1
    # 检查关键 error
    if "[VRFC" in out and "ERROR" in out:
        print("FAIL: xvlog error found in output")
        return 1
    print("PASS: xvlog OK")

    # ---- Step 2: xelab ----
    print("\nStep 2: xelab elaboration")
    tb = "tb_e2e_ckks_mult_ctrl_m4"
    snap = tb + "_smoke2_behav"
    args = [tb, "-s", snap, "-L", "xil_defaultlib", "-log", "xelab.log"]
    rc, out = _run_cmd(SIM_DIR, XELAB, args)
    print(out[-2500:] if len(out) > 2500 else out)
    if rc != 0:
        print(f"FAIL: xelab rc={rc}")
        return 1
    if "Built simulation snapshot" in out:
        print("PASS: xelab OK — snapshot built")
        return 0
    print("FAIL: snapshot not built")
    return 1

if __name__ == "__main__":
    sys.exit(main())
