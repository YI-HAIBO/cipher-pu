#!/usr/bin/env python3
"""
Phase 5 Task 5.2.7: Python Golden Model for Fully Connected Layer

目标：实现密文域 FC 层 GEMM 的参考模型
- Y = X × W^T + b
- 支持任意 IN_DIM / OUT_DIM（用于 FC1 和 FC2）
- 权重与偏置导出为 RTL 可读的定点格式

设计要点：
- 输入 X：shape [n_slots, IN_DIM]（n_slots 独立多项式）
- 权重 W：shape [OUT_DIM, IN_DIM]（Kaiming 初始化）
- 偏置 b：shape [OUT_DIM]（全零）
- 输出 Y：shape [n_slots, OUT_DIM]
- 定点量化：10-bit 输入 + 8-bit 权重，Δ = 2^30

用途：
- MNIST 简化 CNN 训练完成后导出权重
- RTL 仿真 golden 比对
- 端到端精度测试基线
"""

import numpy as np
import json
import os


class FCLayerGoldenModel:
    """FC 层 Golden Model"""

    def __init__(self, in_dim, out_dim, seed=None):
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.seed = seed if seed is not None else 42

        # Xavier/Kaiming 初始化
        rng = np.random.default_rng(self.seed)
        scale = np.sqrt(2.0 / (in_dim + out_dim))
        self.weights = rng.standard_normal((out_dim, in_dim)) * scale
        self.bias = np.zeros(out_dim, dtype=np.float32)

    def forward(self, x):
        """
        前向传播：Y = X @ W^T + b

        x: shape [n_slots, in_dim] 或 [in_dim]
        返回: shape [n_slots, out_dim] 或 [out_dim]
        """
        x = np.asarray(x, dtype=np.float32)
        if x.ndim == 1:
            y = x @ self.weights.T + self.bias
            return y
        y = x @ self.weights.T + self.bias
        return y

    def quantize_input(self, x, bits=10, scale=2**30):
        """将浮点输入量化到整数（模拟硬件 10-bit 输入）"""
        x_int = np.round(x * scale).astype(np.int64)
        x_int = np.clip(x_int, -(1 << (bits - 1)), (1 << (bits - 1)) - 1)
        return x_int

    def quantize_weights(self, w, bits=8, scale=2**30):
        """将浮点权重量化到整数（模拟硬件 8-bit 权重）"""
        w_int = np.round(w * scale).astype(np.int64)
        w_int = np.clip(w_int, -(1 << (bits - 1)), (1 << (bits - 1)) - 1)
        return w_int

    def export_weights(self, output_path=None):
        """导出权重到 JSON（供 RTL 加载）"""
        if output_path is None:
            here = os.path.dirname(os.path.abspath(__file__))
            output_path = os.path.join(here, f"fc_weights_{self.in_dim}x{self.out_dim}.json")

        data = {
            "in_dim": self.in_dim,
            "out_dim": self.out_dim,
            "weights": self.weights.flatten().tolist(),
            "bias": self.bias.tolist(),
            "weights_hex": [hex(int(round(v * 2**30)) & ((1<<45)-1))
                            for v in self.weights.flatten()],
        }

        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2)

        print(f"权重已导出: {output_path}")
        print(f"  形状: ({self.out_dim}, {self.in_dim})")
        print(f"  权重范围: [{self.weights.min():.4f}, {self.weights.max():.4f}]")
        print(f"  偏置范围: [{self.bias.min():.4f}, {self.bias.max():.4f}]")

        return data

    def test_forward(self, num_slots=4, seed=7):
        """测试前向传播精度"""
        rng = np.random.default_rng(seed)
        x = rng.standard_normal((num_slots, self.in_dim))

        # 浮点参考
        y_float = self.forward(x)

        # 量化测试
        x_q = self.quantize_input(x) / 2**30
        w_q = self.quantize_weights(self.weights) / 2**30
        y_q = x_q @ w_q.T + self.bias

        # 精度对比
        abs_err = np.abs(y_float - y_q)
        rel_err = abs_err / (np.abs(y_float) + 1e-8)

        print(f"\nFC {self.in_dim}x{self.out_dim} 前向传播测试:")
        print(f"  输入形状: {x.shape}")
        print(f"  输出形状: {y_float.shape}")
        print(f"  量化 vs 浮点:")
        print(f"    RMSE: {np.sqrt(np.mean(abs_err**2)):.6f}")
        print(f"    Max err: {abs_err.max():.6f}")
        print(f"    Mean rel err: {rel_err.mean():.6f}")

        # 输出统计
        print(f"\n  输出统计:")
        print(f"    Min: {y_float.min():.6f}")
        print(f"    Max: {y_float.max():.6f}")
        print(f"    Mean: {y_float.mean():.6f}")
        print(f"    Std: {y_float.std():.6f}")

        return y_float, y_q


def build_mnist_cnn_model(in_dim_fc1=512, mid_dim=128, num_classes=10, seed=42):
    """构造 MNIST 简化 CNN 的两层 FC（用于端到端测试）"""
    fc1 = FCLayerGoldenModel(in_dim=in_dim_fc1, out_dim=mid_dim, seed=seed)
    fc2 = FCLayerGoldenModel(in_dim=mid_dim, out_dim=num_classes, seed=seed + 1)

    print(f"MNIST 简化 CNN FC 部分:")
    print(f"  FC1: {in_dim_fc1} → {mid_dim}")
    print(f"  FC2: {mid_dim} → {num_classes}")

    return fc1, fc2


def main():
    print("Phase 5 Task 5.2.7: Python Golden Model for FC Layer")
    print("=" * 60)

    # 构造 MNIST CNN 的两层 FC
    fc1, fc2 = build_mnist_cnn_model(in_dim_fc1=512, mid_dim=128, num_classes=10)

    # 测试 FC1
    print("\n" + "=" * 60)
    fc1.test_forward(num_slots=4)

    # 测试 FC2
    print("\n" + "=" * 60)
    fc2.test_forward(num_slots=4)

    # 端到端测试：FC1 → ReLU → FC2
    print("\n" + "=" * 60)
    print("端到端 FC1 → ReLU → FC2 测试:")
    rng = np.random.default_rng(99)
    x = rng.standard_normal((4, 512))  # 4 个 slot 的输入

    # 浮点端到端
    h1 = fc1.forward(x)
    h1_relu = np.maximum(h1, 0)  # ReLU
    logits = fc2.forward(h1_relu)

    print(f"  输入形状: {x.shape}")
    print(f"  FC1 输出: {h1.shape}")
    print(f"  ReLU 后: {h1_relu.shape}")
    print(f"  Logits: {logits.shape}")
    print(f"  Logits 范围: [{logits.min():.4f}, {logits.max():.4f}]")

    # 导出权重
    print("\n" + "=" * 60)
    print("导出权重:")
    fc1.export_weights()
    fc2.export_weights()

    print("\n✅ FC Layer Golden Model 完成")


if __name__ == '__main__':
    main()
