"""Convert an Icarus VCD into an S-expression SAIF_2.0 file Vivado `read_saif` accepts.

Why this exists
---------------
`report_power` on the synthesized masked-NTT DCP reports ~81 W with no
activity file.  That number is nonsense: with no SAIF the tool runs its
vector-less propagation engine and assumes worst-case switching on every net.
A SAIF replaces those assumptions with the switching that a real gate-level
simulation actually produced, which turns `report_power` from a guess into a
defensible dynamic-power estimate.

The bridge is SAIF.  Four things are easy to get wrong, three of which fail
*SILENTLY* (Vivado reports 0% nets matched and keeps the worst-case numbers):

1. `report_power` has NO -saif flag.  The sequence is
       open_checkpoint dcp
       read_saif -strip_path <design> saif_file
       report_power
   `-strip_path` must equal the SAIF's (DESIGN "...") header, because the
   S-expression format roots every net at <design>/<net>.

2. Vivado's `read_saif` parses the S-expression SAIF format (the one Vivado
   Simulator itself emits), NOT the line-oriented "SAIF text" format with
   `#time net (->value)` change records.

3. **Icarus reuses identifier codes.**  The same electrical net is declared
   with the SAME code more than once when it is visible both as a named net
   and as a cell pin (`dut/clk` and `dut/clk_IBUF_inst/I` share one code;
   7364 codes collide in a 16-session run).  A dict keyed by code silently
   keeps only the LAST declaration, mis-attributing the net's activity to a
   pin path that is not a DCP net -> the net is dropped.  This converter
   keeps ALL declarations per code and annotates every one whose
   design-relative path is a DCP net (they are the same node, so the
   activity is identical; Vivado names pin-attached unnamed nets
   `<cell>/<pin>`, which is exactly the second view).

4. **Icarus dumps buses as ONE multi-bit var** (`dut/data0 [23:0]`), while
   the DCP has per-bit nets (`data0[0]` .. `data0[23]`).  Without bit
   expansion every bus net is dropped by the DCP filter.  This converter
   expands multi-bit vars into per-bit nets and computes per-bit T0/T1/TC
   from the vector value history (x/z bits leave the previous state alone).

S-expression SAIF structure
---------------------------
    (SAIFILE
      (SAIFVERSION "2.0")
      (DIRECTION "backward")
      (DESIGN "<design_name>")
      (TIMESCALE 1 ps)
      (DURATION <total_duration_ps>)
      (INSTANCE <design_name>
        (NET <top_level_net> (T0 ...) (T1 ...) (TX 0) (TZ 0) (TB 0) (TC ...))
        (INSTANCE <sub_instance>
          (NET <net> (T0 ...) (T1 ...) (TX 0) (TZ 0) (TB 0) (TC ...))
          (INSTANCE <deeper> ...)
        )
      )
    )

T0 = total time in state 0, T1 = total time in state 1,
TC = total number of value changes.

Hierarchy mapping
-----------------
The VCD is rooted at the testbench, the SAIF must be rooted at the design:

    VCD : tb_vcd_masked_ntt_top / tb_vcd_masked_ntt / dut / ...
    SAIF: masked_ntt_dsa_v2 / ...

After stripping the testbench scopes, the remaining path is the
design-relative net path that Vivado's DCP uses.

VCD escaped identifiers
-----------------------
Icarus emits backslash-escaped identifiers for names containing `[` or `]`.
The backslash is a VCD syntactic marker, not part of the name.  This script
strips the leading backslash before emitting the SAIF name.

DCP filtering
-------------
The gate-level VCD includes UNISIM model parameters (CE_TYPE, SIM_DEVICE,
MODULE_NAME, ...) emitted by iverilog as `$var` entries inside cell-instance
scopes.  Those are not real nets and carry garbage values.  Loading the DCP
net-name set and filtering eliminates them by construction.

Usage
-----
    python scripts/gl_power/vcd_to_saif.py in.vcd out.saif \
           --design masked_ntt_dsa_v2 \
           --strip tb_vcd_masked_ntt_top tb_vcd_masked_ntt dut \
           --dcp-names gl_power/out/dcp_names.txt
"""

import argparse
import os
import re
import sys
from collections import defaultdict


def parse_header(path, log):
    """Stream the VCD header.

    Returns {ident_code: [(full_path, width), ...]} -- a LIST per code,
    because Icarus legitimately emits the same code for the same net seen
    from different scopes (named net + cell-pin view).
    """
    decls = defaultdict(list)
    scopes = []
    n_var = 0
    with open(path, "r", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\r\n")
            if not line:
                continue
            if line[0] != "$":
                continue
            w = line.split()
            kw = w[0]
            if kw == "$scope":
                scopes.append(w[2] if len(w) > 2 else "?")
            elif kw == "$upscope":
                if scopes:
                    scopes.pop()
            elif kw == "$var":
                try:
                    width = int(w[2])
                except (ValueError, IndexError):
                    continue
                ident = w[3]
                name = w[4] if len(w) > 4 else "?"
                # VCD escapes non-simple names with a leading backslash;
                # the backslash itself is not part of the identifier.
                if name.startswith("\\"):
                    name = name[1:]
                # drop a trailing [N:0] range (Icarus emits <name> [msb:lsb])
                name = re.sub(r"\s*\[\s*\d+\s*:\s*\d+\s*\]$", "", name)
                decls[ident].append(("/".join(scopes + [name]), width))
                n_var += 1
            elif kw == "$enddefinitions":
                break
    n_coll = sum(1 for v in decls.values() if len(v) > 1)
    log("  $var entries: %d   unique codes: %d   colliding codes: %d"
        % (n_var, len(decls), n_coll))
    return decls


def remap_path(path, strip, prefix=""):
    """Drop leading testbench scopes; optionally prepend a DCP subtree prefix.

    v4 usage:   remap_path('tb_top/tb/dut/lfsr_reg[0]', ['tb_top','tb','dut'])
                -> 'lfsr_reg[0]'                     (design-relative, sub-DCP)
    v6 usage:   remap_path('tb_top/tb/dut/lfsr_reg[0]', ['tb_top','tb','dut'],
                           'u_mldsa_signer/ntt_u_masked')
                -> 'u_mldsa_signer/ntt_u_masked/lfsr_reg[0]'  (full-chip DCP path)
    """
    parts = path.strip("/").split("/")
    for s in strip:
        if parts and parts[0] == s:
            parts = parts[1:]
    if prefix:
        parts = prefix.split("/") + parts
    return "/".join(parts)


def load_dcp_nets(path):
    """Load DCP net names from dump_nets.tcl output into a set."""
    nets = set()
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if line.startswith("NET "):
                nets.add(line[4:].strip())
    return nets


def build_plan(decls, dcp_nets, strip, prefix, log):
    """Decide which nets to annotate.

    Returns {code: [(net_path, bit_or_None), ...]} where bit is None for
    scalar nets and the LSB index for bit-expanded bus nets.  Every
    declaration of a code is considered, so a net that Icarus declared both
    as a named net and as a cell pin gets annotated under both DCP names.
    """
    plan = defaultdict(set)      # code -> {(net_path, bit)}
    n_scalar = n_bits = 0
    for code, dl in decls.items():
        for full, width in dl:
            desigrel = remap_path(full, strip, prefix)
            if width == 1:
                if desigrel in dcp_nets:
                    plan[code].add((desigrel, None))
                    n_scalar += 1
            else:
                for b in range(width):
                    if "%s[%d]" % (desigrel, b) in dcp_nets:
                        plan[code].add(("%s[%d]" % (desigrel, b), b))
                        n_bits += 1
    log("  annotation plan: %d scalar nets, %d bus bit-nets, %d codes"
        % (n_scalar, n_bits, len(plan)))
    return plan


def stream_changes(path, plan, log):
    """Single pass over the value-change section, accumulating per-net
    T0/T1/TC.

    Returns (stats, n_changes) where stats maps net_path ->
    [t0, t1, tc, prev, last_t]; nets with prev None (never observed with a
    defined value) are dropped by the caller.
    """
    code_nets = {c: sorted(v) for c, v in plan.items()}
    st = {}                       # net_path -> [t0, t1, tc, prev, last_t]
    max_t = 0
    n_changes = 0

    with open(path, "r", errors="replace") as fh:
        in_header = True
        cur_t = 0
        for raw in fh:
            line = raw.rstrip("\r\n")
            if not line:
                continue
            if in_header:
                if line.startswith("$enddefinitions"):
                    in_header = False
                continue
            c0 = line[0]
            if c0 == "#":
                cur_t = int(line[1:])
                continue
            if c0 == "$":
                continue

            if c0 in "01":
                code = line[1:]
                val = 1 if c0 == "1" else 0
                xmask = 0
            elif c0 == "b":
                sp = line[1:].rsplit(" ", 1)
                if len(sp) != 2:
                    continue
                bits, code = sp
                W = len(bits)
                val = 0
                xmask = 0
                for i, ch in enumerate(bits):
                    b = W - 1 - i
                    if ch == "1":
                        val |= (1 << b)
                    elif ch != "0":
                        xmask |= (1 << b)
            else:
                continue

            entries = code_nets.get(code)
            if not entries:
                continue
            n_changes += 1
            if cur_t > max_t:
                max_t = cur_t

            for net_path, bit in entries:
                s = st.get(net_path)
                if s is None:
                    s = st[net_path] = [0, 0, 0, None, None]
                # 1) account time spent in the previous state
                if s[3] is not None and s[4] is not None:
                    dt = cur_t - s[4]
                    if dt > 0:
                        s[0 if s[3] == 0 else 1] += dt
                # 2) extract the new bit value (None-ish x/z -> keep state)
                if bit is None:
                    nv = val & 1
                    undef = xmask & 1
                else:
                    nv = (val >> bit) & 1
                    undef = (xmask >> bit) & 1
                if undef:
                    continue
                if s[3] is None:
                    # first defined observation: value before it is unknown;
                    # account it as 0 (VCD $dumpvars emits initial values at
                    # t=0, so this head is normally zero-length)
                    s[3] = nv
                    if cur_t > 0:
                        s[0] += cur_t
                elif nv != s[3]:
                    s[2] += 1
                    s[3] = nv
                s[4] = cur_t

    # tail: from each net's last change to the end of the observed window
    for net_path, s in st.items():
        if s[3] is not None and s[4] is not None:
            dt = max_t - s[4]
            if dt > 0:
                s[0 if s[3] == 0 else 1] += dt

    n_active = sum(1 for s in st.values() if s[3] is not None)
    log("  clean changes on annotated codes: %d   window end: %d" %
        (n_changes, max_t))
    log("  nets with defined activity: %d" % n_active)
    return st, max_t


def emit_saif(saif_path, design_name, stats, t_end, unit, log):
    """Emit the S-expression SAIF with a properly nested INSTANCE tree."""
    # build the instance tree: {name: {"nets": {...}, "sub": {...}}}
    root = {"nets": {}, "sub": {}}
    for net_path, s in sorted(stats.items()):
        if s[3] is None:
            continue                     # never observed with a defined value
        parts = net_path.split("/")
        net_name = parts[-1]
        node = root
        for inst in parts[:-1]:
            sub = node["sub"]
            if inst not in sub:
                sub[inst] = {"nets": {}, "sub": {}}
            node = sub[inst]
        node["nets"][net_name] = (s[0], s[1], s[2])

    def count(node):
        n = len(node["nets"])
        for c in node["sub"].values():
            n += count(c)
        return n

    n_nets = count(root)
    with open(saif_path, "w", encoding="ascii") as fh:
        w = fh.write
        w("(SAIFILE\n")
        w('  (SAIFVERSION "2.0")\n')
        w('  (DIRECTION "backward")\n')
        w('  (DESIGN "%s")\n' % design_name)
        w('  (DATE "Tue Oct 20 19:00:00 2026")\n')
        w('  (VENDOR "Icarus Verilog")\n')
        w('  (PROGRAM_NAME "vcd_to_saif")\n')
        w('  (VERSION "2.0")\n')
        w("  (DIVIDER /)\n")
        w("  (TIMESCALE 1 %s)\n" % unit)
        w("  (DURATION %d)\n" % t_end)

        def emit_node(node, depth):
            pad = "  " + "  " * depth
            for net_name, (t0, t1, tc) in sorted(node["nets"].items()):
                w('%s(NET %s (T0 %d) (T1 %d) (TX 0) (TZ 0) (TB 0) (TC %d))\n'
                  % (pad, net_name, t0, t1, tc))
            for inst_name, sub in sorted(node["sub"].items()):
                w("%s(INSTANCE %s\n" % (pad, inst_name))
                emit_node(sub, depth + 1)
                w("%s)\n" % pad)

        w("  (INSTANCE %s\n" % design_name)
        emit_node(root, 1)
        w("  )\n")
        w(")\n")

    log("SAIF %s  %.2f MB   nets: %d"
        % (saif_path, os.path.getsize(saif_path) / 1e6, n_nets))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("saif")
    ap.add_argument("--design", default="masked_ntt_dsa_v2")
    ap.add_argument("--strip", nargs="*", default=[],
                    help="leading VCD scopes to drop (testbench hierarchy)")
    ap.add_argument("--dcp-names", default=None,
                    help="dcp_names.txt: filter SAIF to only these nets")
    ap.add_argument("--prefix", default="",
                    help="prefix to prepend to net paths (scope SAIF to a DCP subtree)")
    ap.add_argument("--unit", default="ps", choices=["fs", "ps", "ns", "us"])
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    log = (lambda *x: None) if a.quiet else (lambda *x: print(*x))

    if a.dcp_names:
        dcp_nets = load_dcp_nets(a.dcp_names)
        log("DCP nets loaded: %d" % len(dcp_nets))
    else:
        dcp_nets = None

    log("parsing header of %s" % a.vcd)
    decls = parse_header(a.vcd, log)

    if dcp_nets is None:
        # no filter: annotate everything that has a unique name (debug mode)
        plan = defaultdict(set)
        for code, dl in decls.items():
            for full, width in dl:
                desigrel = remap_path(full, a.strip, a.prefix)
                if width == 1:
                    plan[code].add((desigrel, None))
                else:
                    for b in range(width):
                        plan[code].add(("%s[%d]" % (desigrel, b), b))
    else:
        plan = build_plan(decls, dcp_nets, a.strip, a.prefix, log)

    if not plan:
        log("FATAL: empty annotation plan")
        return 1

    log("streaming value changes")
    stats, t_end = stream_changes(a.vcd, plan, log)

    n_nets = sum(1 for s in stats.values() if s[3] is not None)
    if n_nets == 0:
        log("FATAL: no active nets after filtering")
        return 1

    emit_saif(a.saif, a.design, stats, t_end, a.unit, log)
    return 0


if __name__ == "__main__":
    sys.exit(main())
