#!/usr/bin/env python3
"""
run_gl_power.py -- M4/E30 SAIF gate-level power driver (step 1: netlist export)

Launches Vivado 2026.1 batch to export a funcsim gate-level netlist from the
OOC synthesis checkpoint, so a downstream gate-level simulation can generate
a SAIF annotation file for report_power.

Unlike a raw shell background launch, this uses subprocess with a clean PATH
(same pattern as scripts/run_sim_vivado.py), which survives the broken bash
shim in this sandbox.
"""
import os
import subprocess
import sys
import time

PROJ = str(Path(__file__).resolve().parents[2])
GL = os.path.join(PROJ, "scripts", "gl_power")
VIVADO = os.environ.get("VIVADO_BAT", "vivado")
TCL = "gl_netlist.tcl"
TIMEOUT_S = 1500  # 25 min hard cap


def main() -> int:
    os.chdir(GL)
    log_path = os.path.join(GL, "netlist_export.log")
    env = os.environ.copy()
    # Drop PATH entries that point at a file (powershell.exe) -- same trick
    # used for MiKTeX; keeps Vivado from choking on bogus dirs.
    parts = env.get("PATH", "").split(os.pathsep)
    clean = [p for p in parts if p.strip() and not os.path.isfile(p)]
    env["PATH"] = os.pathsep.join(clean)

    t0 = time.time()
    print(f"[gl] launching vivado batch, cwd={GL}", flush=True)
    with open(log_path, "wb") as lf:
        proc = subprocess.Popen(
            [VIVADO, "-mode", "batch", "-source", TCL],
            cwd=GL,
            env=env,
            stdout=lf,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
        )
        try:
            rc = proc.wait(timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            proc.kill()
            print("[gl] TIMEOUT: vivado killed after %d s" % TIMEOUT_S, flush=True)
            return 2
    dt = time.time() - t0
    print(f"[gl] vivado exited rc={rc} in {dt:.1f} s", flush=True)

    out = os.path.join(GL, "out")
    netlist = os.path.join(out, "gl_netlist.v")
    ports = os.path.join(out, "gl_ports.txt")
    ok_net = os.path.isfile(netlist) and os.path.getsize(netlist) > 1000
    ok_ports = os.path.isfile(ports) and os.path.getsize(ports) > 100
    if rc == 0 and ok_net and ok_ports:
        print(f"[gl] OK  netlist={os.path.getsize(netlist):,} B "
              f"ports={os.path.getsize(ports):,} B", flush=True)
        return 0
    print("[gl] FAILED: rc=%s netlist_ok=%s ports_ok=%s" % (rc, ok_net, ok_ports),
          flush=True)
    # dump log tail for diagnosis
    with open(log_path, "rb") as f:
        tail = f.read()[-3000:].decode("utf-8", errors="replace")
    print("---- log tail ----")
    print(tail)
    return 1


if __name__ == "__main__":
    sys.exit(main())
