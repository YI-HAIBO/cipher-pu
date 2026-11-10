"""compile_bram_ip_prod.py — 编译 ntt_mem_tdp_prod.sv + 生成的 IP HDL 验证接口匹配"""
import os
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
VIVADO_BIN = os.environ.get("VIVADO_BIN", "vivado")
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
from vivado_cmd import run_cmd

IP_BODY_V = PROJECT_ROOT / "ip_repo/ntt_mem_bram/ntt_mem_bram/simulation/blk_mem_gen_v8_4.v"
IP_SIM_V = PROJECT_ROOT / "ip_repo/ntt_mem_bram/ntt_mem_bram/sim/ntt_mem_bram.v"
PROD_SV = PROJECT_ROOT / "rtl/m1/ntt_mem_tdp_prod.sv"
TDP_SV = PROJECT_ROOT / "rtl/m1/ntt_mem_tdp.sv"

WORK_DIR = PROJECT_ROOT / "sim/bram_ip_prod_check"
WORK_DIR.mkdir(parents=True, exist_ok=True)

cmd_str = (
    f'"{VIVADO_BIN}\\xvlog.bat" -sv '
    f'-L xil_defaultlib '
    f'-log {WORK_DIR / "xvlog.log"} '
    f'"{IP_BODY_V.as_posix()}" '
    f'"{IP_SIM_V.as_posix()}" '
    f'"{TDP_SV.as_posix()}" '
    f'"{PROD_SV.as_posix()}"'
)

print(f"CMD: {cmd_str}")
rc, stdout, stderr = run_cmd(cmd_str, cwd=str(WORK_DIR), timeout=180)
print("RC:", rc)
print("---- STDOUT (last 3000) ----")
print((stdout or "")[-3000:])
if stderr:
    print("---- STDERR ----")
    print(stderr[-1000:])
