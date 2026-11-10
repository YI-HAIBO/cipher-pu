#!/usr/bin/env python3
"""
Phase 5 Task 5.2.1: Python Golden Model for Conv Layer

目标：实现 IM2COL + GEMM 卷积参考模型，用于 RTL 验证
- 输入：28×28×1 灰度图（MNIST）
- 输出：26×26×16 特征图（3×3 卷积，16 个卷积核）
- 权重：16 个 3×3×1 卷积核（预加密）

设计：
- IM2COL：将卷积展开为矩阵乘法
- GEMM：矩阵乘法 Y = X × W^T
- 支持零填充（same padding）

输出：
- conv_golden.py: 运行时参考模型
- test_conv_golden.py: 测试脚本
"""

import numpy as np
import json
import os


class ConvLayerGoldenModel:
    """卷积层 Golden Model"""
    
    def __init__(self, in_channels=1, out_channels=16, kernel_size=3, stride=1, padding=1):
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.kernel_size = kernel_size
        self.stride = stride
        self.padding = padding
        
        # 权重初始化（随机）
        np.random.seed(42)
        self.weights = np.random.randn(out_channels, in_channels, kernel_size, kernel_size) * 0.01
        self.biases = np.random.randn(out_channels) * 0.01
        
        # 预计算 IM2COL 模板
        self._compute_im2col_template()
    
    def _compute_im2col_template(self):
        """预计算 IM2COL 模板（卷积核位置映射）"""
        self.patch_positions = []
        for i in range(self.kernel_size):
            for j in range(self.kernel_size):
                self.patch_positions.append((i, j))
    
    def im2col(self, input_data):
        """
        IM2COL：将输入转换为矩阵形式
        
        输入：[batch, height, width, channels]
        输出：[batch, (height_out * width_out), kernel_size * kernel_size * channels]
        """
        batch, height, width, channels = input_data.shape
        
        # 计算输出尺寸
        height_out = (height + 2 * self.padding - self.kernel_size) // self.stride + 1
        width_out = (width + 2 * self.padding - self.kernel_size) // self.stride + 1
        
        # 填充输入
        if self.padding > 0:
            padded = np.pad(input_data, 
                           ((0, 0), (self.padding, self.padding), 
                            (self.padding, self.padding), (0, 0)),
                           mode='constant', constant_values=0)
        else:
            padded = input_data
        
        # 提取 patches
        patches = []
        for i in range(height_out):
            for j in range(width_out):
                for c in range(channels):
                    patch = padded[i:i+self.kernel_size, 
                                  j:j+self.kernel_size, c].flatten()
                    patches.append(patch)
        
        patches = np.array(patches).reshape(batch, height_out * width_out, -1)
        return patches
    
    def gemm(self, im2col_data, weights):
        """
        GEMM：矩阵乘法 Y = X × W^T
        
        输入：
        - im2col_data: [batch, (height_out * width_out), kernel_size * kernel_size * channels]
        - weights: [out_channels, channels, kernel_size, kernel_size]
        
        输出：[batch, out_channels, height_out, width_out]
        """
        batch, patches, patch_size = im2col_data.shape
        out_channels = weights.shape[0]
        
        # 权重变形为 [out_channels, patch_size]
        weights_flat = weights.reshape(out_channels, -1)
        
        # 矩阵乘法：[batch, patches, patch_size] × [patch_size, out_channels]
        output = np.matmul(im2col_data, weights_flat.T)
        output = output + self.biases  # 加偏置
        
        return output
    
    def forward(self, input_data):
        """
        前向传播
        
        输入：[batch, height, width, channels]
        输出：[batch, height_out, width_out, out_channels]
        """
        # IM2COL
        im2col_data = self.im2col(input_data)
        
        # GEMM
        gemm_output = self.gemm(im2col_data, self.weights)
        
        # 变形为 [batch, height_out, width_out, out_channels]
        batch = input_data.shape[0]
        height_out = (input_data.shape[1] + 2 * self.padding - self.kernel_size) // self.stride + 1
        width_out = (input_data.shape[2] + 2 * self.padding - self.kernel_size) // self.stride + 1
        
        output = gemm_output.transpose(0, 2, 1, 3).reshape(batch, height_out, width_out, self.out_channels)
        
        return output
    
    def forward_with_activation(self, input_data, activation='relu'):
        """前向传播 + 激活函数"""
        output = self.forward(input_data)
        
        if activation == 'relu':
            output = np.maximum(0, output)
        elif activation == 'sigmoid':
            output = 1.0 / (1.0 + np.exp(-output))
        elif activation == 'tanh':
            output = np.tanh(output)
        
        return output
    
    def export_weights(self, output_path='conv_weights.json'):
        """导出权重（JSON 格式）"""
        data = {
            'weights': self.weights.flatten().tolist(),
            'biases': self.biases.tolist(),
            'shape': {
                'in_channels': self.in_channels,
                'out_channels': self.out_channels,
                'kernel_size': self.kernel_size
            }
        }
        
        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2)
        
        print(f"权重已导出: {output_path}")
    
    def export_weights_hex(self, output_path='conv_weights.hex'):
        """导出权重（hex 格式，RTL 用）"""
        lines = []
        
        # 权重
        lines.append("# Conv Layer Weights")
        lines.append(f"# Shape: {self.weights.shape}")
        lines.append(f"# Total: {self.weights.size}")
        lines.append("")
        
        # 量化到 16 bit
        for i, w in enumerate(self.weights.flatten()):
            w_fixed = int(round(w * 32767))
            w_fixed = max(-32768, min(32767, w_fixed))
            lines.append(f"{w_fixed:08x}")
        
        # 偏置
        lines.append("")
        lines.append("# Biases")
        for b in self.biases:
            b_fixed = int(round(b * 32767))
            b_fixed = max(-32768, min(32767, b_fixed))
            lines.append(f"{b_fixed:08x}")
        
        with open(output_path, 'w') as f:
            f.write('\n'.join(lines))
        
        print(f"Hex 权重已导出: {output_path}")
    
    def test_forward(self, test_size=(28, 28, 1), num_samples=5):
        """测试前向传播"""
        print("=" * 60)
        print("Conv Layer Golden Model 测试")
        print("=" * 60)
        
        # 生成测试输入
        np.random.seed(123)
        input_data = np.random.randn(1, *test_size)
        
        # 前向传播
        output = self.forward(input_data)
        
        print(f"\n输入形状: {input_data.shape}")
        print(f"输出形状: {output.shape}")
        print(f"期望输出形状: (1, 26, 26, 16)")
        
        if output.shape == (1, 26, 26, 16):
            print("✅ 输出形状正确")
        else:
            print("❌ 输出形状错误")
        
        # 检查数值范围
        print(f"\n输出统计:")
        print(f"  Min: {output.min():.6f}")
        print(f"  Max: {output.max():.6f}")
        print(f"  Mean: {output.mean():.6f}")
        print(f"  Std: {output.std():.6f}")
        
        # 测试激活函数
        print(f"\n激活函数测试:")
        for act in ['relu', 'sigmoid', 'tanh']:
            output_act = self.forward_with_activation(input_data, act)
            print(f"  {act}: min={output_act.min():.6f}, max={output_act.max():.6f}")
        
        print("\n" + "=" * 60)
        print("✅ Conv Layer Golden Model 测试完成")
        print("=" * 60)
        
        return output


def main():
    """主函数"""
    print("Phase 5 Task 5.2.1: Python Golden Model for Conv Layer")
    print("=" * 60)
    
    # 创建 Conv Layer Golden Model
    model = ConvLayerGoldenModel(in_channels=1, out_channels=16, kernel_size=3, stride=1, padding=1)
    
    # 测试前向传播
    output = model.test_forward()
    
    # 导出权重
    model.export_weights()
    model.export_weights_hex()
    
    print("\n✅ Conv Layer Golden Model 完成")


if __name__ == '__main__':
    main()
