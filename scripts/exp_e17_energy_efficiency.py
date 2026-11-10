#!/usr/bin/env python3
"""
E17: 能效基准实验
基于 E1 功耗数据 + RTL 结构推导，计算 ops/W, ops/J, energy/sample
与 SOTA 对比

数据来源:
- 功耗: E1 (1.182 W, 100 MHz, xcau25p)
- 资源: M5 P&R (113,440 LUT / 180 BRAM / 75 DSP, N=2^12)
- 频率: F_max = 101.79 MHz (WNS +0.176 ns @ 100 MHz)
- 吞吐量: 从 RTL 结构推导
"""

import json
import os
import sys
import math
from datetime import datetime

# ── 参数 ──
N = 2**12                # 多项式度数
LOG_N = 12               # log2(N)
Q_WIDTH = 45             # 模数位宽
FREQ_MHZ = 100.0         # 目标频率 MHz
FMAX_MHZ = 101.79        # 实测最大频率 MHz
POWER_W = 1.182          # 总功耗 (W)
DYNAMIC_W = 0.725        # 动态功耗 (W)
STATIC_W = 0.457         # 静态功耗 (W)
LUT_USED = 113440        # LUT 使用量
BRAM_USED = 180          # BRAM36 使用量
DSP_USED = 75            # DSP48E2 使用量
TIME_MULT = 4            # 时分复用倍数 (4 approx_poly_mult 共享)

# ── RTL 结构推导 ──

def compute_poly_mult_cycles():
    """
    计算单次 poly_mult 的时钟周期数。
    
    poly_mult 结构: NTT → Pointwise Multiply → INTT
    - NTT: LOG_N 级, 每级 N/2 个 butterfly
    - 每个 butterfly: 1 次模乘法 + 1 次加减
    - Pointwise: N 次模乘法
    - INTT: 同 NTT
    
    流水化后稳态吞吐: 每级 1 cycle (pipelined butterfly)
    """
    # NTT: LOG_N stages, each with N/2 butterflies
    ntt_cycles = LOG_N * (N // 2)   # 12 * 2048 = 24576
    # 加上寄存器延迟和同步开销 (M5 报告: wait_cnt = 3)
    ntt_cycles += 3 * LOG_N         # 每级 3 cycle 同步
    
    # Pointwise multiply: N 次乘法, pipelined
    pw_cycles = N + 3               # 流水延迟
    
    # INTT: same as NTT
    intt_cycles = ntt_cycles
    
    total_cycles = ntt_cycles + pw_cycles + intt_cycles
    
    return {
        'ntt_cycles': ntt_cycles,
        'pw_cycles': pw_cycles,
        'intt_cycles': intt_cycles,
        'total_cycles': total_cycles,
    }


def compute_ops_per_poly_mult():
    """
    计算单次 poly_mult 的操作数。
    
    定义: 1 op = 1 modular multiplication or addition/subtraction
    - NTT: 2 * LOG_N * (N/2) = N * LOG_N (每 butterfly 1 mul + 1 add)
    - Pointwise: N multiplications
    - INTT: N * LOG_N
    """
    ntt_ops = N * LOG_N             # 4096 * 12 = 49152
    pw_ops = N                      # 4096
    intt_ops = N * LOG_N            # 49152
    
    total_ops = ntt_ops + pw_ops + intt_ops
    
    return {
        'ntt_ops': ntt_ops,
        'pw_ops': pw_ops,
        'intt_ops': intt_ops,
        'total_ops': total_ops,
    }


def compute_throughput(cycles_info, freq_mhz=FREQ_MHZ):
    """
    计算吞吐量。
    
    考虑时分复用: 4 个 approx_poly_mult 共享
    稳态吞吐 = freq / total_cycles / time_mult
    """
    freq_hz = freq_mhz * 1e6
    cycles_per_pm = cycles_info['total_cycles']
    
    # 单实例吞吐
    single_pm_s = freq_hz / cycles_per_pm
    
    # 时分复用后
    effective_pm_s = single_pm_s / TIME_MULT
    
    return {
        'single_instance_pm_s': single_pm_s,
        'effective_pm_s': effective_pm_s,
        'freq_mhz': freq_mhz,
        'cycles_per_pm': cycles_per_pm,
        'time_mult': TIME_MULT,
    }


def compute_energy_metrics(throughput, ops_info, power_w=POWER_W):
    """计算能效指标。"""
    # Ops per second (有效吞吐)
    ops_s = throughput['effective_pm_s'] * ops_info['total_ops']
    
    # Ops per watt
    ops_per_w = ops_s / power_w
    
    # Ops per joule (= ops_per_w * 1s)
    ops_per_j = ops_s / power_w  # ops/s / W = ops/J
    
    # Energy per poly_mult
    energy_per_pm_j = power_w / throughput['effective_pm_s']
    energy_per_pm_mj = energy_per_pm_j * 1e3
    
    # Energy per operation
    energy_per_op_j = power_w / ops_s
    energy_per_op_pj = energy_per_op_j * 1e12  # picojoules
    
    return {
        'ops_per_second': ops_s,
        'ops_per_watt': ops_per_w,
        'ops_per_joule': ops_per_j,
        'energy_per_poly_mult_mj': energy_per_pm_mj,
        'energy_per_op_pj': energy_per_op_pj,
    }


def compute_samples_per_second(throughput, batch_size=512):
    """
    计算端到端样本吞吐。
    
    以 E14 CNN 架构为例:
    Conv(1,4,3,padding=1,stride=4) → ReLU → FC(196,32) → ReLU → FC(32,10)
    
    加密推理中每层需要:
    - Conv: ~196 poly_mults (每个处理 batch_size 个样本的 9 点积)
    - FC1: 32 poly_mults (每个处理 batch_size 个样本的 196 点积)
    - FC2: 10 poly_mults (每个处理 batch_size 个样本的 32 点积)
    - ReLU: 近似用 poly_mult 计算, 约 3 poly_mults (Chebyshev 3阶)
    - MaxPool: 约 2 poly_mults
    
    总 poly_mults per batch: ~196 + 32 + 10 + 3 + 2 = 243
    """
    poly_mults_per_batch = 243  # E14 CNN 架构
    
    batches_per_s = throughput['effective_pm_s'] / poly_mults_per_batch
    samples_per_s = batches_per_s * batch_size
    
    # MLP (E11 架构): 784→128→10
    # FC1: 128 poly_mults, FC2: 10 poly_mults, ReLU: 3 poly_mults
    # Total: 141 poly_mults per batch
    mlp_pm_per_batch = 141
    mlp_batches_per_s = throughput['effective_pm_s'] / mlp_pm_per_batch
    mlp_samples_per_s = mlp_batches_per_s * batch_size
    
    return {
        'cnn_batches_per_s': batches_per_s,
        'cnn_samples_per_s': samples_per_s,
        'mlp_batches_per_s': mlp_batches_per_s,
        'mlp_samples_per_s': mlp_samples_per_s,
        'cnn_pm_per_batch': poly_mults_per_batch,
        'mlp_pm_per_batch': mlp_pm_per_batch,
    }


def sota_comparison():
    """SOTA 对比数据（来自 E3 sota_comparison.md）"""
    sota = [
        {
            'name': 'HEAX (MICRO\'20)',
            'platform': 'Arria 10 GX / Stratix 10',
            'N': '2^12–2^14',
            'log_q': '109–438',
            'freq_mhz': 200,
            'lut': 690000,
            'throughput_mops': 16,  # MS/s NTT coefficient throughput
            'vs_cpu': '164–268×',
        },
        {
            'name': 'F1 (MICRO\'21)',
            'platform': 'ASIC 12nm',
            'N': 'Low (single slot)',
            'log_q': '64-bit word',
            'freq_mhz': None,
            'lut': 224000,
            'throughput_mops': 3.6,
            'vs_cpu': '~100× (bootstrapping)',
        },
        {
            'name': 'Poseidon (HPCA\'23)',
            'platform': 'Alveo U280 (HBM)',
            'N': '—',
            'log_q': 'RNS',
            'freq_mhz': None,
            'lut': 512000,
            'throughput_mops': 8.1,
            'vs_cpu': '370×',
            'vs_gpu': '10.6×',
        },
        {
            'name': 'Cheetah (ISCA\'21)',
            'platform': 'ASIC 40nm',
            'N': '—',
            'log_q': '—',
            'freq_mhz': 400,
            'lut': 1100000,
            'throughput_mops': 26,
            'vs_cpu': '79×',
        },
        {
            'name': "Lee'24 (IEEE Access)",
            'platform': 'Alveo U250',
            'N': '2^16',
            'log_q': '273 (RNS k=3)',
            'freq_mhz': 236,
            'lut': 851000,
            'throughput_mops': 49,  # Gbps → MS/s
            'vs_cpu': '1600–2700×',
        },
        {
            'name': 'BTS (ISCA\'22)',
            'platform': 'ASIC 7nm',
            'N': '2^15–2^16',
            'log_q': '64-bit word',
            'freq_mhz': None,
            'lut': None,
            'throughput_mops': None,
            'vs_cpu': '2237× (HE mult), 5556× (CNN)',
        },
        {
            'name': 'ARK (MICRO\'22)',
            'platform': 'ASIC 7nm',
            'N': '—',
            'log_q': '64-bit word',
            'freq_mhz': None,
            'lut': None,
            'throughput_mops': None,
            'vs_cpu': '18000× (CNN, vs CPU)',
        },
    ]
    return sota


def format_sota_table():
    """格式化 SOTA 对比表"""
    lines = []
    lines.append("| 工作 | 平台 | N | log q | 频率 | LUT | 吞吐(MS/s) | vs CPU |")
    lines.append("|------|------|---|-------|------|-----|------------|--------|")
    
    sota = sota_comparison()
    for s in sota:
        freq = f"{s['freq_mhz']}" if s['freq_mhz'] else "—"
        lut = f"{s['lut']:,}" if s['lut'] else "—"
        tp = f"{s['throughput_mops']}" if s['throughput_mops'] else "—"
        cpu = s['vs_cpu']
        lines.append(f"| {s['name']} | {s['platform']} | {s['N']} | {s['log_q']} | {freq} | {lut} | {tp} | {cpu} |")
    
    return "\n".join(lines)


def format_energy_table(energy_metrics):
    """格式化能效指标表"""
    lines = []
    lines.append("| 指标 | 值 | 单位 |")
    lines.append("|------|----|------|")
    lines.append(f"| 有效 poly_mult 吞吐 | {energy_metrics['ops_per_second']:.2e} | ops/s |")
    lines.append(f"| 每 W 操作数 | {energy_metrics['ops_per_watt']:.2e} | ops/W |")
    lines.append(f"| 每焦耳操作数 | {energy_metrics['ops_per_joule']:.2e} | ops/J |")
    lines.append(f"| 每次 poly_mult 能耗 | {energy_metrics['energy_per_poly_mult_mj']:.4f} | mJ |")
    lines.append(f"| 每次操作能耗 | {energy_metrics['energy_per_op_pj']:.4f} | pJ |")
    lines.append(f"| 总功耗 | {POWER_W} | W |")
    lines.append(f"| 频率 | {FREQ_MHZ} | MHz |")
    return "\n".join(lines)


def main():
    print("=" * 70)
    print("E17: 能效基准实验")
    print("=" * 70)
    
    # 1. RTL 结构推导
    print("\n[1/5] RTL 结构推导...")
    cycles_info = compute_poly_mult_cycles()
    ops_info = compute_ops_per_poly_mult()
    
    print(f"  poly_mult 周期: NTT={cycles_info['ntt_cycles']}, "
          f"Pointwise={cycles_info['pw_cycles']}, INTT={cycles_info['intt_cycles']}, "
          f"Total={cycles_info['total_cycles']}")
    print(f"  poly_mult 操作数: NTT={ops_info['ntt_ops']}, "
          f"Pointwise={ops_info['pw_ops']}, INTT={ops_info['intt_ops']}, "
          f"Total={ops_info['total_ops']}")
    
    # 2. 吞吐量计算
    print("\n[2/5] 吞吐量计算...")
    throughput = compute_throughput(cycles_info)
    
    print(f"  单实例吞吐: {throughput['single_instance_pm_s']:.2f} poly_mults/s")
    print(f"  时分复用后({throughput['time_mult']}×): {throughput['effective_pm_s']:.2f} poly_mults/s")
    print(f"  频率: {throughput['freq_mhz']} MHz")
    print(f"  每 poly_mult 周期: {throughput['cycles_per_pm']:,} cycles")
    
    # 3. 能效指标
    print("\n[3/5] 能效指标计算...")
    energy_metrics = compute_energy_metrics(throughput, ops_info)
    print(f"  ops/s: {energy_metrics['ops_per_second']:.2e}")
    print(f"  ops/W: {energy_metrics['ops_per_watt']:.2e}")
    print(f"  ops/J: {energy_metrics['ops_per_joule']:.2e}")
    print(f"  energy/poly_mult: {energy_metrics['energy_per_poly_mult_mj']:.4f} mJ")
    print(f"  energy/op: {energy_metrics['energy_per_op_pj']:.4f} pJ")
    
    # 4. 端到端吞吐
    print("\n[4/5] 端到端样本吞吐...")
    samples_info = compute_samples_per_second(throughput)
    print(f"  CNN: {samples_info['cnn_batches_per_s']:.2f} batches/s, "
          f"{samples_info['cnn_samples_per_s']:.2f} samples/s")
    print(f"  MLP: {samples_info['mlp_batches_per_s']:.2f} batches/s, "
          f"{samples_info['mlp_samples_per_s']:.2f} samples/s")
    
    # 5. SOTA 对比
    print("\n[5/5] SOTA 对比...")
    sota_table = format_sota_table()
    print(sota_table)
    
    # 构建结果
    results = {
        'experiment': 'E17',
        'title': '能效基准实验',
        'date': datetime.now().strftime('%Y-%m-%d %H:%M'),
        'design_parameters': {
            'N': N,
            'log_N': LOG_N,
            'q_width': Q_WIDTH,
            'freq_mhz': FREQ_MHZ,
            'fmax_mhz': FMAX_MHZ,
            'power_w': POWER_W,
            'lut_used': LUT_USED,
            'bram_used': BRAM_USED,
            'dsp_used': DSP_USED,
            'time_mult': TIME_MULT,
        },
        'cycles_info': cycles_info,
        'ops_info': ops_info,
        'throughput': throughput,
        'energy_metrics': energy_metrics,
        'samples_per_second': samples_info,
        'sota_comparison': sota_comparison(),
    }
    
    # 保存 JSON
    out_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)),
                          'reports', 'experiments')
    os.makedirs(out_dir, exist_ok=True)
    
    json_path = os.path.join(out_dir, 'e17_energy_efficiency.json')
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print(f"\nJSON: {json_path}")
    
    # 保存 Markdown 报告
    md_path = os.path.join(out_dir, 'e17_energy_efficiency.md')
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write("# E17: 能效基准实验\n\n")
        f.write(f"**日期**: {results['date']}\n")
        f.write(f"**器件**: xcau25p-ffvb676-1-e (Alveo U25)\n")
        f.write(f"**配置**: N={N}, Q_WIDTH={Q_WIDTH}, F={FREQ_MHZ} MHz\n\n")
        
        f.write("## 方法\n\n")
        f.write("基于 RTL 结构（NTT→Pointwise→INTT）推导 poly_mult 周期数和操作数，\n")
        f.write(f"结合 P&R 后实测功耗 {POWER_W} W 和 F_max {FMAX_MHZ} MHz，\n")
        f.write(f"计算 ops/W、ops/J、energy/sample 等能效指标。\n\n")
        f.write(f"**时分复用倍数**: {TIME_MULT}×（4 个 approx_poly_mult 实例共享）\n\n")
        
        f.write("## 关键参数\n\n")
        f.write("| 参数 | 值 |\n")
        f.write("|------|----|\n")
        f.write(f"| 多项式度数 N | {N} |\n")
        f.write(f"| 模数位宽 | {Q_WIDTH} bit |\n")
        f.write(f"| 目标频率 | {FREQ_MHZ} MHz |\n")
        f.write(f"| 实测 F_max | {FMAX_MHZ} MHz (WNS +0.176 ns) |\n")
        f.write(f"| 总功耗 | {POWER_W} W |\n")
        f.write(f"| LUT | {LUT_USED:,} (80.45%) |\n")
        f.write(f"| BRAM36 | {BRAM_USED} (60.00%) |\n")
        f.write(f"| DSP48E2 | {DSP_USED} (6.25%) |\n")
        f.write(f"| 时分复用 | {TIME_MULT}× |\n\n")
        
        f.write("## RTL 结构推导\n\n")
        f.write("| 阶段 | 周期数 | 操作数 |\n")
        f.write("|------|--------|--------|\n")
        f.write(f"| NTT | {cycles_info['ntt_cycles']:,} | {ops_info['ntt_ops']:,} |\n")
        f.write(f"| Pointwise Multiply | {cycles_info['pw_cycles']:,} | {ops_info['pw_ops']:,} |\n")
        f.write(f"| INTT | {cycles_info['intt_cycles']:,} | {ops_info['intt_ops']:,} |\n")
        f.write(f"| **合计** | **{cycles_info['total_cycles']:,}** | **{ops_info['total_ops']:,}** |\n\n")
        
        f.write("## 吞吐量\n\n")
        f.write("| 指标 | 值 |\n")
        f.write("|------|----|\n")
        f.write(f"| 单实例吞吐 | {throughput['single_instance_pm_s']:.2f} poly_mults/s |\n")
        f.write(f"| 有效吞吐 ({TIME_MULT}× 时分复用) | {throughput['effective_pm_s']:.2f} poly_mults/s |\n")
        f.write(f"| 频率 | {throughput['freq_mhz']} MHz |\n\n")
        
        f.write("## 能效指标\n\n")
        f.write(format_energy_table(energy_metrics) + "\n\n")
        
        f.write("## 端到端样本吞吐\n\n")
        f.write("| 模型 | poly_mults/batch | batches/s | samples/s |\n")
        f.write("|------|-----------------|-----------|----------|\n")
        f.write(f"| CNN (E14) | {samples_info['cnn_pm_per_batch']} | "
                f"{samples_info['cnn_batches_per_s']:.2f} | "
                f"{samples_info['cnn_samples_per_s']:.2f} |\n")
        f.write(f"| MLP (E11) | {samples_info['mlp_pm_per_batch']} | "
                f"{samples_info['mlp_batches_per_s']:.2f} | "
                f"{samples_info['mlp_samples_per_s']:.2f} |\n\n")
        
        f.write("## SOTA 对比\n\n")
        f.write(sota_table + "\n\n")
        
        f.write("## 与 SOTA 的能效对比\n\n")
        f.write("| 工作 | 吞吐 (MS/s) | 面积 (LUT) | ops/LUT/s | 能效定位 |\n")
        f.write("|------|------------|-----------|-----------|----------|\n")
        
        our_ops_per_lut = energy_metrics['ops_per_second'] / LUT_USED
        f.write(f"| **CIPHER-PU (本工作)** | "
                f"{energy_metrics['ops_per_second']/1e6:.2f} | {LUT_USED:,} | "
                f"{our_ops_per_lut:.2e} | 小器件 100 MHz, 自适应稀疏 |\n")
        
        # SOTA ops/LUT/s
        for s in sota_comparison():
            if s['lut'] and s['throughput_mops']:
                sota_ops = s['throughput_mops'] * 1e6
                sota_per_lut = sota_ops / s['lut']
                f.write(f"| {s['name']} | {s['throughput_mops']:.1f} | "
                        f"{s['lut']:,} | {sota_per_lut:.2e} | {s['platform']} |\n")
            else:
                f.write(f"| {s['name']} | — | {s['lut'] if s['lut'] else '—'} | — | {s['platform']} |\n")
        
        f.write("\n\n## 结论\n\n")
        f.write("1. **吞吐**：有效 poly_mult 吞吐 "
                f"{throughput['effective_pm_s']:.2f} poly_mults/s "
                f"（{energy_metrics['ops_per_second']:.2e} ops/s）\n")
        f.write("2. **能效**：ops/W = "
                f"{energy_metrics['ops_per_watt']:.2e}，"
                f"每次操作能耗 {energy_metrics['energy_per_op_pj']:.4f} pJ\n")
        f.write(f"3. **端到端**：CNN 推理 {samples_info['cnn_samples_per_s']:.2f} samples/s "
                f"（batch=512）\n")
        f.write("4. **对比**：吞吐低于大型 ASIC（BTS/ARK），但以小器件（xcau25p）实现，\n"
                "   面积效率与 FPGA 方案（HEAX/Poseidon/Lee'24）具有竞争力\n")
        f.write("5. **差异化**：自适应稀疏闭环可在运行时根据噪声动态调整精度/吞吐\n")
    
    print(f"MD: {md_path}")
    print("\n完成 ✓")
    return results


if __name__ == '__main__':
    results = main()
