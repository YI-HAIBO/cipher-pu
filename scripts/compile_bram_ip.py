"""compile_bram_ip.py — 用 xvlog 编译生成的 IP HDL 验证语法"""
import os
import subprocess
from pathlib import Path

VIVADO_BIN = os.environ.get("VIVADO_BIN", "vivado")
PROJECT_ROOT = Path(__file__).resolve().parent.parent
IP_SIM_V = PROJECT_ROOT / "ip_repo/ntt_mem_bram/ntt_mem_bram/sim/ntt_mem_bram.v"
IP_BODY_V = PROJECT_ROOT / "ip_repo/ntt_mem_bram/ntt_mem_bram/simulation/blk_mem_gen_v8_4.v"
PROD_SV = PROJECT_ROOT / "rtl/m1/ntt_mem_tdp_prod.sv"
TDP_SV = PROJECT_ROOT / "rtl/m1/ntt_mem_tdp.sv"

WORK_DIR = PROJECT_ROOT / "sim/bram_ip_check"
WORK_DIR.mkdir(parents=True, exist_ok=True)

# 用 run_sim 里已有的 .bat 包装逻辑
import sys
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
from vivado_cmd import run_cmd

cmd_str = (
    f'"{VIVADO_BIN}\\xvlog.bat" -sv '
    f'-L xil_defaultlib '
    f'-log {WORK_DIR / "xvlog_bram_ip.log"} '
    f'"{IP_BODY_V.as_posix()}" '
    f'"{IP_SIM_V.as_posix()}"'
)

print(f"CMD: {cmd_str}")
rc, stdout, stderr = run_cmd(cmd_str, cwd=str(WORK_DIR), timeout=180)
print("RC:", rc)
print("---- STDOUT (last 3000) ----")
print((stdout or "")[-3000:])
if stderr:
    print("---- STDERR ----")
    print(stderr[-1000:])

# 检查生成结果
print()
print("---- Work directory contents ----")
for p in sorted(WORK_DIR.iterdir()):
    print(f"  {p.name}  ({p.stat().st_size:,} bytes)" if p.is_file() else f"  {p.name}/")
