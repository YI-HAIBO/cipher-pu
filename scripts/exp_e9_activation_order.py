#!/usr/bin/env python3
"""
E9: 激活函数 Chebyshev 阶数 sweep（poly_order 3-15）

对 ReLU(hard sigmoid) / Sigmoid / Tanh，在 [-1,1] 上按两段分段拟合，
sweep 阶数 3..15，输出：
  - 浮点系数误差：RMSE / MAE / MAX-ERR
  - 定点化误差（coeff_bits=30，与 golden_activation.py 一致）
输出 CSV + Markdown 表，供论文 Experiments 直接引用。
"""

import numpy as np
from numpy.polynomial.chebyshev import chebfit, cheb2poly
from numpy.polynomial import polynomial as P
import csv
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(OUT_DIR)
REPORT_DIR = os.path.join(PARENT, "reports", "experiments")
os.makedirs(REPORT_DIR, exist_ok=True)

COEFF_BITS = 30  # 与 golden_activation.py 一致
SEGMENTS = [(-1.0, 0.0), (0.0, 1.0)]


def f_sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def f_tanh(x):
    return np.tanh(x)


def f_relu(x):
    return np.where(x >= 0, x / (1.0 + np.abs(x)), 0.0)


FUNCS = {"relu": f_relu, "sigmoid": f_sigmoid, "tanh": f_tanh}


def fit_segment(func, a, b, order):
    """在 [a,b] 上做 order 阶 Chebyshev 拟合，返回多项式系数（升序）"""
    n = order + 1
    theta = np.linspace(0, np.pi, n)
    x_norm = np.cos(np.pi - theta)          # [-1,1] 归一化节点
    x = 0.5 * (a + b) + 0.5 * (b - a) * x_norm
    y = func(x)
    cheb = chebfit(x_norm, y, order)
    return cheb2poly(cheb)                   # 归一化域多项式系数


def eval_poly(poly, x_norm):
    # cheb2poly 返回升序幂系数，必须用 polynomial.polyval（升序）
    return P.polyval(x_norm, poly)


def sweep(func_name, order):
    """返回 (rmse, mae, max_err, rmse_q, mae_q, max_err_q)"""
    func = FUNCS[func_name]
    x_test = np.linspace(-1.0, 1.0, 2001)
    y_exact = func(x_test)

    y_approx = np.zeros_like(x_test)
    y_approx_q = np.zeros_like(x_test)
    scale = float(1 << (COEFF_BITS - 1))
    for (a, b) in SEGMENTS:
        poly = fit_segment(func, a, b, order)
        poly_q = np.round(poly * scale) / scale
        mask = (x_test >= a) & (x_test <= b)
        x_n = 2.0 * (x_test[mask] - a) / (b - a) - 1.0
        y_approx[mask] = eval_poly(poly, x_n)
        y_approx_q[mask] = eval_poly(poly_q, x_n)

    err = np.abs(y_exact - y_approx)
    err_q = np.abs(y_exact - y_approx_q)
    return (
        float(np.sqrt(np.mean(err ** 2))), float(np.mean(err)), float(np.max(err)),
        float(np.sqrt(np.mean(err_q ** 2))), float(np.mean(err_q)), float(np.max(err_q)),
    )


def main():
    rows = []
    print("=== E9: 激活 Chebyshev 阶数 sweep（[-1,1] 两段，coeff_bits=30）===")
    print(f"{'func':8s} {'order':>5s} {'RMSE':>10s} {'MAE':>10s} {'MAX':>10s} "
          f"{'RMSE_q':>10s} {'MAE_q':>10s} {'MAX_q':>10s}")
    for fname in ["relu", "sigmoid", "tanh"]:
        for order in range(3, 16):
            r = sweep(fname, order)
            rows.append([fname, order] + list(r))
            print(f"{fname:8s} {order:5d} {r[0]:10.2e} {r[1]:10.2e} {r[2]:10.2e} "
                  f"{r[3]:10.2e} {r[4]:10.2e} {r[5]:10.2e}")

    csv_path = os.path.join(REPORT_DIR, "e9_activation_order_sweep.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["func", "poly_order", "rmse", "mae", "max_err",
                    "rmse_fixed", "mae_fixed", "max_err_fixed"])
        w.writerows(rows)

    md_path = os.path.join(REPORT_DIR, "e9_activation_order_sweep.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write("# E9 激活函数 Chebyshev 阶数 sweep\n\n")
        f.write("区间 [-1,1] 两段分段拟合，coeff_bits=30 定点化（与 golden_activation.py 一致）。\n\n")
        f.write("| 激活 | 阶数 | RMSE | MAE | MAX-ERR | RMSE(定点) | MAE(定点) | MAX(定点) |\n")
        f.write("|---|---:|---:|---:|---:|---:|---:|---:|\n")
        for r in rows:
            f.write(f"| {r[0]} | {r[1]} | {r[2]:.3e} | {r[3]:.3e} | {r[4]:.3e} | "
                    f"{r[5]:.3e} | {r[6]:.3e} | {r[7]:.3e} |\n")
    print()
    print(f"CSV: {csv_path}")
    print(f"MD : {md_path}")


if __name__ == "__main__":
    main()
