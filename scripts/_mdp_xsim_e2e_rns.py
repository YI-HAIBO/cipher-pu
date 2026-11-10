# -*- coding: utf-8 -*-
"""M-D'：e2e_rns N=16 回归用 xsim（xvlog/xelab/xsim），支持 parameter string。

iverilog 不支持 parameter string（Unable to bind variable），改用 xsim。
流程：_e37_e2e_rns_tb.gen_vectors/write_vecs/write_tb 生成 TB ->
      xvlog 编译 RTL+TB -> xelab snapshot -> xsim run -> 判 PASS。
"""
import os
import subprocess
import sys
import importlib.util

BASE = str(Path(__file__).resolve().parents[1])
BIN = os.environ.get("VIVADO_BIN", "vivado")
XVLOG = os.path.join(BIN, "xvlog.bat")
XELAB = os.path.join(BIN, "xelab.bat")
XSIM = os.path.join(BIN, "xsim.bat")

RTL_M5 = os.path.join(BASE, "rtl", "m5")
RTL_M2 = os.path.join(BASE, "rtl", "m2")
RTL_M1 = os.path.join(BASE, "rtl", "m1")
TB_DIR = os.path.join(BASE, "tb")
WORKDIR = os.path.join(BASE, "sim", "run_e2e_rns_xsim")

RTL = [
    os.path.join(RTL_M5, "e2e_rns_top.sv"),
    os.path.join(RTL_M5, "poly_mult_rns.sv"),
    os.path.join(RTL_M5, "rescale_rns.sv"),
    os.path.join(RTL_M5, "rns_merge.sv"),
    os.path.join(RTL_M2, "poly_mult.sv"),
    os.path.join(RTL_M2, "mod45_fastred.sv"),
    os.path.join(RTL_M1, "ntt_unit.sv"),
    os.path.join(RTL_M1, "ntt_butterfly.sv"),
    os.path.join(RTL_M1, "mult_43x43_horner4.sv"),
    os.path.join(RTL_M1, "ckks_bram.sv"),
    os.path.join(RTL_M1, "ntt_mem_tdp_prod.sv"),
]


def load_tbgen():
    path = os.path.join(BASE, "scripts", "_e37_e2e_rns_tb.py")
    spec = importlib.util.spec_from_file_location("e37tb", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sh(cmd, cwd, env, timeout, tag):
    print("  $ %s" % " ".join(cmd))
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print("  [%s] TIMEOUT" % tag)
        return False, ""
    out = (r.stdout or b"").decode("utf-8", "replace")
    err = (r.stderr or b"").decode("utf-8", "replace")
    tail = (out + err)
    print("  [%s] rc=%d" % (tag, r.returncode))
    if r.returncode != 0:
        print(tail[-3000:])
    return r.returncode == 0, tail


def main():
    tbgen = load_tbgen()
    vec_dir = os.path.join(BASE, "scripts", "_e37_e2e_vecs")
    os.makedirs(vec_dir, exist_ok=True)
    vecs = tbgen.gen_vectors()
    tbgen.write_vecs(vecs, vec_dir)
    tb_file = os.path.join(TB_DIR, "tb_e2e_rns.sv")
    tbgen.write_tb(tb_file, vec_dir)
    print("[OK] TB generated:", tb_file)

    os.makedirs(WORKDIR, exist_ok=True)
    env = os.environ.copy()
    env["XILINX_VIVADO"] = os.environ.get("VIVADO_ROOT", "")

    srcs = [tb_file] + RTL
    ok, _ = sh([XVLOG, "-sv", "-work", "work", "--relax"] + srcs, WORKDIR, env, 300, "xvlog")
    if not ok:
        print(">>> xvlog FAIL"); return 1
    # B-6: TB 的 parameter string REPO_ROOT 由脚本注入仓库绝对路径 (-f 选项文件绕过 cmd 引号解析)
    gen_opts = os.path.join(WORKDIR, "gen_b6.opts")
    repo_abs = BASE.replace("\\", "/")
    with open(gen_opts, "w", encoding="ascii") as f:
        f.write('--generic_top "REPO_ROOT=%s"\n' % repo_abs)
    print("  [B-6] inject --generic_top REPO_ROOT=%s" % repo_abs)
    xelab_cmd = [XELAB, "--relax", "-sv", "-s", "tb_e2e_rns_behav", "-f", gen_opts, "-L", "work", "tb_e2e_rns"]
    ok, _ = sh(xelab_cmd, WORKDIR, env, 900, "xelab")
    if not ok:
        print(">>> xelab FAIL"); return 1
    tclp = os.path.join(WORKDIR, "run_sim.tcl")
    with open(tclp, "w", encoding="ascii") as f:
        f.write("run -all\nquit\n")
    ok, out = sh([XSIM, "tb_e2e_rns_behav", "-tclbatch", "run_sim.tcl",
                  "-log", "xsim_e2e_rns.log"], WORKDIR, env, 300, "xsim")
    if not ok:
        print(">>> xsim FAIL"); return 1
    if "ALL PASS" in out or "RESULT: ALL PASS" in out:
        print(">>> e2e_rns_top RTL 验证: ALL PASS")
        return 0
    print(">>> 有失败：")
    print(out[-2500:])
    return 1


if __name__ == "__main__":
    sys.exit(main())
