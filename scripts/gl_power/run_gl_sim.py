#!/usr/bin/env python3
"""
run_gl_sim.py -- M4/E30 step 3: compile + elaborate + run gate-level sim with SAIF.

Flow (all via Vivado 2026.1 bin loaders, clean PATH):
  xvlog  out/gl_netlist.v + sim_build/tb_gl_top.sv
  xelab  -L unisims -L secureip work.tb_gl_top -snapshot gl_snap
  xsim   gl_snap -t sim.tcl  (writes out/sim.saif)
"""
import os
import subprocess
import sys
import time

PROJ = str(Path(__file__).resolve().parents[2])
GL = os.path.join(PROJ, "scripts", "gl_power")
SIM = os.path.join(GL, "sim_build")
BIN = os.environ.get("VIVADO_BIN", "vivado")
NET = os.path.join(GL, "out", "gl_netlist.v")
TIMEOUT_S = 1800


def clean_env():
    env = os.environ.copy()
    parts = env.get("PATH", "").split(os.pathsep)
    clean = [p for p in parts if p.strip() and not os.path.isfile(p)]
    env["PATH"] = os.pathsep.join(clean)
    return env


def run(cmd, log, cwd, timeout):
    t0 = time.time()
    print(f"[sim] {' '.join(cmd)}", flush=True)
    with open(log, "wb") as lf:
        proc = subprocess.Popen(cmd, cwd=cwd, env=clean_env(),
                                stdout=lf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            print(f"[sim] TIMEOUT after {timeout} s: {' '.join(cmd)}", flush=True)
            return -1
    dt = time.time() - t0
    print(f"[sim] rc={rc} in {dt:.1f} s -> {log}", flush=True)
    return rc


def main() -> int:
    os.makedirs(SIM, exist_ok=True)

    # xvlog: netlist (Verilog) + TB (SystemVerilog)
    rc = run([os.path.join(BIN, "xvlog.bat"), "-work", "work", NET],
             os.path.join(SIM, "xvlog_net.log"), SIM, 900)
    if rc != 0:
        return 1
    rc = run([os.path.join(BIN, "xvlog.bat"), "-work", "work", "-sv",
              os.path.join(SIM, "tb_gl_top.sv")],
             os.path.join(SIM, "xvlog_tb.log"), SIM, 900)
    if rc != 0:
        return 1

    # xvlog: glbl (UNISIM GSR binding) into work library
    rc = run([os.path.join(BIN, "xvlog.bat"), "-work", "work",
              os.path.join(os.environ.get("VIVADO_LIB", ""), "glbl.v")],
             os.path.join(SIM, "xvlog_glbl.log"), SIM, 600)

    # xelab: tb + glbl as second root so UNISIM 'glbl.GSR' resolves
    rc = run([os.path.join(BIN, "xelab.bat"), "-L", "unisims_ver", "-L", "secureip",
              "-debug", "off", "work.tb_gl_top", "work.glbl", "-snapshot", "gl_snap"],
             os.path.join(SIM, "xelab.log"), SIM, 1500)
    if rc != 0:
        return 1

    # xsim with SAIF capture
    rc = run([os.path.join(BIN, "xsim.bat"), "gl_snap", "-t", "sim.tcl"],
             os.path.join(SIM, "xsim.log"), SIM, TIMEOUT_S)
    saif = os.path.join(GL, "out", "sim.saif")
    if rc == 0 and os.path.isfile(saif) and os.path.getsize(saif) > 10000:
        print(f"[sim] OK saif={os.path.getsize(saif):,} B -> {saif}", flush=True)
        return 0
    print(f"[sim] FAILED rc={rc} saif_exists={os.path.isfile(saif)}", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
