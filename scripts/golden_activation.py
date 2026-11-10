#!/usr/bin/env python3
"""
Phase 5 Task 5.1.1: Python Golden Model for Activation Approximation

目标：计算 Chebyshev 多项式系数，用于 RTL 激活函数近似
- ReLU: hard sigmoid x/(1+|x|)
- Sigmoid: 1/(1+e^-x)
- Tanh: 2*sigmoid(2x)-1

设计：
- 分段 Chebyshev 拟合（[-1,0] 和 [0,1] 两段）
- 5 阶多项式（6 个系数）
- 目标 RMSE < 0.005

输出：
- chebyshev_coefficients.txt: RTL 用系数文件
- golden_activation.py: 运行时参考模型
"""

import numpy as np
from numpy.polynomial.chebyshev import chebfit, cheb2poly
from scipy.optimize import brentq
import json
import os


class ActivationGoldenModel:
    """激活函数 Golden Model"""
    
    def __init__(self, poly_order=5, num_segments=2, coeff_bits=30):
        self.poly_order = poly_order
        self.num_segments = num_segments
        self.coeff_bits = coeff_bits
        self.max_val = 2**(coeff_bits - 1) - 1
        
        # 预计算所有激活函数的系数
        self.coeffs = {
            'relu': None,
            'sigmoid': None,
            'tanh': None
        }
        
        # 计算系数
        self._compute_all_coefficients()
    
    def _compute_all_coefficients(self):
        """计算所有激活函数的 Chebyshev 系数"""
        # ReLU (hard sigmoid)
        self.coeffs['relu'] = self._fit_piecewise_chebyshev(
            self._hard_sigmoid, self.poly_order, self.num_segments
        )
        
        # Sigmoid
        self.coeffs['sigmoid'] = self._fit_piecewise_chebyshev(
            self._sigmoid, self.poly_order, self.num_segments
        )
        
        # Tanh
        self.coeffs['tanh'] = self._fit_piecewise_chebyshev(
            self._tanh, self.poly_order, self.num_segments
        )
    
    def _sigmoid(self, x):
        """Sigmoid 函数"""
        return 1.0 / (1.0 + np.exp(-x))
    
    def _tanh(self, x):
        """Tanh 函数"""
        return np.tanh(x)
    
    def _hard_sigmoid(self, x):
        """Hard sigmoid (ReLU 替代)"""
        return np.where(x >= 0, x / (1 + np.abs(x)), 0)
    
    def _fit_piecewise_chebyshev(self, func, order, num_segments):
        """分段 Chebyshev 拟合"""
        segments = []
        
        for seg_idx in range(num_segments):
            # 定义分段区间
            if num_segments == 2:
                if seg_idx == 0:
                    a, b = -1.0, 0.0
                else:
                    a, b = 0.0, 1.0
            else:
                a = -1.0 + seg_idx * (2.0 / num_segments)
                b = -1.0 + (seg_idx + 1) * (2.0 / num_segments)
            
            # Chebyshev 节点（在 [-1, 1] 上）
            n = order + 1
            theta = np.linspace(0, np.pi, n)
            x_cheb_norm = np.cos(np.pi - theta)  # 归一化坐标 [-1, 1]
            
            # 映射到 [a, b] 区间
            x_cheb = 0.5 * (a + b) + 0.5 * (b - a) * x_cheb_norm
            
            # 函数值
            y_cheb = func(x_cheb)
            
            # Chebyshev 拟合（在归一化坐标上）
            coeffs = chebfit(x_cheb_norm, y_cheb, order)
            
            # 转换为普通多项式系数
            poly_coeffs = cheb2poly(coeffs)
            # np.polyval 期望系数按降幂排列（最高次在前）
            poly_coeffs = poly_coeffs[::-1]
            
            segments.append({
                'a': a,
                'b': b,
                'cheb_coeffs': coeffs.tolist(),
                'poly_coeffs': poly_coeffs.tolist()
            })
        
        return segments
    
    def evaluate(self, x, act_type='sigmoid'):
        """评估激活函数（明文参考）"""
        if act_type == 'relu':
            return self._hard_sigmoid(x)
        elif act_type == 'sigmoid':
            return self._sigmoid(x)
        elif act_type == 'tanh':
            return self._tanh(x)
        else:
            return x
    
    def approximate(self, x, act_type='sigmoid'):
        """Chebyshev 近似（用于对比误差）"""
        segments = self.coeffs[act_type]
        
        result = np.zeros_like(x)
        for i in range(len(x)):
            xi = x[i]
            
            # 查找对应分段
            seg_idx = None
            for seg in segments:
                if seg['a'] <= xi < seg['b']:
                    seg_idx = seg
                    break
            if seg_idx is None:
                seg_idx = segments[-1]
            
            # Chebyshev 求值
            a, b = seg_idx['a'], seg_idx['b']
            x_norm = 2 * (xi - a) / (b - a) - 1  # 归一化到 [-1, 1]
            
            # 求值
            result[i] = np.polyval(seg_idx['poly_coeffs'], x_norm)
        
        return result
    
    def compute_error(self, x_test, act_type='sigmoid', num_points=1000):
        """计算近似误差"""
        if isinstance(x_test, (int, float)):
            x_test = np.linspace(x_test, 1, num_points)
        elif not isinstance(x_test, np.ndarray):
            x_test = np.array(x_test)
        
        x_exact = self.evaluate(x_test, act_type)
        x_approx = self.approximate(x_test, act_type)
        
        rmse = np.sqrt(np.mean((x_exact - x_approx) ** 2))
        max_err = np.max(np.abs(x_exact - x_approx))
        
        return {
            'rmse': rmse,
            'max_err': max_err,
            'mean_err': np.mean(x_exact - x_approx),
            'num_points': len(x_test)
        }
    
    def export_coefficients(self, output_path='chebyshev_coefficients.txt'):
        """导出 RTL 用系数文件"""
        lines = []
        lines.append("# Phase 5 Activation Approximation Coefficients")
        lines.append(f"# Generated: {__file__}")
        lines.append(f"# Poly order: {self.poly_order}")
        lines.append(f"# Num segments: {self.num_segments}")
        lines.append(f"# Coeff bits: {self.coeff_bits}")
        lines.append("")
        
        for act_type, segments in self.coeffs.items():
            lines.append(f"# {act_type}")
            for seg_idx, seg in enumerate(segments):
                lines.append(f"# Segment {seg_idx}: [{seg['a']:.6f}, {seg['b']:.6f}]")
                # 转换为定点格式
                for coeff_idx, c in enumerate(seg['poly_coeffs']):
                    # 量化到 coeff_bits 位
                    c_fixed = int(round(c * self.max_val))
                    c_fixed = max(-self.max_val, min(self.max_val, c_fixed))
                    lines.append(f"  coeff[{seg_idx}][{coeff_idx}] = {c_fixed}")
            lines.append("")
        
        with open(output_path, 'w') as f:
            f.write('\n'.join(lines))
        
        print(f"系数已导出: {output_path}")
        return lines
    
    def export_json(self, output_path='golden_activation.json'):
        """导出 JSON 格式系数"""
        data = {
            'poly_order': self.poly_order,
            'num_segments': self.num_segments,
            'coeff_bits': self.coeff_bits,
            'coefficients': {}
        }
        
        for act_type, segments in self.coeffs.items():
            data['coefficients'][act_type] = []
            for seg in segments:
                data['coefficients'][act_type].append({
                    'a': seg['a'],
                    'b': seg['b'],
                    'poly_coeffs': seg['poly_coeffs']
                })
        
        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2)
        
        print(f"JSON 已导出: {output_path}")
    
    def test_all_activations(self):
        """测试所有激活函数的近似误差"""
        print("=" * 60)
        print("激活函数近似误差测试")
        print("=" * 60)
        
        x_test = np.linspace(-1, 1, 1000)
        
        for act_type in ['relu', 'sigmoid', 'tanh']:
            error = self.compute_error(x_test, act_type)
            print(f"\n{act_type}:")
            print(f"  RMSE: {error['rmse']:.6f}")
            print(f"  Max err: {error['max_err']:.6f}")
            print(f"  Mean err: {error['mean_err']:.6f}")
            print(f"  Points: {error['num_points']}")
            
            # 检查是否满足目标
            if error['rmse'] < 0.005:
                print(f"  ✅ 满足目标 (< 0.005)")
            else:
                print(f"  ❌ 不满足目标 (需 < 0.005)")
        
        print("\n" + "=" * 60)
        
        # 累计误差测试（5 层推理）
        print("\n累计误差测试（5 层推理）:")
        x = np.linspace(-1, 1, 100)
        cumulative_error = 0
        for layer in range(5):
            x_approx = self.approximate(x, 'sigmoid')
            x_exact = self.evaluate(x, 'sigmoid')
            layer_err = np.sqrt(np.mean((x_exact - x_approx) ** 2))
            cumulative_error += layer_err
            print(f"  Layer {layer}: RMSE={layer_err:.6f}")
        
        print(f"  5 层累计 RMSE: {cumulative_error:.6f}")
        if cumulative_error < 0.02:
            print(f"  ✅ 满足目标 (< 0.02)")
        else:
            print(f"  ❌ 不满足目标 (需 < 0.02)")


def main():
    """主函数"""
    print("Phase 5 Task 5.1.1: Python Golden Model for Activation")
    print("=" * 60)
    
    # 创建 Golden Model
    model = ActivationGoldenModel(poly_order=5, num_segments=2, coeff_bits=30)
    
    # 测试所有激活函数
    model.test_all_activations()
    
    # 导出系数
    model.export_coefficients()
    model.export_json()
    
    print("\n✅ Golden Model 完成")


if __name__ == '__main__':
    main()
