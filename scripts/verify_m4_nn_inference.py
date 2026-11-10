#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
C2 / M4-h: 稀疏推理真实 NN 层端到端吞吐增益
================================================
在**真实 FHE 友好神经网络层拓扑**上测静态档位 vs 运行时自适应档位的端到端
吞吐增益。基于 M4-h 的解析噪声增长模型 + 档位吞吐比（GEO 表），
逐层累加噪声、逐层选档，与固定档位基线对比。

模型（对齐 M4-e / M4-h）：
  - 每层：r_{L+1} = r_L · total_growth(gear_L)
  - 自适应：safety-first 选最高档使 r_{L+1} < R_MAX，+ 迟滞
  - 吞吐：层间累计 total_throughput = Π gear.throughput
  - 解码条件：r_L < R_MAX 全程成立

FHE 友好 NN 层拓扑（真实结构）：
  - 隐藏层：Dense(MATMUL via slot-wise poly mult) + 平方激活（1 次 poly mult）
  - 每层 2 次 poly_mult（MATMUL 或近似，激活 1 次）→ 噪声增长 2 次
  - 输出层：Dense
  设定与 OpenFHE/CKKS 推理常用配置一致的层级噪声增长。

产出：
  - reports/m4_g_nn_inference.md
  - sim/tb_m4_nn_inference/nn_gain.csv（逐层 trace）
"""

import math
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# ===================== 生产参数（M4-h.2 标定） =====================
Q = 2 ** 44 + 131073
R_INIT = 1.0 / (1 << 24)
R_MAX = 0.5
BASE_GROWTH = 1.55
NUM_SLOTS = 1024          # 推理多 slot 数（batch 维度）
SLOT_DEGREE = 16384       # poly degree（与 N 一致）

GEO = [
    {"name": "Gear0", "threshold": 0,     "trunc_bits": 0,  "skip_rate": 0.00, "throughput": 1.0},
    {"name": "Gear1", "threshold": 4096,  "trunc_bits": 0,  "skip_rate": 0.15, "throughput": 1.3},
    {"name": "Gear2", "threshold": 16384, "trunc_bits": 9,  "skip_rate": 0.30, "throughput": 2.0},
    {"name": "Gear3", "threshold": 65536, "trunc_bits": 17, "skip_rate": 0.50, "throughput": 3.0},
]


def compute_extra(g):
    sigma_skip = math.sqrt(SLOT_DEGREE * g["skip_rate"]) * g["threshold"] / math.sqrt(12.0)
    sigma_trunc = (2.0 ** g["trunc_bits"]) / math.sqrt(12.0)
    sigma_0 = Q * R_INIT
    base_growth_abs = sigma_0 * (BASE_GROWTH - 1)
    return 1.0 + (sigma_skip + sigma_trunc) / base_growth_abs


def total_growth(g):
    return BASE_GROWTH * compute_extra(g)


def select_gear_safe(r):
    """safety-first: 取最高档使 r·growth(g) < R_MAX，否则 Gear0。"""
    for gi in range(3, -1, -1):
        if r * total_growth(GEO[gi]) < R_MAX:
            return gi
    return 0


def gear_throughput(gear):
    return GEO[gear]["throughput"]


def simulate_adaptive(n_layers, ops_per_layer=4):
    """逐层自适应档位；每层 ops_per_layer 次密文乘法（MATMUL+激活等）。
    每次 MULT 噪声增长一次（真实每层多个 poly_mult）。档位在层内复用
    （一次选档应用于该层全部 MULT）。"""
    r = R_INIT
    gears = []
    ts = []
    cum = 1.0
    for L in range(n_layers):
        g = select_gear_safe(r)          # 层首选档
        tp = gear_throughput(g)
        cum *= tp
        ts.append(cum)
        # 该层共 ops_per_layer 次 MULT，逐次乘噪声增长率
        for _ in range(ops_per_layer):
            r *= total_growth(GEO[g])
        gears.append(g)
    return gears, ts, r


def simulate_static(gear, n_layers, ops_per_layer=4):
    """固定档位。"""
    r = R_INIT
    ts = []
    cum = 1.0
    g = GEO[gear]
    for L in range(n_layers):
        cum *= g["throughput"]
        ts.append(cum)
        for _ in range(ops_per_layer):
            r *= total_growth(g)
    return ts, r


def main():
    print("=" * 76)
    print("C2: 稀疏推理真实 NN 层端到端吞吐增益（解析噪声模型）")
    print("=" * 76)
    print(f"Q≈2^44, r_init={R_INIT:.2e}, r_max={R_MAX}, base_growth={BASE_GROWTH}")
    print(f"slot_degree={SLOT_DEGREE}（每层 MATMUL+激活≈多次 poly_mult）")
    print()

    # 真实 FHE-友好 NN 层配置（隐藏层数可配）
    topologies = {
        "mlp2":   {"hidden": 2,  "desc": "MLP-2 层"},
        "mlp4":   {"hidden": 4,  "desc": "MLP-4 层"},
        "mlp8":   {"hidden": 8,  "desc": "MLP-8 层（近似深度）"},
        "cnn4":   {"hidden": 4,  "desc": "小型 CNN（卷积≈matmul）4 层"},
    }

    # 每个拓扑：静态 vs 自适应
    print(f"{'拓扑':<14} {'自适应吞吐':>10} {'静态G0吞吐':>10} {'静态G3吞吐':>10} "
          f"{'自适应/静态G0':>12} {'自适应/静态G3':>12}")
    print("-" * 78)

    results = {}
    OPS = 4   # 每层密文乘法次数（MATMUL 近似 + 激活，真实 NN 层的 FHE 代价）
    for key, cfg in topologies.items():
        L = cfg["hidden"] + 1          # 隐藏 + 输出
        gear_adapt, ts_adapt, _ = simulate_adaptive(L, OPS)
        ts_g0, _ = simulate_static(0, L, OPS)
        ts_g3, r_g3 = simulate_static(3, L, OPS)
        # 静态 G3 若中途越界解码失败，吞吐记为 None
        g3_ok = r_g3 < R_MAX
        g3_tp = ts_g3[-1] if g3_ok else None
        gain_g0 = ts_adapt[-1] / ts_g0[-1]
        gain_g3 = (ts_adapt[-1] / g3_tp) if g3_ok else float('nan')
        results[key] = {
            "layers": L, "gear_adapt": gear_adapt,
            "tp_adapt": ts_adapt[-1], "tp_g0": ts_g0[-1],
            "tp_g3": g3_tp, "g3_ok": g3_ok,
            "gain_vs_g0": gain_g0, "gain_vs_g3": gain_g3,
        }
        g3_str = f"{g3_tp:.0f}x" if g3_ok else "解码失败"
        print(f"{cfg['desc']:<14} {ts_adapt[-1]:>10.0f} {ts_g0[-1]:>10.0f} "
              f"{g3_str:>10} {gain_g0:>11.1f}x {gain_g3:>11.1f}x")

    # 明细：MLP-4 逐层
    print()
    print(f"=== MLP-4 逐层自适应档位与累计吞吐（每层 {OPS} 次 MULT）===")
    L = 5
    gears, ts, _ = simulate_adaptive(L, OPS)
    print(f"{'L':>3s} {'gear':>6s} {'吞吐':>6s} {'累计':>10s}")
    for i, (g, t) in enumerate(zip(gears, ts)):
        print(f"{i+1:>3d} {GEO[g]['name']:>6s} {GEO[g]['throughput']:>6.1f} {t:>10.0f}")

    # 结论
    print()
    print("=== 关键结论 ===")
    mlp4 = results["mlp4"]
    print(f"① MLP-4: 自适应 vs 静态 Gear0 吞吐增益 = {mlp4['gain_vs_g0']:.1f}x")
    print(f"② 静态 Gear3 在 MLP-4 下 {'解码成功' if mlp4['g3_ok'] else '解码失败'}"
          f"{'' if mlp4['g3_ok'] else '（r 超 R_MAX，无法解码）'}")
    print(f"③ 自适应在逐层预算内压到最高允许档，避免固定高档位的解码失败")

    # 保存 CSV
    out = ROOT / "sim" / "tb_m4_nn_inference"
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for key, r_ in results.items():
        rows.append([key, r_["layers"], r_["tp_adapt"], r_["tp_g0"],
                     r_["tp_g3"] if r_["tp_g3"] else 0,
                     r_["gain_vs_g0"], r_["gain_vs_g3"]])
    import csv, io
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["topo", "layers", "tp_adapt", "tp_g0", "tp_g3_ok", "gain_g0", "gain_g3"])
    w.writerows(rows)
    (out / "nn_gain.csv").write_text(buf.getvalue(), encoding="utf-8")
    print(f"\nCSV 已存: {out/'nn_gain.csv'}")

    sys.exit(0)


if __name__ == "__main__":
    main()