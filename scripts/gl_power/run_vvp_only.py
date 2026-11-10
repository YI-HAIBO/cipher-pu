#!/usr/bin/env python3
"""
run_vvp_only.py -- M4/E30: run the compiled gate-level vvp only (compile already done).
Produces sim_build/gl.vcd via $dumpvars(0, u_dut).
"""
import os
import subprocess
import sys
import time

PROJ = str(Path(__file__).resolve().parents[2])
SIM = os.path.join(PROJ, "scripts", "gl_power", "sim_build")
IV = r"C:\iverilog\bin"
VVP = os.path.join(SIM, "gl_tb.vvp")


def clean_env():
    env = os.environ.copy()
    parts = env.get("PATH", "").split(os.pathsep)
    clean = [p for p in parts if p.strip() and not os.path.isfile(p)]
    env["PATH"] = os.pathsep.join([IV] + clean)
    return env


def main() -> int:
    if not os.path.isfile(VVP):
        print(f"[vvp] missing {VVP}")
        return 1
    log = os.path.join(SIM, "vvp.log")
    vcd = os.path.join(SIM, "gl.vcd")
    if os.path.isfile(vcd):
        os.remove(vcd)
    t0 = time.time()
    print(f"[vvp] start {VVP}", flush=True)
    with open(log, "wb") as lf:
        proc = subprocess.Popen([os.path.join(IV, "vvp.exe"), VVP],
                                cwd=SIM, env=clean_env(),
                                stdout=lf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)
        rc = proc.wait(timeout=14400)
    dt = time.time() - t0
    size = os.path.getsize(vcd) if os.path.isfile(vcd) else 0
    print(f"[vvp] rc={rc} in {dt:.1f} s, vcd={size:,} B", flush=True)
    with open(log, "rb") as f:
        tail = f.read()[-3000:].decode("utf-8", errors="replace")
    print("---- vvp.log tail ----")
    print(tail)
    return 0 if (rc == 0 and size > 1_000_000) else 1


if __name__ == "__main__":
    sys.exit(main())
