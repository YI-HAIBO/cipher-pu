#!/usr/bin/env python3
"""E35 driver: run the three ablation variants + two control modules sequentially."""
import os, subprocess, sys, time

PROJ = str(Path(__file__).resolve().parents[1])
SC = os.path.join(PROJ, "scripts")
VIVADO = os.environ.get("VIVADO_BAT", "vivado")
OUT = os.path.join(PROJ, "reports", "experiments", "e35_ablation")
os.makedirs(OUT, exist_ok=True)

VARIANTS = ["abl0_block_sparse", "abl1_element_sparse", "abl2_naive",
            "ctrl_adaptive_gear"]  # ctrl_noise_monitor already completed 2026-10-24 17:08

# skip variants whose util report already exists (resume support)
VARIANTS = [v for v in VARIANTS
            if not os.path.exists(os.path.join(OUT, "%s_util.rpt" % v))]
print("[e35] variants to run: %s" % VARIANTS, flush=True)

env = os.environ.copy()
parts = env.get("PATH", "").split(os.pathsep)
env["PATH"] = os.pathsep.join(p for p in parts if p.strip() and not os.path.isfile(p))

def _own_vivado_pids():
    """Return vivado.exe PIDs that are descendants of THIS script process.

    Scoping is mandatory: a bare 'tasklist | taskkill' sweep would kill every
    vivado.exe on the machine, including concurrent runs of OTHER projects
    (e.g. the ML-KEM board_top route), which is why our route kept dying
    mid-run.  We only clean up our OWN spawns, never another project's.
    """
    try:
        out = subprocess.run(
            ['powershell', '-NoProfile', '-Command',
             "Get-CimInstance Win32_Process | "
             "Select-Object ProcessId,ParentProcessId,Name | "
             "ConvertTo-Csv -NoTypeInformation"],
            capture_output=True, env=env)
        txt = out.stdout.decode('utf-8', errors='replace')
        pp, names = {}, {}
        for ln in txt.splitlines():
            if ln.startswith('"') and ln.count('"') >= 6:
                # CSV: "Name","ParentProcessId","ProcessId"
                import csv, io as _io
                try:
                    row = next(csv.reader(_io.StringIO(ln)))
                    if len(row) >= 3:
                        names[int(row[2])] = row[0].strip()
                        pp[int(row[2])] = int(row[1])
                except Exception:
                    pass
    except Exception:
        return []
    me = os.getpid()
    own = []
    for pid in names:
        cur, hop = pid, 0
        while cur in pp and hop < 25:
            if pp[cur] == me:
                if names.get(pid, '').lower() == 'vivado.exe':
                    own.append(pid)
                break
            cur = pp[cur]
            hop += 1
    return own


def kill_stray_vivado():
    """Kill any orphaned vivado.exe left by a crashed batch run (the .bat
    wrapper exits while the JVM lingers, holding locks on vivado.log/jou
    in the shared cwd — that makes the next launch die instantly).

    SCOPED: only vivado.exe processes spawned by THIS script are killed,
    never a concurrent run of another project."""
    try:
        pids = _own_vivado_pids()
        for pid in pids:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(pid)],
                           capture_output=True, env=env)
            print(f"[e35] killed stray vivado PID {pid}", flush=True)
        if not pids:
            print("[e35] no own vivado to sweep", flush=True)
    except Exception as e:
        print(f"[e35] stray-sweep failed: {e}", flush=True)


t0 = time.time()
summary = []
for v in VARIANTS:
    log = os.path.join(OUT, f"e35_{v}.log")
    wd = os.path.join(OUT, f"wd_{v}")
    os.makedirs(wd, exist_ok=True)
    for junk in ('vivado.log', 'vivado.jou', 'vivado_1.log', 'vivado_1.jou'):
        p = os.path.join(wd, junk)
        if os.path.exists(p):
            os.remove(p)
    env2 = dict(env)
    env2["E35_VARIANT"] = v
    print(f"[e35] === {v} ===", flush=True)
    tv0 = time.time()
    with open(log, "wb") as lf:
        proc = subprocess.Popen([VIVADO, "-mode", "batch", "-source",
                                 os.path.join(SC, "e35_ablation_synth.tcl")],
                                cwd=wd, env=env2, stdout=lf, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)
        try:
            rc = proc.wait(timeout=5400)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(proc.pid)],
                           capture_output=True, env=env)
            kill_stray_vivado()
            print(f"[e35] TIMEOUT for {v}", flush=True)
            summary.append((v, "TIMEOUT", 0))
            continue
    dt = time.time() - tv0
    # scrape headline lines from log
    lines = []
    with open(log, "rb") as f:
        for raw in f.read().decode("utf-8", errors="replace").splitlines():
            if raw.startswith(">>> UTIL:") or raw.startswith(">>> POWER:") or "E35_SYNTH_COMPLETE" in raw:
                lines.append(raw.strip())
    ok = any("E35_SYNTH_COMPLETE" in ln for ln in lines)
    print(f"[e35] rc={rc} in {dt:.0f}s complete={ok}", flush=True)
    for ln in lines:
        print(f"[e35]   {ln}", flush=True)
    summary.append((v, "OK" if ok else f"FAIL rc={rc}", dt))
    # a crashed Vivado can orphan the JVM even when the .bat exits; sweep
    # before the next variant so it does not inherit a locked cwd state
    kill_stray_vivado()
    time.sleep(5)

print(f"[e35] all done in {time.time()-t0:.0f}s", flush=True)
for v, st, dt in summary:
    print(f"[e35] {v:24s} {st:12s} {dt:.0f}s", flush=True)
