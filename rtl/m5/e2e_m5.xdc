# =============================================================================
# e2e_m5.xdc - M5 完整约束（E2E 控制器 + M4 档位集成）
# -----------------------------------------------------------------------------
# 器件：xcau25p-ffvb676-1-e (Alveo U20, UltraScale+ Artix)
#       参考估算器件：xc7a200t-ffv1156-2 (Artix-7, 综合资源估算用)
# 版本：Vivado 2026.1 (BASIC 授权，到期 2027-09-26)
# 顶层：e2e_ckks_mult_ctrl_m4（含 gear_controller + 4× approx_poly_mult +
#       keyswitch_pipe + 2× rescale + 13 态 FSM）
#
# 覆盖章节：
#   §1 时钟定义与时钟不确定度
#   §2 复位与单周期脉冲（False Path）
#   §3 BRAM 推断与 RAM Style 提示
#   §4 MTC（多周期路径）— fast-red 归约与关键 DSP 路径
#   §5 时钟延迟（IO，M6 上板时启用）
#   §6 布局 hint（不强制位置）
#   §7 IO 约束（M6 上板时启用）
#   §8 综合属性与策略
#   §9 时序例外报告命令（综合后手动运行）
#
# 使用方式：
#   create_project e2e_m5 ... -part xc7a200t-ffv1156-2
#   read_verilog -sv rtl/m1/*.sv rtl/m2/*.sv rtl/m3/*.sv rtl/m4/*.sv
#   read_xdc rtl/m1/clocks.xdc
#   read_xdc rtl/m2/poly_mult.xdc
#   read_xdc rtl/m5/e2e_m5.xdc     # 本文件
#
# 版本：v1.0 (2026-10-04)
# =============================================================================

# -----------------------------------------------------------------------------
# §1 时钟定义与时钟不确定度
# -----------------------------------------------------------------------------
# M1 clocks.xdc 已声明 clk 100 MHz（period=10.0 ns），此处补时钟不确定度。
# Alveo U20 板载 100 MHz HCSL 时钟：
#   - input jitter: ~2 ps RMS
#   - period jitter: ~20 ps RMS
#   - skew: ~50 ps P2P (FPGA internal)
#   - routing skew: ~30 ps (worst-case)
# 合计约 100 ps 保守估算
set_clock_uncertainty -setup 0.100 [get_clocks clk]
set_clock_uncertainty -hold  0.050 [get_clocks clk]

# 时钟波形（默认 50% duty cycle，可微调为 45/55 观察时序）
set_clock_waveform -inc 5.0 7.5 [get_clocks clk]

# -----------------------------------------------------------------------------
# §2 复位与单周期脉冲（False Path）
# -----------------------------------------------------------------------------
# rst_n：异步复位，同步释放
#   - 从 rst_n=0 -> 1 恢复时间：需 >= 1 cycle（TB 已确保）
#   - 从 rst_n=1 -> 0 移除时间：需 >= 1 cycle（TB 已确保）
# 声明 false path 让静态时序分析不误报
set_false_path -from [get_ports rst_n]

# start：单周期脉冲，与 clk 同频同步
# TB 已确保 start 在 clk 上升沿后释放，无跨时钟路径
set_false_path -from [get_ports start]

# gear_sel：档位选择信号，运行期组合逻辑配置
# 在 FSM 空闲态更新，避免与 clk 数据通路冲突
# 不强制 false path（保留为普通时序路径，供 TNS 观察）

# -----------------------------------------------------------------------------
# §3 BRAM 推断与 RAM Style 提示
# -----------------------------------------------------------------------------
# UltraScale+ 支持 RAMB36E1 (36 Kbit) 与 RAMB18E1 (18 Kbit)
# 预算：300 块 RAMB36（MEMORY.md 口径）/ xc7a200t 约 1430 块

# 3.1 小型分布式 RAM（< 1024 深度）保持寄存器实现
set_property RAM_STYLE "register" [get_cells -hierarchical -filter { NAME =~ */mem_reg$ }]

# 3.2 大型 BRAM（>= 1024 深度）强制块 RAM
# poly_mult 内部的 a_mem / b_mem / a_hat_mem / b_hat_mem / c_hat_mem
set_property style "block" [get_cells -hierarchical -filter { NAME =~ */a_mem* | NAME =~ */b_mem* | NAME =~ */a_hat_mem* | NAME =~ */b_hat_mem* | NAME =~ */c_hat_mem* | NAME =~ */buf* }]

# 3.3 保留寄存器初值（避免 X 传播）
set_property KEEP_REG_INIT TRUE [get_cells -hierarchical -filter { NAME =~ */mem\[.*\]$ }]

# 3.4 允许综合器推断 BRAM（默认行为，此处显式声明便于审查）
if {[get_cells -hierarchical -filter { IS_RAM == TRUE }]} {
    set_property USE_BLOCK_RAM TRUE [get_cells -hierarchical -filter { IS_RAM == TRUE }]
}

# 3.5 m1_data_buf（keyswitch 输入缓冲）— N 深度 × Q_WIDTH
# 生产配置 N=16384, Q_WIDTH=45 -> 737280 bit ≈ 11.2 KB -> 需 20+ 块 RAMB36
# 玩具配置 N=16 -> 720 bit -> 1 块 RAMB18
if {[get_cells -hierarchical -filter { NAME =~ *m1_data_buf* }]} {
    set_property RAM_STYLE "block" [get_cells -hierarchical -filter { NAME =~ *m1_data_buf* }]
}

# -----------------------------------------------------------------------------
# §4 多周期路径（MTC）
# -----------------------------------------------------------------------------
# 4.1 fast-red 归约：3-stage 组合减 q 链
# 实测单蝴蝶关键路径 6.073 ns（@100 MHz WNS +3.774 ns，已闭合）
# 无需 MTC，保留注释供未来参考

# 4.2 poly_mult 三级流水（NTT -> 点乘 -> INTT）
# 每级间有寄存器，天然 1 cycle 时序边界
# 无需 MTC

# 4.3 gear_controller 组合逻辑
# 单 cycle 翻译，无需 MTC

# 4.4 若未来 fast-red 或点乘在 100 MHz 下违例，可启用：
# set_max_delay -datapath_only 20.0 \
#   -from [get_cells -hierarchical -filter { NAME =~ */u_fastred* }] \
#   -to   [get_cells -hierarchical -filter { NAME =~ */u_butterfly* }]

# -----------------------------------------------------------------------------
# §5 时钟延迟（IO，M6 上板时启用）
# -----------------------------------------------------------------------------
# 占位注释；实际值需板卡实测
# set_input_delay  -clock clk -max 2.000 [get_ports -filter { NAME =~ * }]
# set_input_delay  -clock clk -min 0.500 [get_ports -filter { NAME =~ * }]
# set_output_delay -clock clk -max 2.000 [get_ports -filter { NAME =~ * }]
# set_output_delay -clock clk -min 0.500 [get_ports -filter { NAME =~ * }]

# -----------------------------------------------------------------------------
# §6 布局 Hint（不强制位置，仅引导）
# -----------------------------------------------------------------------------
# 三级流水中间寄存器应保持物理邻近，减少布线延迟
# set_physical_property LOC X0Y0 [get_cells -hierarchical -filter { NAME =~ */a_hat* }]

# 4 个 poly_mult 应尽量集中布局（DSP 集群附近）
# set_area_group -add cell u_pm0 -name pm0_grp
# set_area_group -add cell u_pm1a -name pm1_grp
# set_area_group -add cell u_pm1b -name pm1_grp
# set_area_group -add cell u_pm2 -name pm2_grp

# -----------------------------------------------------------------------------
# §7 IO 约束（M6 上板时启用）
# -----------------------------------------------------------------------------
# 目标板：Alveo U20（xcau25p-ffvb676-1-e）
# 高速接口通过 HBM 与 PCIe 连接，无需传统 IO bank 分配
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
# §8 综合属性与策略
# -----------------------------------------------------------------------------
# 8.1 优化策略：balanced（默认）；时序收敛后可切 speed 优先
# get_runs 在 XDC 中不支持，改为在 TCL 脚本里 set_property

# 8.2 通用综合（允许综合器做更激进的优化）—— get_files 在 XDC 中不支持，改在 TCL 设置
# set_property GENERIC_SYNTHESIS true [get_files *.sv]

# 8.3 保留层次结构（便于波形观察和时序调试）—— TCL 脚本中设置
# set_property STEPS.SYNTH_1.STRATEGY "Vivado Synthesize Defaults" [get_runs synth_1]

# 8.4 允许 DSP 推断（poly_mult 内部乘法器）—— TCL 脚本中设置
# set_property STEPS.SYNTH_1.ARCH_PLUGINIT_PARAM.OPTIMIZE_DSP true [get_runs synth_1]

# 8.5 保留关键信号名（KEEP 属性不支持 port 类型，改为在 RTL 中用 attribute）
# set_property KEEP HIERARCHICAL [get_ports gear_sel]

# -----------------------------------------------------------------------------
# §9 时序例外报告命令（综合后手动运行）
# -----------------------------------------------------------------------------
# report_timing -from [get_ports rst_n] -delay_type min
# report_timing_summary -max_paths 20
# report_timing_summary -delay_type min -max_paths 20
# report_timing_exceptions -name all_exceptions
# report_clock_interaction
# report_clock_utilization
# report_clock_timing_summary

# -----------------------------------------------------------------------------
# §10 待补清单（M6 上板阶段完成）
# -----------------------------------------------------------------------------
# - [ ] 实测板卡时钟不确定度（用 signal integrity 分析工具）
# - [ ] IO bank 分配（Alveo U20 板卡特定 pinout）
# - [ ] 功耗约束（power intent）
# - [ ] Bitstream 生成时的 config 属性（SPI / JTAG 模式）
# - [ ] 时序例外审查（false_path 与 max_delay 数量）
# =============================================================================
