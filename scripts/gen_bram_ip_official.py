#!/usr/bin/env python3
"""
gen_bram_ip_official.py — 通过 Vivado batch 模式生成官方 blk_mem_gen IP

功能：调用 scripts/gen_bram_ip_official.tcl，生成 NTT 系数存储器 IP
      （16384 x 45, TDP 同步读, ~20 x RAMB36E1）

用法：
    python scripts/gen_bram_ip_official.py
    python scripts/gen_bram_ip_official.py --keep-log

说明：
    - 使用 .bat 包装方式调用 vivado.bat，规避 Bash shim / DLL 缺失
    - Vivado batch 模式启动约需 30-60 秒，IP 生成约需 1-2 分钟
    - 输出：ip_repo/ntt_mem_bram/blk_mem_gen.xci + hdl/
"""

import os
import sys
import time
import glob
from pathlib import Path

# 项目根目录（脚本位于 scripts/ 下）
PROJECT_ROOT = Path(__file__).resolve().parent.parent

# 导入已有的 Vivado 命令调用层
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
from vivado_cmd import run_cmd  # noqa: E402

VIVADO_BIN = os.environ.get("VIVADO_BIN", "vivado")
VIVADO_BAT = os.path.join(VIVADO_BIN, "vivado.bat")

TCL_SCRIPT = PROJECT_ROOT / "scripts" / "gen_bram_ip_official.tcl"
OUT_DIR = PROJECT_ROOT / "ip_repo" / "ntt_mem_bram"
LOG_DIR = PROJECT_ROOT / "reports" / "synth" / "bram_ip_gen"


def ensure_dirs():
    """确保必要目录存在。"""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)


def generate_ip(keep_log: bool = True) -> int:
    """
    执行 IP 生成流程。
    返回 exit_code。
    """
    print("=" * 70)
    print("Step: Generate Official blk_mem_gen IP")
    print("=" * 70)
    print(f"Vivado   : {VIVADO_BAT}")
    print(f"TCL      : {TCL_SCRIPT}")
    print(f"Output   : {OUT_DIR}")
    print(f"Log Dir  : {LOG_DIR}")
    print()

    if not os.path.isfile(VIVADO_BAT):
        print(f"ERROR: Vivado not found at {VIVADO_BAT}")
        return 2
    if not TCL_SCRIPT.is_file():
        print(f"ERROR: TCL script not found at {TCL_SCRIPT}")
        return 2

    tcl_abs = str(TCL_SCRIPT).replace("\\", "/")
    log_prefix = str(LOG_DIR / "gen_bram_ip_official").replace("\\", "/")

    # 通过 .bat 包装运行 Vivado batch 模式
    cmd_str = (
        f'"{VIVADO_BAT}" '
        f"-mode batch "
        f"-source {tcl_abs} "
        f'-log "{log_prefix}.log"'
    )

    t0 = time.time()
    rc, stdout, stderr = run_cmd(cmd_str, cwd=str(PROJECT_ROOT), timeout=900)
    elapsed = time.time() - t0

    print(f"\nElapsed: {elapsed:.1f} s")
    print(f"Exit code: {rc}")
    print()

    # 打印日志尾部（最后 3000 字符）
    if stdout:
        print("---- STDOUT (last 3000 chars) ----")
        print(stdout[-3000:])
    if stderr:
        print("---- STDERR (last 1000 chars) ----")
        print(stderr[-1000:])

    # 检查生成结果
    print()
    print("=" * 70)
    print("Post-check")
    print("=" * 70)

    xci_files = glob.glob(str(OUT_DIR / "**" / "*.xci"), recursive=True)
    hdl_files = glob.glob(str(OUT_DIR / "**" / "*.v"), recursive=True)

    print(f"XCI files found ({len(xci_files)}):")
    for p in xci_files:
        print(f"  {p}")
    print(f"HDL .v files found ({len(hdl_files)}):")
    for p in hdl_files:
        print(f"  {p}")

    if not xci_files:
        print("\n[FAIL] No .xci file generated. Check log for errors.")
        if log_prefix + ".log" and os.path.isfile(log_prefix + ".log"):
            log_path = Path(log_prefix + ".log")
            print(f"\nFull log: {log_path}")
        return 1

    if rc != 0:
        print(f"\n[FAIL] Vivado exit code = {rc}")
        return rc

    print("\n[PASS] IP generated successfully.")
    return 0


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Generate official blk_mem_gen IP")
    parser.add_argument("--keep-log", action="store_true", default=True,
                        help="Keep log files (default: keep)")
    args = parser.parse_args()

    ensure_dirs()
    rc = generate_ip(keep_log=args.keep_log)
    sys.exit(rc)


if __name__ == "__main__":
    main()
