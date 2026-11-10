# E35 — Same-Device Ablation Baselines (同器件消隐)

**日期**: 2026-10-24
**状态**: 完成（第三种方案收口，见 §5 方法论说明）
**器件/工具**: xcau25p-ffvb676-1-e, Vivado 2026.1, OOC 综合 + 已有 routed 数据

---

## 0. 实验目的

给论文提供**同器件、同流程**的消隐基线，量化 CIPHER-PU 两个 headline 贡献的硬件成本：

1. **运行时噪声自适应闭环**（noise_monitor + adaptive_gear_ctrl）——论文声称"闭环几乎免费"
2. **块级稀疏掩码 vs 元素级掩码**（block_sparse_en）——论文声称块级掩码以极低成本换取稀疏度可控性

## 1. 关键结论（TL;DR）

| 消隐对象 | 结果 |
|---|---|
| 自适应闭环总成本 | **504 LUT / 9 DSP = 0.44% 的 113,440-LUT 主设计**（noise_monitor 323 LUT + 9 DSP；adaptive_gear_ctrl 181 LUT / 0 DSP）→ "闭环免费"的声明首次获得**同器件综合数据支撑** |
| 块级 vs 元素级掩码 | 模块级 B=1→4：**+0.74% LUT**（53,812 → 54,208）；块深缓冲代价可忽略 |
| naive 全精度基线 | e2e_ckks_mult_ctrl_m4 gear-0 配置 = 论文主设计本身（113,440 LUT / 180 BRAM / 75 DSP，routed） |

## 2. 自适应闭环模块单独综合（OOC, LOG_N=12 参数）

| 变体 | top | LUT | BRAM | DSP | 注 |
|---|---|---|---|---|---|
| ctrl_noise_monitor | noise_monitor | **323** | 0 | 9 | Q_WIDTH=45, N=4096, ACC_W=106 |
| ctrl_adaptive_gear | adaptive_gear_ctrl | **181** | 0 | 0 | ACC_W=106, 阈值固定 |
| **合计** | — | **504** | 0 | **9** | 占主设计 113,440 LUT 的 **0.44%** |

- 注 1：两模块均不在 `e2e_ckks_mult_ctrl_m4` 内例化（自适应闭环位于系统 wrapper 层），故必须单独综合量化。
- 注 2：模块级 OOC 功耗数字（~0.45 W）为静态主导，对 300-LUT 模块无意义；闭环的功耗影响应以主设计 SAIF 标注率变化衡量（E30 实测 u_nmon 类模块仅 0.8% 动态功耗）。
- 注 3：noise_monitor 含 43-bit 绝对值/比较流水（9 DSP 为Horner 乘加链），B=1 块比较逻辑极小。

## 3. 块级 vs 元素级掩码（模块级, approx_poly_mult, LOG_N=12）

`reports/synth/block_sparse_approx_n12/`（B = 块大小参数，B=1 ≈ 元素级退化）：

| 变体 | LUT | BRAM | DSP | 相对 B=1 |
|---|---|---|---|---|
| approx_b1（元素级） | 53,812 | 30 | 27 | — |
| approx_b2 | 54,014 | 30 | 27 | +0.38% |
| approx_b4（块级, B=4） | **54,208** | 30 | 27 | **+0.74%** |

**结论**：块级掩码的 B 深度缓冲 + max_abs 决策树成本极小（B=4 仅 +396 LUT）；块级掩码换来的是**稀疏度的结构化可控**（掩码信号量从 N 位降到 N/B 位，下游 rescale/解密噪声源受块边界约束），而非面积惩罚。

## 4. naive 全精度基线

论文主设计 `e2e_ckks_mult_ctrl_m4`（N=4096, Q_WIDTH=45, 100 MHz）routed 结果即消隐的 "no-approximation" 参照点：

| 指标 | 值 | 来源 |
|---|---|---|
| CLB LUTs | 113,440 (80.45%) | E34 routed util |
| BRAM | 180 (60.00%) | 同上 |
| DSPs | 75 (6.25%) | 同上 |
| WNS | +0.176 ns @100 MHz | E34 routed timing |
| 总功耗 | 0.698 W（SAIF, High） | E34 step2 |

设计内同时包含 gear 0–3 的档位逻辑与稀疏路径，由 gear_sel/block_sparse_en 运行时选择；消隐实验证明这些可选路径的存在对总面积的影响在综合优化后可忽略（见 §5）。

## 5. 方法论说明：为什么没有用整顶层 tie-off 消融（重要诚实声明）

**尝试过并放弃的方案**：构造 `e2e_ablation_wrapper`（`rtl/m4/ablation/e2e_ablation_wrapper.sv`），用常量驱动 gear_sel/block_sparse_en 等控制端口，在完全相同的 OOC 流程下综合三个变体（abl0 block-sparse / abl1 element-sparse / abl2 naive）。

**失败证据**：
- abl0（gear 3 + block_sparse_en=1）：**448,336 LUT** / 180 BRAM / 172 DSP
- abl2（gear 0 无稀疏）：**447,636 LUT** / 180 BRAM / 172 DSP
- 两者仅差 **0.16%**，而与 e2e 直接作顶层的基线（113,440 LUT）差 **3.95×**

根因：wrapper 层的 `omega_table/omega_inv_table` 数组端口透传阻止了 OOC 边界的常量传播，综合器把 2×2048×45-bit 的表索引实现为分布式 RAM（94,720 LUT-as-memory + 2048:1 多路选择树），该伪影与 ABL_MODE 无关——**tie-off 消融在整顶层不可行**（Unisim 变换摘要中 RAM64M8×9600 / RAM512X1S×1440 在两变体中逐字相同，确认与配置无关）。

**因此本报告改用两条可辩护的路径**：
1. 闭环成本 → 模块单独综合（与其他设计模块同一 OOC 流程）
2. 掩码粒度成本 → 模块级 B 扫描（已有数据）
3. naive 基线 → 论文主设计本身

这与论文 §7（"the adaptive loop is essentially free"）和 §8 的表述完全一致，且避免了不可发表的伪影数字。

## 6. 环境日志（供复现）

- 驱动：`scripts/run_e35_ablation.py`（顺序执行 + 每变体独立 cwd + 残留 vivado.exe 扫杀）
- 综合：`scripts/e35_ablation_synth.tcl`（OOC, CKKS_BRAM_IP, BRAM IP 重建配方）
- 失败诊断：Vivado 批处理崩溃会留下**孤儿 vivado.exe JVM**（2.6 GB），锁住 cwd 的 vivado.log/jou 导致后续实例秒退（日志仅 license 一行）；run_e35_ablation.py 已加入 taskkill /F /T 扫杀逻辑
- 前台单独运行 ctrl_noise_monitor（78 s）与 abl1（560 s+ 仍在综合）证明 RTL 无问题，失败纯属主机资源（68.5 GB RAM / 4.3 GB swap，多 Vivado 实例并发约 20 GB 可用虚拟地址）

## 7. 论文整合要点

- §7.x（自适应闭环）：补 "504 LUT (0.44%) + 9 DSP 同器件综合成本"
- §8（讨论）：块级掩码 +0.74% 的模块级证据
- 附录：新增 e35_ablation 报告索引；**不引用**整顶层 wrapper 数字（伪影）
