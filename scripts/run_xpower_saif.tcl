# =============================================================================
# run_xpower_saif.tcl
#
# E13 Step 2: 在已 P&R 的 N=2^12 e2e DCP 上，用 SAIF 活动文件跑高精度功耗
# 用法: vivado -mode batch -source run_xpower_saif.tcl
#
# 对比：
#   - 默认切换活动率（Medium Confidence，无 SAIF）
#   - SAIF 驱动（High Confidence，真实切换活动）
# =============================================================================

set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set DCP  "$PROJ_DIR/reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp"
set VCD  "$PROJ_DIR/sim/tb_e2e_saif_minimal/e2e.vcd"
set OUT  "$PROJ_DIR/reports/power/e2e_au25p_n12_vcd"

file mkdir $OUT

puts "============================================================"
puts "###### E13: XPower with VCD simulation activity ######"
puts "DCP: $DCP"
puts "VCD: $VCD"
puts "OUT: $OUT"
puts "============================================================"

open_checkpoint $DCP

# ---- 1. 默认活动率功耗（无 VCD，Medium Confidence）----
puts "\n--- 1. Default switching activity (no VCD) ---"
report_power -file "$OUT/e2e_power_default.rpt"

# ---- 2. VCD 驱动功耗（High Confidence）----
puts "\n--- 2. VCD-driven power (high confidence) ---"
if {[file exists $VCD]} {
    read_saif $VCD
    report_power -file "$OUT/e2e_power_vcd.rpt"
    puts "  VCD-driven report written."
} else {
    puts "  ERROR: VCD file not found: $VCD"
    exit 1
}

# ---- 3. 对比摘要 ----
puts "\n--- 3. Power comparison summary ---"
puts "  See $OUT/e2e_power_default.rpt (default) vs $OUT/e2e_power_vcd.rpt (VCD)"

puts ""
puts "###### E13 XPower COMPLETE ######"
exit 0