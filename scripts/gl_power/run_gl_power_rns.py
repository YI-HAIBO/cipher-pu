# -*- coding: utf-8 -*-
"""run_gl_power_rns.py — 方案B RNS SAIF 功耗报告（step2d）

调用 gl_power.tcl（open_checkpoint 路由 RNS DCP + read_saif + report_power）。

用法:
    python scripts/gl_power/run_gl_power_rns.py
"""
import os
import subprocess
import sys
import time

PROJ = str(Path(__file__).resolve().parents[2])
GL = os.path.join(PROJ, "scripts", "gl_power")
VIVADO = os.environ.get("VIVADO_BAT", "vivado")
TCL = os.path.join(GL, "gl_power.tcl")
DCP = os.path.join(PROJ, "reports", "impl", "rns_n12_ku5p", "e2e_impl_routed.dcp")
SAIF = os.path.join(GL, "out_rns", "gl_power.saif")
RPT = os.path.join(PROJ, "reports", "experiments", "e34_rns_power", "e34_rns_power_rpt")
LOG = os.path.join(PROJ, "reports", "experiments", "e34_rns_power", "e34_rns_step2d.log")
TIMEOUT_S = 1800  # 30 min


def main() -> int:
    for p in (DCP, SAIF):
        if not os.path.isfile(p):
            print("MISSING input:", p)
            return 1
    env = os.environ.copy()
    parts = env.get("PATH", "").split(os.pathsep)
    clean = [p for p in parts if p.strip() and not os.path.isfile(p)]
    env["PATH"] = os.pathsep.join(clean)

    cmd = [VIVADO, "-mode", "batch", "-source", TCL,
           "-tclargs", DCP, SAIF, RPT]
    print("[rns] vivado batch:", " ".join(str(c) for c in cmd), flush=True)
    t0 = time.time()
    with open(LOG, "wb") as lf:
        proc = subprocess.Popen(cmd, cwd=GL, env=env,
                                stdout=lf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)
        try:
            rc = proc.wait(timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            proc.kill()
            print("[rns] TIMEOUT after %d s" % TIMEOUT_S, flush=True)
            return 2
    dt = time.time() - t0
    print("[rns] vivado rc=%d in %.1f s" % (rc, dt), flush=True)

    rpt = RPT
    ok = rc == 0 and os.path.isfile(rpt) and os.path.getsize(rpt) > 1000
    if ok:
        txt = open(rpt, "r", encoding="utf-8", errors="replace").read()
        for l in txt.split("\n"):
            ls = l.strip()
            if ("Total On-Chip Power" in ls or "Dynamic (W)" in ls
                    or "Device Static (W)" in ls or "GL_POWER_OK" in ls):
                print("   ", ls[:100])
        print("[rns] OK report:", rpt)
        return 0
    print("[rns] FAILED rc=%s rpt_exists=%s" % (rc, os.path.isfile(rpt)))
    # dump log tail
    if os.path.exists(LOG):
        tail = open(LOG, "r", encoding="utf-8", errors="replace").read()[-2000:]
        print("---- log tail ----")
        print(tail)
    return 1


if __name__ == "__main__":
    sys.exit(main())
