#!/usr/bin/env python3
"""
run_iverilog_gl.py -- M4/E30: Icarus Verilog gate-level sim (xsim BASIC license
caps instances at 50k; the N=2^12 DUT elaborates to 211k, so we use iverilog
with Vivado's unisims Verilog sources).

Flow:
  iverilog -g2012 -o gl_tb.vvp <netlist> <tb> <11 unisim .v> <glbl.v>
  vvp gl_tb.vvp           (writes sim_build/gl.vcd via $dumpvars(0, u_dut))
"""
import os
import subprocess
import sys
import time

PROJ = str(Path(__file__).resolve().parents[2])
GL = os.path.join(PROJ, "scripts", "gl_power")
SIM = os.path.join(GL, "sim_build")
IV = r"C:\iverilog\bin"
UNIS = os.path.join(os.environ.get("VIVADO_LIB", ""), "unisims")
GLBL = os.path.join(os.environ.get("VIVADO_LIB", ""), "glbl.v")

NEEDED = ["CARRY8", "DSP48E2", "FDCE", "FDRE", "FDSE", "GND", "MUXF7", "MUXF8",
          "LUT1", "LUT2", "LUT3", "LUT4", "LUT5", "LUT6"]


def strip_protected(src: str, dst: str) -> bool:
    """write_verilog -mode funcsim appends an encrypted `pragma protect` block
    that iverilog cannot parse. It is not referenced by any plain module, so
    drop it (keep the trailing embedded glbl)."""
    with open(src, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    begin = end = None
    for i, l in enumerate(lines):
        if l.startswith("`pragma protect begin_protected") and begin is None:
            begin = i
        if l.startswith("`pragma protect end_protected"):
            end = i
    if begin is None or end is None:
        with open(dst, "w", encoding="utf-8") as f:
            f.writelines(lines)
        return True
    out = lines[:begin] + lines[end + 1:]
    with open(dst, "w", encoding="utf-8") as f:
        f.writelines(out)
    print(f"[iv] stripped protected region lines {begin + 1}-{end + 1} "
          f"({end - begin + 1} lines) -> {dst}", flush=True)
    return True


def clean_env():
    env = os.environ.copy()
    parts = env.get("PATH", "").split(os.pathsep)
    clean = [p for p in parts if p.strip() and not os.path.isfile(p)]
    # keep iverilog on PATH (vvp may need its dll dir)
    env["PATH"] = os.pathsep.join([IV] + clean)
    return env


def run(cmd, log, cwd, timeout):
    t0 = time.time()
    print(f"[iv] {' '.join(str(c) for c in cmd[:6])} ...", flush=True)
    with open(log, "wb") as lf:
        proc = subprocess.Popen(cmd, cwd=cwd, env=clean_env(),
                                stdout=lf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            print(f"[iv] TIMEOUT after {timeout} s", flush=True)
            return -1
    dt = time.time() - t0
    print(f"[iv] rc={rc} in {dt:.1f} s -> {log}", flush=True)
    return rc


def main() -> int:
    net_src = os.path.join(GL, "out", "gl_netlist.v")
    net = os.path.join(SIM, "gl_netlist_stripped.v")
    strip_protected(net_src, net)
    tb = os.path.join(SIM, "tb_gl_top.sv")
    stubs = os.path.join(SIM, "bram_stubs.v")
    # glbl is embedded at the end of the stripped netlist
    files = [net, tb, stubs] + [os.path.join(UNIS, f"{m}.v") for m in NEEDED]
    vvp = os.path.join(SIM, "gl_tb.vvp")

    rc = run([os.path.join(IV, "iverilog.exe"), "-g2012", "-o", vvp] + files,
             os.path.join(SIM, "iverilog.log"), SIM, 1800)
    if rc != 0:
        return 1

    rc = run([os.path.join(IV, "vvp.exe"), vvp],
             os.path.join(SIM, "vvp.log"), SIM, 3600)
    vcd = os.path.join(SIM, "gl.vcd")
    if rc == 0 and os.path.isfile(vcd) and os.path.getsize(vcd) > 1_000_000:
        print(f"[iv] OK vcd={os.path.getsize(vcd):,} B", flush=True)
        return 0
    print(f"[iv] FAILED rc={rc} vcd={os.path.isfile(vcd)}", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
