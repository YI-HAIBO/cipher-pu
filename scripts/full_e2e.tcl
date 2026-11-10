# full_e2e.tcl — 完整 E2E 顶层 OOC 综合 + P&R（Phase 2）
#
# 目标：
#   - 对完整顶层 e2e_ckks_mult_ctrl_m4 进行 OOC 综合 + P&R
#   - 绕过 DCP 集成路径
#
# 用法：
#   vivado -mode batch -source full_e2e.tcl

# --- 参数（通过环境变量传递，在 script 中读取）---
if {[info exists ::env(PROD_LOG_N)]} {
    set LOG_N $::env(PROD_LOG_N)
} else {
    set LOG_N 14
}
set N [expr {1 << $LOG_N}]
set Q_WIDTH 45
set Q_IN 17592186175489
set Q_OUT 17592186372097
set N_INV 17587891208161
set USE_FASTRED 1
set PART "xcau25p-ffvb676-1-e"

if {[info exists ::env(PROD_OUT_DIR)]} {
    set OUT_DIR $::env(PROD_OUT_DIR)
} else {
    set OUT_DIR "$PROJ_DIR/reports/impl/full_e2e_au25p_n14"
}
set CLK_FREQ_MHZ 100
set CLK_PERIOD 10.000

file mkdir $OUT_DIR

# --- 工作目录切换到项目根目录（避免 glob 路径问题）---
set PROJECT_ROOT "[file normalize [file dirname [file dirname [info script]]]]"

# --- 清理上一个项目 ---
if {[llength [get_projects]] > 0} {
    closescript
}

# --- 创建项目 ---
create_project full e2e_impl $OUT_DIR/full_e2e_impl -part $PART -force

# --- 添加所有 RTL（相对 PROJECT_ROOT）---
set all_rtl [list]
foreach dir {rtl/m1 rtl/m2 rtl/m3 rtl/m4} {
    foreach f [glob -directory [file join $PROJECT_ROOT $dir] *.sv] {
        lappend all_rtl $f
    }
}
add_files -fileset [get_filesets sources_1] $all_rtl

# --- 设置顶层 ---
set_property top e2e_ckks_mult_ctrl_m4 [current_fileset]

# --- 内存墙规避参数 ---
set_param synth.elaboration.rodinMoreOptions {rt::set_parameter dissolveMemorySizeLimit 800000}

# --- 准备 generic 参数列表（用于 exec 命令）---
set generic_list [list]
lappend generic_list "LOG_N" $LOG_N
lappend generic_list "Q_WIDTH" $Q_WIDTH
lappend generic_list "Q_IN" $Q_IN
lappend generic_list "Q_OUT" $Q_OUT
lappend generic_list "N_INV" $N_INV
lappend generic_list "USE_FASTRED" $USE_FASTRED

# --- OOC 综合：使用 exec 避免 Vivado 命令解析问题 ---
# 注意：这里使用 exec 将 synth_design 作为外部命令执行，可以正确传递 generic 参数
set synth_cmd "synth_design -top e2e_ckks_mult_ctrl_m4 -part $PART -mode out_of_context -define CKKS_BRAM_IP"
foreach {k v} {
    LOG_N $LOG_N Q_WIDTH $Q_WIDTH Q_IN $Q_IN Q_OUT $Q_OUT N_INV $N_INV USE_FASTRED $USE_FASTRED
} {
    append synth_cmd " -generic $k $v"
}
puts "Running OOC synthesis: $synth_cmd"
exec $synth_cmd

# --- 地址约束 ---
create_clock -period $CLK_PERIOD -name clk [get_ports clk]

# --- 布局布线 ---
puts "Running place_design..."
place_design -timing_effort Medium

puts "Running route_design..."
route_design -timing_effort Medium

# --- 生成报告 ---
puts "Generating reports..."
report_utilization -file "$OUT_DIR/full_e2e_impl_util.rpt"
report_timing_summary -max_paths 20 -file "$OUT_DIR/full_e2e_impl_timing.rpt"
report_timing_summary -delay_type min -max_paths 20 -file "$OUT_DIR/full_e2e_impl_timing_min.rpt"
report_clock_interaction -file "$OUT_DIR/full_e2e_impl_clock_interaction.rpt"

# --- 导出 DCP（可选）---
write_checkpoint -force "$OUT_DIR/full_e2e_impl.dcp"

puts "Phase 2 COMPLETE."
puts "  OUTPUT: $OUT_DIR"
puts "  Util:   $OUT_DIR/full_e2e_impl_util.rpt"
puts "  Timing: $OUT_DIR/full_e2e_impl_timing.rpt"

exit 0
