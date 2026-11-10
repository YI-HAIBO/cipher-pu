#!/usr/bin/env python3
"""
Phase 5 Task 5.2.4: Python Golden Model for MaxPool Layer

目标：实现多项式近似 max 操作的参考模型
- max(a,b) = (a+b+|a-b|)/2
- |a-b| 用 Chebyshev 近似（直接对 |x| 拟合，不用 sqrt(x^2)）
- 2×2 MaxPool：4 次两两 max 操作

设计要点（v2，修复 v1 精度问题）：
- 用 approx_abs 直接近似 |x|（等价于 sqrt(x^2)，但避免了 x^2 溢出到 [0,4]
  而 sqrt poly 只在 [0,1] 拟合导致的多项式爆炸）
- |x| 拟合区间 [-1, 1]；输入 diff = a-b ∈ [-2, 2] 先除以 2 归一化到 [-1,1]，
  再乘 2 还原
- 2×2 MaxPool 用 pairwise max（先两两 max 再 max）
- 归一化到 [-1, 1] 输入前提下，输出也落在 [-1, 1]

输出：
- golden_maxpool.py: 运行时参考模型
- maxpool_coefficients.txt: RTL 用系数
"""

import numpy as np
from numpy.polynomial.chebyshev import chebfit, cheb2poly
import os


class MaxPoolGoldenModel:
    """MaxPool 多项式近似 Golden Model"""

    def __init__(self, pool_size=2, coeff_bits=30, poly_order=12):
        self.pool_size = pool_size
        self.coeff_bits = coeff_bits
        self.poly_order = poly_order
        self.max_val = 2**(coeff_bits - 1) - 1

        # 计算 |x| 的 Chebyshev 系数（在 [-1, 1] 区间）
        self.abs_coeffs = self._fit_abs_chebyshev()

        # 记录用于评估的采样
        self._eval_x = None

    def _fit_abs_chebyshev(self):
        """拟合 |x| 在 [-1, 1] 区间（Chebyshev 节点）"""
        n = self.poly_order + 1
        # 归一化坐标上的 Chebyshev 节点（升序）
        theta = np.linspace(0, np.pi, n)
        x = np.cos(np.pi - theta)  # 升序：-1 ... 1
        y = np.abs(x)
        coeffs = chebfit(x, y, self.poly_order)
        # cheb2poly 返回升序，np.polyval 期望降序，故反转
        poly_coeffs = cheb2poly(coeffs)[::-1]
        return poly_coeffs

    def approx_abs(self, x):
        """近似 |x|，x ∈ [-1, 1]"""
        return np.polyval(self.abs_coeffs, x)

    def approx_max(self, a, b):
        """
        近似 max(a, b) = (a + b + |a-b|) / 2
        假设 a, b ∈ [-1, 1]，则 diff = a-b ∈ [-2, 2]
        """
        diff = a - b
        # 归一化到 [-1, 1]，再近似 |·|，再乘回 2
        diff_norm = diff / 2.0
        abs_diff_norm = self.approx_abs(diff_norm)
        abs_diff = abs_diff_norm * 2.0
        return (a + b + abs_diff) / 2.0

    def maxpool_2x2(self, input_data):
        """
        2×2 MaxPool

        输入：[batch, height, width, channels]（batch 必须是 1）
        输出：[batch, height/2, width/2, channels]
        """
        batch, height, width, channels = input_data.shape
        if batch != 1:
            raise ValueError("maxpool_2x2 只支持 batch=1")

        height_out = height // self.pool_size
        width_out = width // self.pool_size

        output = np.zeros((batch, height_out, width_out, channels))

        for i in range(height_out):
            for j in range(width_out):
                for c in range(channels):
                    patch = input_data[0, i*2:(i+1)*2, j*2:(j+1)*2, c]  # 2x2
                    p0 = patch[0, 0]
                    p1 = patch[0, 1]
                    p2 = patch[1, 0]
                    p3 = patch[1, 1]
                    # pairwise max: max(p0,p1), max(p2,p3), 再 max
                    m1 = self.approx_max(p0, p1)
                    m2 = self.approx_max(p2, p3)
                    final_max = self.approx_max(m1, m2)
                    output[0, i, j, c] = final_max

        return output

    def compute_error(self, num_points=5000, seed=42):
        """计算近似误差"""
        rng = np.random.default_rng(seed)
        a = rng.uniform(-1, 1, num_points)
        b = rng.uniform(-1, 1, num_points)

        exact = np.maximum(a, b)
        approx = np.array([self.approx_max(ai, bi) for ai, bi in zip(a, b)])
        errors = np.abs(exact - approx)

        return {
            'rmse': float(np.sqrt(np.mean(errors ** 2))),
            'max_err': float(np.max(errors)),
            'mean_err': float(np.mean(errors)),
            'num_points': num_points,
        }

    def compute_abs_error(self, num_points=2000):
        """单独评估 |x| 近似误差"""
        x = np.linspace(-1, 1, num_points)
        exact = np.abs(x)
        approx = self.approx_abs(x)
        errors = np.abs(exact - approx)
        return {
            'rmse': float(np.sqrt(np.mean(errors ** 2))),
            'max_err': float(np.max(errors)),
        }

    def export_coefficients(self, output_path=None):
        """导出 RTL 用系数文件（定点 30-bit，符号位 + 29 位分数）"""
        if output_path is None:
            here = os.path.dirname(os.path.abspath(__file__))
            output_path = os.path.join(here, 'maxpool_coefficients.txt')

        lines = []
        lines.append("# Phase 5 MaxPool Approximation Coefficients")
        lines.append(f"# Generated: {os.path.basename(__file__)}")
        lines.append(f"# Poly order (abs |x|): {self.poly_order}")
        lines.append(f"# Coeff bits: {self.coeff_bits}")
        lines.append(f"# Max fixed value: {self.max_val}")
        lines.append("")

        lines.append("# |x| approximation on [-1, 1]")
        lines.append("# poly_coeffs 为降幂排列，np.polyval 语义")
        for i, c in enumerate(self.abs_coeffs):
            c_fixed = int(round(c * self.max_val))
            c_fixed = max(-self.max_val, min(self.max_val, c_fixed))
            lines.append(f"  abs_coeff[{i}] = {c_fixed}")

        with open(output_path, 'w') as f:
            f.write('\n'.join(lines))

        print(f"系数已导出: {output_path}")
        return lines

    def test_approximation(self):
        """测试近似精度"""
        print("=" * 60)
        print("MaxPool 多项式近似精度测试")
        print("=" * 60)

        # |x| 拟合误差
        abs_err = self.compute_abs_error()
        print(f"\n|x| 拟合精度（poly_order={self.poly_order}）:")
        print(f"  RMSE: {abs_err['rmse']:.6f}")
        print(f"  Max err: {abs_err['max_err']:.6f}")

        # max(a,b) 近似误差
        error = self.compute_error(num_points=5000)
        print(f"\nmax(a,b) 近似精度:")
        print(f"  RMSE: {error['rmse']:.6f}")
        print(f"  Max err: {error['max_err']:.6f}")
        print(f"  Mean err: {error['mean_err']:.6f}")
        print(f"  Points: {error['num_points']}")

        if error['rmse'] < 0.03:
            print(f"  ✅ RMSE 满足目标 (< 0.03，MaxPool 精度容忍度)")
        else:
            print(f"  ❌ RMSE 不满足目标 (需 < 0.03)")

        # 2×2 MaxPool
        print(f"\n2×2 MaxPool 测试:")
        rng = np.random.default_rng(7)
        input_data = rng.uniform(-1, 1, size=(1, 4, 4, 1))  # 归一化到 [-1,1]
        output_data = self.maxpool_2x2(input_data)

        print(f"  输入形状: {input_data.shape}")
        print(f"  输出形状: {output_data.shape}")

        if output_data.shape == (1, 2, 2, 1):
            print(f"  ✅ 输出形状正确")
        else:
            print(f"  ❌ 输出形状错误")

        # 数值范围
        print(f"\n  输出统计:")
        print(f"    Min: {output_data.min():.6f}")
        print(f"    Max: {output_data.max():.6f}")
        print(f"    Mean: {output_data.mean():.6f}")

        # 与真值比较：真 maxpool 2×2
        true_out = np.zeros_like(output_data)
        for i in range(2):
            for j in range(2):
                patch = input_data[0, i*2:(i+1)*2, j*2:(j+1)*2, 0]
                true_out[0, i, j, 0] = patch.max()

        mp_err = float(np.sqrt(np.mean((output_data - true_out) ** 2)))
        print(f"\n  与真 2×2 MaxPool 对比 RMSE: {mp_err:.6f}")

        print("\n" + "=" * 60)
        print("✅ MaxPool Golden Model 测试完成")
        print("=" * 60)

        return output_data


def main():
    """主函数"""
    print("Phase 5 Task 5.2.4: Python Golden Model for MaxPool")
    print("=" * 60)

    # 从低阶到高阶扫一遍，看看 poly_order 选型
    print("\n[扫参] 不同 poly_order 下的 max(a,b) 近似精度:")
    print(f"{'order':>6} {'rmse':>12} {'max_err':>12} {'mean_err':>12}")
    for order in [3, 4, 5, 6, 7, 8, 10, 12]:
        m = MaxPoolGoldenModel(poly_order=order)
        err = m.compute_error(num_points=2000)
        print(f"{order:>6} {err['rmse']:>12.6f} {err['max_err']:>12.6f} {err['mean_err']:>12.6f}")

    print()

    # 用推荐 poly_order=12 做主测试（生产配置：12 MACs，RMSE 0.026）
    model = MaxPoolGoldenModel(pool_size=2, coeff_bits=30, poly_order=12)
    model.test_approximation()
    model.export_coefficients()

    print("\n✅ MaxPool Golden Model 完成")


if __name__ == '__main__':
    main()
