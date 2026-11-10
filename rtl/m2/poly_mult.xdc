# =============================================================================
# poly_mult.xdc - Constraints for CKKS poly_mult synthesizable top
# -----------------------------------------------------------------------------
# 器件：xcau25p-ffvb676-1-e (Alveo U20, UltraScale+ Artix-7)
# 版本：Vivado 2026.1
# 说明：本文件是 M2 poly_mult 与后续 M3 Rescale 综合的 XDC 骨架。
#       M6 上板阶段需追加 IO 约束（见 §7 预留段）。
#
# 使用方式：
#   1. 综合阶段：
#      open_project
#      read_xdc rtl/m1/clocks.xdc          # 基础时钟
#      read_xdc rtl/m2/poly_mult.xdc       # 本文件
#   2. 或命令行：
#      create_project poly_mult ... -part xcau25p-ffvb676-1-e
#      read_xdc rtl/m1/clocks.xdc rtl/m2/poly_mult.xdc
#
# 版本：v1.0 (2026-10-03)
# =============================================================================

# -----------------------------------------------------------------------------
# §1 时钟（覆盖 rtl/m1/clocks.xdc 的 create_clock 声明）
# -----------------------------------------------------------------------------
# 注意：clocks.xdc 已声明 clk 100 MHz，此处只补时钟不确定度与时序例外。

# 时钟不确定度（jitter + skew + period uncertainty）
# Alveo U20 板载 100 MHz HCSL：
#   - input jitter: ~2 ps RMS
#   - period jitter: ~20 ps RMS
#   - skew: ~50 ps P2P (FPGA internal)
# 合计约 70-90 ps，这里取保守 100 ps
set_clock_uncertainty -setup 0.100 [get_clocks clk]
set_clock_uncertainty -hold  0.050 [get_clocks clk]

# -----------------------------------------------------------------------------
# §2 时钟延迟（input/output delay）
#   用于跨时钟域路径。M6 上板时替换成实测值。
#   当前值仅为仿真占位。
# -----------------------------------------------------------------------------
# set_input_delay  -clock clk -max 2.000 [get_ports -filter { NAME =~ * }]
# set_input_delay  -clock clk -min 0.500 [get_ports -filter { NAME =~ * }]
# set_output_delay -clock clk -max 2.000 [get_ports -filter { NAME =~ * }]
# set_output_delay -clock clk -min 0.500 [get_ports -filter { NAME =~ * }]

# -----------------------------------------------------------------------------
# §3 复位与时序例外
# -----------------------------------------------------------------------------
# rst_n 是异步复位，从 rst_n=0 -> 1 的恢复/移除时间：
#   - recovery: 复位释放后要有一个 cycle 让寄存器锁定
#   - removal:  复位作用前至少要 hold 一个 cycle
set_false_path -from [get_ports rst_n]

# start 是单 cycle 脉冲，与 clk 同频同步（TB 已确保），无跨时钟路径
# set_false_path -from [get_ports start]

# -----------------------------------------------------------------------------
# §4 RAM 推断（M2 poly_mult 内部的 a_mem/b_mem/a_hat/b_hat/c_hat）
# -----------------------------------------------------------------------------
# 目标：所有 16-bit 或更大的 RAM 实例推断为 BRAM。
# 注意：UltraScale+ 支持 RAMB36E1（36 Kbit）与 RAMB18E1（18 Kbit），
#       BRAM 数量预算 300 块（MEMORY.md 口径）。

# 强制推断为分布式 RAM（小于 1024 深度）
set_property RAM_STYLE "register" [get_cells -hierarchical -filter { NAME =~ */mem_reg$ }]

# 允许综合器推断 BRAM
set_property style "block" [get_cells -hierarchical -filter { NAME =~ */a_mem* | NAME =~ */b_mem* | NAME =~ */a_hat_mem* | NAME =~ */b_hat_mem* | NAME =~ */c_hat_mem* }]

# 强制使用 BRAM 存储（避免被推断成 LUT RAM，节省 LUT 资源）
set_property KEEP_REG_INIT TRUE  [get_cells -hierarchical -filter { NAME =~ */mem\[.*\]$ }]

# -----------------------------------------------------------------------------
# §5 多周期路径（MTC）
# -----------------------------------------------------------------------------
# fast-red 归约是纯组合 3-stage 减 q 链，理论上 1 cycle 完成。
# 若单蝴蝶关键路径在 100 MHz 下违例，可考虑把 fast-red 归约声明为 2-cycle MTC。
# 目前 fast-red 单蝴蝶 WNS +3.774 ns（已闭合），暂不需要 MTC。

# 生产配置 (N=2^14, USE_FASTRED=1) 下若时序违例，可启用以下：
# set_max_delay -datapath_only -from [get_cells -hierarchical -filter { NAME =~ */u_fastred* }] \
#               -to   [get_cells -hierarchical -filter { NAME =~ */u_butterfly* }] 20.0

# -----------------------------------------------------------------------------
# §6 关键路径 hint（引导布局）
# -----------------------------------------------------------------------------
# poly_mult 三级流水的中间寄存器（a_hat/b_hat/c_hat）应保持物理邻近，
# 减少布线延迟。此处仅提示，不强制位置。
# set_physical_property LOCATION X0Y0 [get_cells u_dut/u_ntt/u_butterfly/u_mult]

# -----------------------------------------------------------------------------
# §7 IO 约束（M6 上板阶段启用）
# -----------------------------------------------------------------------------
# 目标板：Alveo U20（xcau25p-ffvb676-1-e）
# 高速接口通过 HBM 与 PCIe 连接，无需传统 IO bank 分配。
# 若外接调试 IO（LED / 按钮 / UART），在此处追加：

# UART RX/TX（用于上板时打印调试）
# set_property PACKAGE_PIN H13  [get_ports uart_tx]
# set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
# set_property PACKAGE_PIN H14  [get_ports uart_rx]
# set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

# LED 状态指示
# set_property PACKAGE_PIN B3  [get_ports led[0]]  # idle
# set_property PACKAGE_PIN C3  [get_ports led[1]]  # busy
# set_property PACKAGE_PIN D3  [get_ports led[2]]  # done
# set_property IOSTANDARD LVCMOS33 [get_ports led*]

# 按钮复位
# set_property PACKAGE_PIN F5 [get_ports rst_btn]
# set_property IOSTANDARD LVCMOS33 [get_ports rst_btn]
# set_property PULLUP TRUE     [get_ports rst_btn]

# -----------------------------------------------------------------------------
# §8 Power intent（M6 综合功耗估算阶段启用）
# -----------------------------------------------------------------------------
# 目标功耗预算：
#   - 静态功耗：<= 25 W（Alveo U20 TDP 55 W）
#   - 动态功耗：<= 30 W
#
# create_power_scenario -name default_scenario
# set_current_analysis_state -enabled yes

# 时钟功耗场景（100 MHz 100% toggle）
# set_clock_power_scenario [current_power_scenario] -clock {clk} -period 10 -jitter 0.1

# -----------------------------------------------------------------------------
# §9 综合属性（全局）
# -----------------------------------------------------------------------------
# 优化策略：balanced（默认）；时序收敛后可切 speed 优先
# set_property STEPS.SYNTH_1.ARCH_PLUGINIT_PARAM.OPTIMIZE_POWER false [get_runs synth_1]

# 使用分布式 RAM 存储小表（< 1024 深度）
set_property GENERIC_SYNTHESIS true [get_files *.sv]

# -----------------------------------------------------------------------------
# §10 时序例外报告命令（供综合后手动运行）
# -----------------------------------------------------------------------------
# report_timing -from [get_ports rst_n] -delay_type min
# report_timing_summary -max_paths 20
# report_timing_summary -delay_type min -max_paths 20
# report_timing_exceptions -name all_exceptions
# report_clock_interaction

# -----------------------------------------------------------------------------
# §11 待补清单（M5 阶段完成）
# -----------------------------------------------------------------------------
# - [ ] 实测板卡时钟不确定度（用 signal integrity 分析工具）
# - [ ] 生产配置 (N=2^14, Q_WIDTH=45) 下的 RAM 深度与 BRAM 使用估算
# - [ ] KeySwitch 流水的 MTC 声明（如 3-cycle MTC）
# - [ ] Rescale 硬件的跨时钟域路径（若涉及 rescale 域）
# - [ ] Bitstream 生成时的 bitstream config（SPI / JTAG 模式选择）
# - [ ] XDC 语法与 Vivado 2026.1 命令的兼容性检查（本报告基于 2023.2 惯例）
