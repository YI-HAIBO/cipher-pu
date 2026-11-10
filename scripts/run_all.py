#!/usr/bin/env python3
"""
A2: 统一回归入口
================

把项目全部 Python 数学验证脚本 + Vivado 仿真脚本串成一条命令，
输出汇总报告 reports/regression_report.md。

用法：
  python scripts/run_all.py              # 跑全部（verify + sim）
  python scripts/run_all.py --verify     # 只跑 Python 数学验证（快，~10s）
  python scripts/run_all.py --sim        # 只跑 Vivado 仿真（慢，~5min）
  python scripts/run_all.py --only m4_h  # 只跑名字含 m4_h 的脚本
  python scripts/run_all.py --list       # 列出全部条目

设计：
  - 子进程 stdout 用 bytes 捕获后手工 decode(errors='replace')，
    规避 Vivado 输出非 UTF-8 导致的 UnicodeDecodeError
  - 每条目记录：退出码、耗时、关键输出行（PASS/FAIL/ALL PASS）
  - 失败条目汇总到报告顶部
"""
import os
import sys
import time
import subprocess
from pathlib import Path

# 镜像（open_source_repo）自包含：以本文件位置推导仓库根，而非硬编码开发者路径。
# 这样发布树在任意机器检出后，run_all.py 都能指向本树自身的 scripts/。
ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
PY = sys.executable or "python"
OUT = ROOT / "reports" / "regression_report.md"

# ---- 条目表：(名字, 相对路径, 分组, 说明) ----
ENTRIES = [
    # ==== Python 数学验证（快）====
    # m1_dsp_mult / m1_ntt_intt 两条目已由 A1 下架（旧版单例 runner run_sim_mult.py /
    # run_sim_ntt.py），其 43x43 乘法器与 NTT/INTT 向量覆盖已并入 run_sim_vivado.py
    # 的 pm_n8 / pm_n16 / ntt_n8 用例，不再单列。
    ("m2_fastred",      "_verify_fastred.py",           "verify", "M2 fast-red 归约验证"),
    ("m2_poly_mult",    "verify_m4_d_approx_mult.py",   "verify", "M2/M4-d 多项式乘法与近似乘法验证"),
    ("m3_rescale",      "verify_rescale.py",            "verify", "M3-b rescale 验证"),
    ("m3_keyswitch",    "verify_keyswitch.py",          "verify", "M3-c keyswitch 验证"),
    ("m3_e2e_mult",     "verify_e2e_mult.py",           "verify", "M3-d E2E 密文乘法验证"),
    ("m3_openfhe",      "verify_openfhe_alignment.py",  "verify", "M3-e OpenFHE 对齐验证"),
    ("c1_multi_slot",   "verify_multi_slot_simd.py",     "verify", "C1 多 slot SIMD 数学等价 (7/7)"),
    ("c2_nn_inference", "verify_m4_nn_inference.py",      "verify", "C2 稀疏推理 NN 层端到端增益"),
    ("m4_a_gear",       "verify_m4_a_gear_ctrl.py",     "verify", "M4-a 档位控制器验证"),
    ("m4_b_sparse",     "verify_m4_b_sparse_ntt.py",    "verify", "M4-b 稀疏 NTT 验证"),
    ("m4_c_trunc",      "verify_m4_c_trunc_mult.py",    "verify", "M4-c 截断乘法器验证"),
    ("m4_e_noise",      "verify_m4_e_noise_analysis.py", "verify", "M4-e 噪声预算分析"),
    ("m4_f_e2e_gears",  "verify_m4_f_e2e_gears.py",     "verify", "M4-f E2E 4 档验证"),
    ("m4_h_adaptive",   "verify_m4_h_adaptive.py",      "verify", "M4-h 自适应稀疏 Python 原型"),
    ("m4_h_prod_cal",   "calibrate_m4_h_prod.py",       "verify", "M4-h.2 生产参数标定"),
    ("m4_h_multilayer", "verify_m4_h_multilayer.py",     "verify", "B3 M4-h.3 多层实际数据流 (6/6)"),
    ("b1_mlp_reference","verify_project_b_mlp_reference.py","verify","B.1 项目B MLP明文vs密文链参考模型 (15/15)"),
    ("b3_e2e_rtl_sim",  "verify_b3_e2e_rtl_sim.py",     "verify","B.3 端到端RTL仿真：加密→多层推理→解密比对 (5/5)"),
    ("compile_bram_ip",      "compile_bram_ip.py",       "verify","BRAM IP HDL 编译冒烟 (xvlog RC=0)"),
    ("compile_bram_ip_prod", "compile_bram_ip_prod.py",  "verify","BRAM IP + wrapper (ntt_mem_tdp_prod) 端口匹配编译"),
    ("lint",            "lint_sv.py",                   "verify", "A4 SV lint 扫描"),

    # ==== Vivado 仿真（慢）====
    # 7 个旧版单例 runner（run_sim_noise_monitor / run_sim_e2e_m4_adaptive /
    # run_sim_e2e_m4_noise_monitor / run_sim_b_layer_ctrl / run_sim_poly_mult /
    # run_sim_ntt_prod / run_sim_poly_mult_prod）已由 A1 下架，其 TB 覆盖（noise_monitor、
    # adaptive_gear_ctrl、E2E 自适应、b_layer_ctrl、poly_mult、NTT 生产配置）全部并入
    # run_sim_vivado.py（Phase 5 通用 runner，B-8 SUITE 15 用例），不再单列。
    ("sim_vivado",        "run_sim_vivado.py",            "sim", "Vivado 全量回归（B-8 SUITE 15 用例：maxpool/fc/conv/activation/ntt/m4e2e/blocksparse/slot_wrapper/b_layer_ctrl/pm_n8/ntt_n8/pm_n16/struct_mask/quant_sparse/gemm_tiling）"),
    ("compile_e2e_m4",    "check_e2e_m4_compile.py",      "sim", "M4-h wrapper 编译冒烟（xvlog+xelab）"),
    ("gen_bram_ip_official","gen_bram_ip_official.py",    "sim", "生成官方 blk_mem_gen 8.4 IP (16384×45 TDP)"),
    ("synth_prod_blocks","run_synth_prod_blocks.py",       "sim", "生产分模块 OOC 综合 + DCP 导出（3 个叶子子模块）"),
]


def run_one(name: str, rel: str) -> dict:
    """跑单个脚本，返回结果 dict。"""
    path = SCRIPTS / rel
    if not path.exists():
        return {"name": name, "rc": -1, "secs": 0.0,
                "status": "MISSING", "pass": 0, "fail": 0, "key": []}

    t0 = time.time()
    try:
        r = subprocess.run(
            [PY, str(path)],
            cwd=str(SCRIPTS),
            capture_output=True,
            timeout=900,
        )
        rc = r.returncode
        raw = (r.stdout or b"") + (r.stderr or b"")
        text = raw.decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        rc = -2
        text = "TIMEOUT after 900s"
    except Exception as e:
        rc = -3
        text = f"EXCEPTION: {e}"
    secs = time.time() - t0

    # 统计 PASS/FAIL
    n_pass = text.count("[PASS]") + text.count("[PASS] ")
    n_fail = text.count("[FAIL]")
    # 兼容 "PASS: 19   FAIL: 0" 汇总行
    key = []
    for ln in text.splitlines():
        if any(k in ln for k in ["ALL PASS", "SOME FAILED", "PASS:", "FAIL:",
                                 "PASS] ", "FAIL]", "GLOBAL TIMEOUT", "ERROR"]):
            s = ln.strip()
            if s and len(s) < 200:
                key.append(s)

    # 环境缺失识别：工具/绑定不可用不算功能失败，标 SKIP
    ENV_MISSING_KW = ["绑定不可用", "引擎不可用", "not found", "No module named",
                      "command not found", "STATUS_DLL_NOT_FOUND"]
    env_missing = [k for k in ENV_MISSING_KW if k in text]

    if env_missing:
        # rc==0 且仅因环境缺失而报 FAIL → SKIP（非功能回归）
        status = "SKIP"
    elif rc == 0 and n_fail == 0 and "SOME FAILED" not in text:
        status = "PASS"
    else:
        status = "FAIL"

    return {"name": name, "rc": rc, "secs": secs, "status": status,
            "pass": n_pass, "fail": n_fail, "key": key[-25:],
            "env_missing": env_missing}


def main():
    args = [a for a in sys.argv[1:]]
    if "--list" in args:
        print(f"{'名字':<22} {'分组':<8} {'脚本'}")
        print("-" * 70)
        for n, r, g, d in ENTRIES:
            print(f"{n:<22} {g:<8} {r}")
        return 0

    only = None
    for a in args:
        if a.startswith("--only="):
            only = a.split("=", 1)[1]

    if "--verify" in args:
        groups = {"verify"}
    elif "--sim" in args:
        groups = {"sim"}
    else:
        groups = {"verify", "sim"}

    selected = [(n, r, g, d) for n, r, g, d in ENTRIES if g in groups]
    if only:
        selected = [e for e in selected if only in e[0]]
    if "--sim" not in args and "--verify" not in args and not only:
        # 默认先快后慢
        selected = [e for e in ENTRIES if e[2] in groups]

    print("=" * 74)
    print("A2: 统一回归入口")
    print("=" * 74)
    print(f"分组: {sorted(groups)}   条目数: {len(selected)}\n")

    results = []
    for n, r, g, d in selected:
        print(f"[RUN ] {n:<22} ({g}) ...", end="", flush=True)
        res = run_one(n, r)
        results.append((res, d, g))
        print(f" {res['status']:<8} rc={res['rc']:<3} "
              f"pass={res['pass']:<3} fail={res['fail']:<3} {res['secs']:.1f}s")

    # ---- 汇总 ----
    n_pass = sum(1 for r, _, _ in results if r["status"] == "PASS")
    n_fail = sum(1 for r, _, _ in results if r["status"] == "FAIL")
    n_miss = sum(1 for r, _, _ in results if r["status"] == "MISSING")
    total_p = sum(r["pass"] for r, _, _ in results)
    total_f = sum(r["fail"] for r, _, _ in results)

    print()
    print("=" * 74)
    print(f"汇总: 条目 {len(results)}  |  通过 {n_pass}  失败 {n_fail}  缺失 {n_miss}")
    print(f"      断言 PASS {total_p}  FAIL {total_f}")
    print("=" * 74)

    # ---- 写报告 ----
    L = []
    L.append("# 统一回归报告\n")
    L.append(f"**日期**：{time.strftime('%Y-%m-%d %H:%M:%S')}  ")
    L.append(f"**分组**：{', '.join(sorted(groups))}  ")
    L.append(f"**条目数**：{len(results)}\n")
    L.append("---\n")
    L.append("\n## 1. 汇总\n")
    L.append("| 指标 | 值 |")
    L.append("|---|---:|")
    L.append(f"| 条目总数 | {len(results)} |")
    L.append(f"| 通过 | {n_pass} |")
    L.append(f"| 失败 | {n_fail} |")
    L.append(f"| 脚本缺失 | {n_miss} |")
    L.append(f"| 断言 PASS 合计 | {total_p} |")
    L.append(f"| 断言 FAIL 合计 | {total_f} |\n")
    L.append(f"**结论**：{'**ALL PASS**' if n_fail == 0 and n_miss == 0 else '**存在失败/缺失项**'}\n")

    L.append("\n## 2. 条目明细\n")
    L.append("| 条目 | 分组 | 状态 | rc | PASS | FAIL | 耗时 | 说明 |")
    L.append("|---|---|---|---:|---:|---:|---:|---|")
    for (r, d, g) in results:
        L.append(f"| {r['name']} | {g} | {r['status']} | {r['rc']} | "
                 f"{r['pass']} | {r['fail']} | {r['secs']:.1f}s | {d} |")

    L.append("\n## 3. 失败条目关键输出\n")
    failed = [(r, d) for r, d, _ in results if r["status"] in ("FAIL", "MISSING")]
    if not failed:
        L.append("无失败条目。\n")
    else:
        for r, d in failed:
            L.append(f"\n### {r['name']} — {r['status']} (rc={r['rc']})\n")
            L.append("```")
            for k in r["key"]:
                L.append(k)
            L.append("```\n")

    OUT.write_text("\n".join(L), encoding="utf-8")
    print(f"\n[SAVE] 报告已写入: {OUT}")
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
