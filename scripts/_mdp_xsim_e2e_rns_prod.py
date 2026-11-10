# -*- coding: utf-8 -*-
"""M-D'：N=4096 生产真密文 e2e_rns bit-exact 回归（xsim，支持 parameter string）。

背景：twiddle 表从 input 数组组合 mux 改为内部 block ROM + $readmemh 同步读后，
M-C 的 N=4096 真密文 bit-exact 结论需在真实规模重验（N=16 玩具已 PASS）。

流程（不重新生成 golden，复用 _e37_e2e_vecs_prod/ 的 M-C 真密文向量）：
  xvlog 编译 RTL + tb_e2e_rns_prod.sv -> xelab snapshot -> xsim run -> 判 PASS。

注意：ntt_unit 内部 $readmemh 从 rtl/m5/tw/ 读 n4096 twiddle .hex；
      golden（exp*.hex）由 _e37_e2e_rns_prod_tb.py 用同一组 omega 计算。
"""
import os
import subprocess
import sys

BASE = str(Path(__file__).resolve().parents[1])
BIN = os.environ.get("VIVADO_BIN", "vivado")
XVLOG = os.path.join(BIN, "xvlog.bat")
XELAB = os.path.join(BIN, "xelab.bat")
XSIM = os.path.join(BIN, "xsim.bat")

RTL_M5 = os.path.join(BASE, "rtl", "m5")
RTL_M2 = os.path.join(BASE, "rtl", "m2")
RTL_M1 = os.path.join(BASE, "rtl", "m1")
TB_DIR = os.path.join(BASE, "tb")
WORKDIR = os.path.join(BASE, "sim", "run_e2e_rns_prod_xsim")

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
    # 前置：golden 向量必须在（M-C 已生成，不重新算）
    vec_dir = os.path.join(BASE, "scripts", "_e37_e2e_vecs_prod")
    need = ["a0.hex", "b0.hex", "exp0.hex", "om1.hex"]
    if not all(os.path.exists(os.path.join(vec_dir, f)) for f in need):
        print(">>> golden 向量缺失，请先运行 _e37_e2e_rns_prod_tb.py（gen_vecs）")
        return 1
    tb_file = os.path.join(TB_DIR, "tb_e2e_rns_prod.sv")
    if not os.path.exists(tb_file):
        print(">>> TB 缺失:", tb_file)
        return 1

    os.makedirs(WORKDIR, exist_ok=True)
    env = os.environ.copy()
    env["XILINX_VIVADO"] = os.environ.get("VIVADO_ROOT", "")

    srcs = [tb_file] + RTL
    ok, _ = sh([XVLOG, "-sv", "-work", "work", "--relax"] + srcs, WORKDIR, env, 600, "xvlog")
    if not ok:
        print(">>> xvlog FAIL"); return 1
    # B-6: TB 的 parameter string REPO_ROOT 由脚本注入仓库绝对路径 (-f 选项文件绕过 cmd 引号解析)
    gen_opts = os.path.join(WORKDIR, "gen_b6.opts")
    repo_abs = BASE.replace("\\", "/")
    with open(gen_opts, "w", encoding="ascii") as f:
        f.write('--generic_top "REPO_ROOT=%s"\n' % repo_abs)
    print("  [B-6] inject --generic_top REPO_ROOT=%s" % repo_abs)
    xelab_cmd = [XELAB, "--relax", "-sv", "-s", "tb_e2e_rns_prod_behav", "-f", gen_opts, "-L", "work", "tb_e2e_rns_prod"]
    ok, _ = sh(xelab_cmd, WORKDIR, env, 1800, "xelab")
    if not ok:
        print(">>> xelab FAIL"); return 1
    tclp = os.path.join(WORKDIR, "run_sim.tcl")
    with open(tclp, "w", encoding="ascii") as f:
        f.write("run -all\nquit\n")
    ok, out = sh([XSIM, "tb_e2e_rns_prod_behav", "-tclbatch", "run_sim.tcl",
                  "-log", "xsim_e2e_rns_prod.log"], WORKDIR, env, 900, "xsim")
    if not ok:
        print(">>> xsim FAIL"); return 1
    if "ALL PASS" in out or "RESULT: ALL PASS" in out:
        print(">>> e2e_rns_top N=4096 真密文 RTL 验证: ALL PASS")
        return 0
    print(">>> 有失败：")
    print(out[-2500:])
    return 1


if __name__ == "__main__":
    sys.exit(main())
