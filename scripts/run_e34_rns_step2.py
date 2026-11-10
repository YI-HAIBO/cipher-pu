#!/usr/bin/env python3
"""方案B A-1: full SAIF gate-level power flow on xcku5p RNS ROUTED DCP.

Stages (all subprocess, clean PATH, logs to reports/experiments/e34_rns_power/):
  2a. vivado batch: open RNS routed DCP -> funcsim netlist + dcp_names.txt [TCL]
  2b. iverilog: compile routed netlist + glbl.v + unisims prims + RNS TB
  2c. vvp: gate-level sim -> gl_rns.vcd
  2d. vcd_to_saif.py: VCD -> routed.saif (DESIGN=e2e_rns_top, strip tb+u_dut)
  2e. vivado batch: read_saif + report_power on RNS routed DCP             [TCL]

Usage: python run_e34_rns_step2.py [--skip-to <stage>]
"""
import argparse
import os
import subprocess
import sys
import time

PROJ = str(Path(__file__).resolve().parents[1])
GL = os.path.join(PROJ, "scripts", "gl_power")
OUTR = os.path.join(GL, "out_rns")
SIM = os.path.join(GL, "sim_build")
EXP = os.path.join(PROJ, "reports", "experiments", "e34_rns_power")
VIVADO = os.environ.get("VIVADO_BAT", "vivado")
IV = r"C:\iverilog\bin"
UNIS = os.path.join(os.environ.get("VIVADO_LIB", ""), "unisims")
GLBL = os.path.join(os.environ.get("VIVADO_LIB", ""), "glbl.v")

os.makedirs(EXP, exist_ok=True)


def clean_env(extra_path=None):
    env = os.environ.copy()
    parts = env.get("PATH", "").split(os.pathsep)
    clean = [p for p in parts if p.strip() and not os.path.isfile(p)]
    if extra_path:
        clean = [extra_path] + clean
    env["PATH"] = os.pathsep.join(clean)
    return env


def run(cmd, logname, cwd, timeout, env=None):
    log = os.path.join(EXP, logname)
    t0 = time.time()
    print(f"[rns-2] {logname}: {' '.join(str(c) for c in cmd[:5])} ...", flush=True)
    with open(log, "wb") as lf:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env or clean_env(),
                                stdout=lf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            print(f"[rns-2] TIMEOUT after {timeout}s in {logname}", flush=True)
            return -1
    print(f"[rns-2] {logname}: rc={rc} in {time.time()-t0:.1f}s", flush=True)
    return rc


def stage_2a():
    rc = run([VIVADO, "-mode", "batch", "-source",
              os.path.join(PROJ, "scripts", "e34_rns_netlist.tcl")],
             "e34_rns_step2a.log", GL, 2400)
    ok = (rc == 0 and os.path.isfile(os.path.join(OUTR, "gl_netlist.v"))
          and os.path.isfile(os.path.join(OUTR, "dcp_names.txt")))
    return ok


def strip_protected(src, dst):
    with open(src, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    begin = end = None
    for i, l in enumerate(lines):
        if l.startswith("`pragma protect begin_protected") and begin is None:
            begin = i
        if l.startswith("`pragma protect end_protected"):
            end = i
    if begin is None or end is None:
        out = lines
    else:
        out = lines[:begin] + lines[end + 1:]
        print(f"[rns-2] stripped protected region lines {begin+1}-{end+1}", flush=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.writelines(out)
    return True


def stage_2b():
    net = os.path.join(SIM, "gl_netlist_rns_stripped.v")
    strip_protected(os.path.join(OUTR, "gl_netlist.v"), net)
    tb = os.path.join(SIM, "tb_rns_gl_top.sv")
    # RNS netlist primitives (bare Xilinx): must compile with glbl.GSR bound.
    prims = ["CARRY8", "DSP48E2", "FDCE", "FDRE", "FDSE", "GND", "MUXF7", "MUXF8",
             "LUT1", "LUT2", "LUT3", "LUT4", "LUT5", "LUT6",
             "RAMB36E2", "RAMB18E2", "URAM288", "VCC"]
    files = [net, tb, GLBL] + [os.path.join(UNIS, f"{m}.v") for m in prims]
    vvp = os.path.join(SIM, "gl_tb_rns.vvp")
    rc = run([os.path.join(IV, "iverilog.exe"), "-g2012", "-o", vvp] + files,
             "e34_rns_step2b.log", SIM, 3600, env=clean_env(IV))
    return rc == 0 and os.path.isfile(vvp)


def stage_2c():
    vvp = os.path.join(SIM, "gl_tb_rns.vvp")
    rc = run([os.path.join(IV, "vvp.exe"), vvp], "e34_rns_step2c.log", SIM, 10800,
             env=clean_env(IV))
    vcd = os.path.join(SIM, "gl_rns.vcd")
    # TB hard-codes $dumpfile to gl_rns.vcd; vvp writes it in cwd (SIM).
    produced = os.path.join(SIM, "gl_rns.vcd")
    if os.path.isfile(produced) and not os.path.isfile(vcd):
        os.replace(produced, vcd)
    ok = rc == 0 and os.path.isfile(vcd) and os.path.getsize(vcd) > 1_000_000
    if ok:
        print(f"[rns-2] VCD {os.path.getsize(vcd)/1e9:.2f} GB", flush=True)
    return ok


def stage_2d():
    vcd = os.path.join(SIM, "gl_rns.vcd")
    saif = os.path.join(OUTR, "routed.saif")
    names = os.path.join(OUTR, "dcp_names.txt")
    rc = run([sys.executable, os.path.join(GL, "vcd_to_saif.py"), vcd, saif,
              "--design", "e2e_rns_top",
              "--strip", "tb_rns_gl_top", "u_dut",
              "--dcp-names", names],
             "e34_rns_step2d.log", GL, 5400)
    return rc == 0 and os.path.isfile(saif) and os.path.getsize(saif) > 10000


def stage_2e():
    tcl = os.path.join(PROJ, "scripts", "e34_rns_saif_power.tcl")
    rc = run([VIVADO, "-mode", "batch", "-source", tcl],
             "e34_rns_step2e.log", GL, 2400)
    rpt = os.path.join(EXP, "e34_rns_saif.rpt")
    return rc == 0 and os.path.isfile(rpt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-to", default="2a", choices=["2a", "2b", "2c", "2d", "2e"])
    a = ap.parse_args()
    stages = [("2a", stage_2a), ("2b", stage_2b), ("2c", stage_2c),
              ("2d", stage_2d), ("2e", stage_2e)]
    order = [s for s in stages if s[0] >= a.skip_to]
    t0 = time.time()
    for name, fn in order:
        print(f"\n===== 方案B RNS stage {name} =====", flush=True)
        ok = fn()
        if not ok:
            print(f"[rns-2] stage {name} FAILED -- aborting", flush=True)
            sys.exit(1)
    print(f"\n[rns-2] ALL STAGES OK in {(time.time()-t0)/60:.1f} min", flush=True)


if __name__ == "__main__":
    main()
