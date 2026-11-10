#!/usr/bin/env python3
"""
gen_bram_stubs.py -- M4/E30: generate behavioral BRAM stubs for the funcsim
netlist.

write_verilog -mode funcsim embeds the blk_mem_gen_v8_4_13__NN models inside an
encrypted `pragma protect` region that Icarus cannot read. We replace each
variant with a behavioral dual-port RAM stub with the same port set (widths
inferred from the netlist wiring), which is sufficient for switching-activity
(SAIF) purposes.
"""
import os
import re
import sys

PROJ = str(Path(__file__).resolve().parents[2])
SIM = os.path.join(PROJ, "scripts", "gl_power", "sim_build")
NET = os.path.join(SIM, "gl_netlist_stripped.v")
OUT = os.path.join(SIM, "bram_stubs.v")

MEM_MOD_RE = re.compile(r"^(\s+)(blk_mem_gen_v8_4_13\S*)\s+(\S+)\s*(?:\(.*|\s*)$")


def expr_width(expr: str, scope: dict):
    """resolve bit width of a port connection expression"""
    e = expr.strip()
    m = re.match(r"^NLW_\S*UNCONNECTED\[(\d+):(\d+)\]$", e)
    if m:
        return abs(int(m.group(1)) - int(m.group(2))) + 1
    if re.match(r"^[01]'[bB][01xz]$", e) or e in ("1'b0", "1'b1", "1'bz", "1'bx"):
        return 1
    if e.startswith("{") and e.endswith("}"):
        inner = e[1:-1]
        parts = split_top(inner)
        total = 0
        for p in parts:
            m2 = re.match(r"^\{(\d+)\{(.+)\}\}$", p.strip())
            if m2:
                total += int(m2.group(1)) * expr_width(m2.group(2), scope)
            else:
                total += expr_width(p, scope)
        return total
    # plain net name (maybe escaped)
    name = e.rstrip(";").strip()
    if name in scope:
        return scope[name]
    # escaped identifier may carry trailing space already stripped
    return None


def split_top(s: str):
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def parse_netlist(path):
    """yield (module_name, body_lines) blocks"""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    cur_name = None
    cur_body = []
    for line in lines:
        if line.startswith("module "):
            cur_name = line.split()[1]
            cur_body = []
        elif line.startswith("endmodule"):
            if cur_name:
                yield cur_name, cur_body
            cur_name = None
        elif cur_name is not None:
            cur_body.append(line)


def scan_module(body):
    """collect wire widths + blk_mem_gen instantiations of one module"""
    scope = {}
    decl_re = re.compile(
        r"^\s+(?:input|output|inout|wire|reg|tri)\s+(?:\[(\d+):(\d+)\])?\s*(\S+?)(\s*;|\s*$)")
    for line in body:
        m = decl_re.match(line)
        if m:
            hi, lo, name = m.group(1), m.group(2), m.group(3).strip()
            w = abs(int(hi) - int(lo)) + 1 if hi is not None else 1
            scope[name] = w
    insts = []
    i = 0
    while i < len(body):
        m = MEM_MOD_RE.match(body[i])
        if m and "#" not in body[i]:
            mod_name = m.group(2)
            j = i + 1
            # skip a parameter block if present
            if body[j].strip().startswith("#("):
                depth = 0
                while j < len(body):
                    depth += body[j].count("(") - body[j].count(")")
                    j += 1
                    if depth <= 0:
                        break
            # now port list until ');'
            ports = {}
            depth = 0
            buf = ""
            while j < len(body):
                s = body[j].strip()
                depth += body[j].count("(") - body[j].count(")")
                buf += " " + s
                if depth <= 0 and ")" in s:
                    break
                j += 1
            # parse .port(expr) pairs (exprs contain no parens)
            for pm in re.finditer(r"\.(\w+)\s*\(([^()]*)\)", buf):
                ports[pm.group(1)] = pm.group(2).strip().rstrip(",").strip()
            insts.append((mod_name, ports))
            i = j + 1
            continue
        i += 1
    return scope, insts


def main() -> int:
    # module name -> {port: width}
    mod_ports = {}
    for _name, body in parse_netlist(NET):
        scope, insts = scan_module(body)
        for mod_name, ports in insts:
            entry = mod_ports.setdefault(mod_name, {})
            for p, e in ports.items():
                if p not in entry:
                    w = expr_width(e, scope)
                    if w is not None:
                        entry[p] = w
    print(f"[stub] unique blk_mem_gen variants: {len(mod_ports)}")

    #Ram model port roles
    RAM_PORTS = {
        "clka": "in", "ena": "in", "wea": "in", "addra": "in", "dina": "in",
        "douta": "out", "regcea": "in", "rsta": "in",
        "clkb": "in", "enb": "in", "web": "in", "addrb": "in", "dinb": "in",
        "doutb": "out", "regceb": "in", "rstb": "in",
    }

    out = []
    out.append("// AUTO-GENERATED behavioral BRAM stubs (M4/E30 SAIF flow)")
    out.append("// Replaces encrypted blk_mem_gen_v8_4_13* models of the funcsim netlist.")
    out.append("`timescale 1 ns / 1 ps")
    unresolved = []
    for mod_name in sorted(mod_ports):
        P = mod_ports[mod_name]
        for need in ("clka", "addra", "dina", "douta", "clkb", "addrb", "dinb", "doutb"):
            if need not in P:
                unresolved.append((mod_name, need))
        wa = P.get("wea", 1)
        wb = P.get("web", 1)
        aa, ab = P["addra"], P["addrb"]
        da, db = P["dina"], P["douta"]
        da2, db2 = P["dinb"], P["doutb"]
        depth = 1
        while depth < (1 << aa):
            depth <<= 1
        hdr = [f"module {mod_name} ("]
        terms = []
        for p, w in sorted(P.items()):
            role = RAM_PORTS.get(p)
            if role is None:
                # heuristic: UNCONNECTED-style or known-output suffix => output
                role = "out" if p in (
                    "dbiterr", "douta", "doutb", "rdaddrecc", "rsta_busy",
                    "rstb_busy", "sbiterr", "s_axi_arready", "s_axi_awready",
                    "s_axi_bid", "s_axi_bresp", "s_axi_bvalid",
                    "s_axi_dbiterr", "s_axi_rdaddrecc", "s_axi_rdata",
                    "s_axi_rid", "s_axi_rlast", "s_axi_rresp", "s_axi_rvalid",
                    "s_axi_sbiterr", "s_axi_wready") else "in"
            d = "input " if role == "in" else "output reg "
            terms.append(f"    {d}[{w-1}:0]{p}")
        hdr.append(",\n".join(terms))
        hdr.append(");")
        out.append("\n".join(hdr))
        body = []
        body.append(f"    reg [{max(da, da2)-1}:0] mem [0:{depth-1}];")
        body.append("    integer k;")
        body.append("    initial begin")
        body.append(f"        for (k = 0; k < {depth}; k = k + 1) mem[k] = {max(da, da2)}'b0;")
        body.append("    end")
        body.append("    always @(posedge clka) begin")
        body.append("        if (ena) begin")
        body.append(f"            if (wea) mem[addra[{aa-1}:0]] <= dina[{max(da,da2)-1}:0];")
        body.append(f"            if (regcea) douta <= mem[addra[{aa-1}:0]][{da-1}:0];")
        body.append("        end")
        body.append("        if (rsta) douta <= 0;")
        body.append("    end")
        body.append("    always @(posedge clkb) begin")
        body.append("        if (enb) begin")
        body.append(f"            if (web) mem[addrb[{ab-1}:0]] <= dinb[{max(db,db2)-1}:0];")
        body.append(f"            if (regceb) doutb <= mem[addrb[{ab-1}:0]][{db-1}:0];")
        body.append("        end")
        body.append("        if (rstb) doutb <= 0;")
        body.append("    end")
        out.append("\n".join(body))
        out.append("endmodule")
        out.append("")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print(f"[stub] -> {OUT} ({len(out)} lines)")
    if unresolved:
        print("[stub] WARNING unresolved RAM ports:", unresolved[:10])
    return 0


if __name__ == "__main__":
    sys.exit(main())
