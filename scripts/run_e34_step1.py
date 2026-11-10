#!/usr/bin/env python3
"""E34 step 1 driver: launch Vivado batch for routed-DCP power."""
import os, subprocess, sys, time

PROJ = str(Path(__file__).resolve().parents[1])
SC = os.path.join(PROJ, "scripts")
VIVADO = os.environ.get("VIVADO_BAT", "vivado")
TCL = "e34_routed_power.tcl"
OUT = os.path.join(PROJ, "reports", "experiments", "e34_routed_power")
os.makedirs(OUT, exist_ok=True)
LOG = os.path.join(OUT, "e34_step1.log")

env = os.environ.copy()
parts = env.get("PATH", "").split(os.pathsep)
env["PATH"] = os.pathsep.join(p for p in parts if p.strip() and not os.path.isfile(p))

t0 = time.time()
print(f"[e34] launching vivado batch, cwd={SC}", flush=True)
with open(LOG, "wb") as lf:
    proc = subprocess.Popen([VIVADO, "-mode", "batch", "-source", TCL],
                            cwd=SC, env=env, stdout=lf, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL)
    try:
        rc = proc.wait(timeout=1800)
    except subprocess.TimeoutExpired:
        proc.kill()
        print("[e34] TIMEOUT", flush=True)
        sys.exit(2)
print(f"[e34] rc={rc} in {time.time()-t0:.1f}s  log={LOG}", flush=True)
sys.exit(0 if rc == 0 else 1)
