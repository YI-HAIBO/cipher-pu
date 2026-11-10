#!/usr/bin/env python3
"""
ciph_stat_probe 验证脚本 - 1. Python Golden Model
"""
import numpy as np
from typing import List, Dict, Tuple

class CipherStatProbe:
    """密文域统计探针Python参考实现"""
    
    def __init__(self, q_width: int = 45, stat_mode: int = 3, hist_bins: int = 64):
        self.q_width = q_width
        self.stat_mode = stat_mode
        self.hist_bins = hist_bins
        
        self.buffer = []
        self.histogram = np.zeros(hist_bins, dtype=np.int32)
        self.importance = 0
        
    def process_coefficient(self, coeff: int) -> Tuple[float, np.ndarray]:
        """处理单个系数，返回重要性和直方图"""
        self.buffer.append(coeff)
        
        # 重要性计算
        self.importance = np.abs(coeff)
        
        # 直方图计算
        hist_bin = np.floor((coeff + 2**(self.q_width-1)) / 2**self.q_width * self.hist_bins)
        hist_bin = int(min(hist_bin, self.hist_bins - 1))
        self.histogram[hist_bin] += 1
        
        return self.importance, self.histogram.copy()
    
    def get_statistics(self) -> Dict[str, np.ndarray]:
        """获取统计结果"""
        if len(self.buffer) == 0:
            return {
                'importance': 0,
                'histogram': np.zeros(self.hist_bins),
                'quant_param': 0,
                'precision_loss': 0
            }
        
        # 直方图统计
        total = np.sum(self.histogram)
        max_bin = np.max(self.histogram)
        
        # 自适应量化参数
        quant_bits = self.q_width - np.ceil(np.log2(max_bin + 1))
        quant_bits = max(8, int(quant_bits))  # 最小8位
        
        # 精度损失估计
        precision_loss = (max_bin * total) / (self.q_width * 2)
        
        return {
            'importance': self.importance,
            'histogram': self.histogram.copy(),
            'quant_param': quant_bits,
            'precision_loss': precision_loss
        }
    
    def clear(self):
        """清空缓存"""
        self.buffer.clear()
        self.histogram.fill(0)
        self.importance = 0
        
    def get_stats(self) -> np.ndarray:
        """
        获取关键统计特征：
        - 最密集bin
        - 直方图标准差
        - 稀疏度
        """
        if len(self.buffer) == 0:
            return np.zeros(3, dtype=np.int32)
        
        # 最密集bin
        max_bin_idx = np.argmax(self.histogram)
        
        # 标准差（分布分散度）
        spread = np.std(self.histogram)
        
        # 稀疏度（零bin比例）
        sparse_rate = np.sum(self.histogram == 0) / self.hist_bins
        
        return np.array([max_bin_idx, spread, sparse_rate], dtype=np.int32)


class MomentumBasedSparse:
    """动量近似稀疏化器"""
    
    def __init__(self, q_width: int = 45, momentum_decay: float = 0.9):
        self.q_width = q_width
        self.momentum = 0.0
        self.momentum_decay = momentum_decay
        self.mask = []
        
    def update_momentum(self, coeff: int) -> float:
        """更新动量"""
        # 计算新系数的影响
        coeff_magnitude = np.abs(coeff)
        
        # 动量更新：M = decay * M + |c|
        self.momentum = self.momentum_decay * self.momentum + (coeff_magnitude / (2**(self.q_width-1)))
        
        # 更新掩码
        self.mask.append(self.momentum)
        
        # 关闭小系数
        if self.momentum < 0.1:
            return 0
        return coeff
    
    def clear(self):
        self.momentum = 0.0
        self.mask.clear()


def test_cipher_stat_probe():
    """测试密文域统计探针"""
    
    print("=" * 70)
    print("CIPHER-PU 密文域统计探针验证")
    print("=" * 70)
    
    # 创建一个统计探针
    probe = CipherStatProbe(q_width=7, stat_mode=3, hist_bins=16)  # 用较小的参数测试
    
    # 生成测试数据
    test_data = [1, 5, 3, 7, 2, 6, 4, 0, 1]
    
    print("\n测试数据:", test_data)
    
    # 处理每个系数
    for i, coeff in enumerate(test_data):
        importance, histogram = probe.process_coefficient(coeff)
        print(f"  Coeff {i}: {coeff}, Importance={importance:.3f}")
        print(f"    Histogram bin: {np.argmax(histogram)}")
    
    # 获取统计结果
    stats = probe.get_statistics()
    print("\n最终统计结果:")
    print(f"  重要性: {stats['importance']:.3f}")
    print(f"  量化参数: {stats['quant_param']} bits")
    print(f"  精度损失: {stats['precision_loss']:.3f}")
    
    # 测试动量稀疏化
    print("\n" + "-" * 70)
    print("动量稀疏化测试:")
    
    mps = MomentumBasedSparse(q_width=7, momentum_decay=0.9)
    for i, coeff in enumerate(test_data):
        adjusted = mps.update_momentum(coeff)
        print(f"  Coeff {i}: {coeff} -> {adjusted}")
    
    print("\n" + "=" * 70)
    print("测试完成")
    print("=" * 70)


if __name__ == "__main__":
    test_cipher_stat_probe()
