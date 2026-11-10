# =============================================================================
# run_synth_e2e_m5.tcl - M5 Vivado 综合脚本
# 器件：xc7a200t-ffv1156-2 | 参考：xcau25p-ffvb676-1-e
# 版本：v1.0 (2026-10-04)
# =============================================================================

if { $argc < 1 } {
    puts "Usage: -tclargs config:out_dir"
    exit
}

set ARGS_STR [lindex $argv 0]
set ARGS_LIST [split $ARGS_STR ":"]
set CONFIG [lindex $ARGS_LIST 0]
set OUT_DIR [lindex $ARGS_LIST 1]

set PROJECT_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set RTL_DIR "$PROJECT_DIR/rtl"
set OUT_DIR_ABS [file normalize "$PROJECT_DIR/$OUT_DIR"]
file mkdir $OUT_DIR_ABS

puts "=== M5 Synthesis: $CONFIG -> $OUT_DIR_ABS ==="

if { $CONFIG eq "toy" } {
    set PART "xc7a200t-ffv1156-2"
    set PROJECT_NAME "e2e_m5_toy"
} elseif { $CONFIG eq "prod" } {
    set PART "xc7a200t-ffv1156-2"
    set PROJECT_NAME "e2e_m5_prod"
} else { puts "ERROR"; exit }

# Step 1: Create Project
catch { close_project }
create_project $PROJECT_NAME $OUT_DIR_ABS/$PROJECT_NAME -part $PART -force

# Step 2: Add Sources
set m1_files [glob "$RTL_DIR/m1/mult_43x43_horner4.sv" "$RTL_DIR/m1/mult_43x43_ip_core.sv" "$RTL_DIR/m1/mult_43x43_iteradd.sv" "$RTL_DIR/m1/ntt_butterfly.sv" "$RTL_DIR/m1/ntt_unit.sv"]
set m2_files [glob "$RTL_DIR/m2/mod45_fastred.sv" "$RTL_DIR/m2/poly_mult.sv"]
set m1b_files [glob "$RTL_DIR/m1/ckks_bram.sv"]
set m3_files [glob "$RTL_DIR/m3/keyswitch_pipe.sv" "$RTL_DIR/m3/rescale.sv"]
set m4_files [glob "$RTL_DIR/m4/gear_controller.sv" "$RTL_DIR/m4/sparse_ntt_unit.sv" "$RTL_DIR/m4/trunc_multiplier.sv" "$RTL_DIR/m4/approx_poly_mult.sv" "$RTL_DIR/m4/e2e_ckks_mult_ctrl_m4.sv"]
add_files -fileset [get_filesets sources_1] $m1_files $m2_files $m1b_files $m3_files $m4_files
set_property top e2e_ckks_mult_ctrl_m4 [current_fileset]

# Step 3: Read XDC
read_xdc "$RTL_DIR/m1/clocks.xdc"
read_xdc "$RTL_DIR/m2/poly_mult.xdc"
read_xdc "$RTL_DIR/m5/e2e_m5.xdc"

# Step 4: Synthesize
# 允许大内存推断（poly_mult 内部 N=16384 x Q_WIDTH=45 = 737280 bit）
set_param synth.elaboration.rodinMoreOptions {rt::set_parameter dissolveMemorySizeLimit 800000}

if { $CONFIG eq "toy" } {
    synth_design -top e2e_ckks_mult_ctrl_m4 -part $PART -mode out_of_context -generic "LOG_N=4" -generic "Q_WIDTH=7" -generic "N_INV=106" -generic "Q_IN=113" -generic "Q_OUT=97" -generic "USE_FASTRED=0"
} else {
    synth_design -top e2e_ckks_mult_ctrl_m4 -part $PART -mode out_of_context -generic "LOG_N=14" -generic "Q_WIDTH=45" -generic "N_INV=17591112433657" -generic "Q_IN=17592186634241" -generic "Q_OUT=17592186372097" -generic "USE_FASTRED=1"
}

# Step 5: Reports
report_utilization -file $OUT_DIR_ABS/$PROJECT_NAME/utilization_${CONFIG}.rpt
report_timing_summary -max_paths 20 -file $OUT_DIR_ABS/$PROJECT_NAME/timing_${CONFIG}.rpt
report_timing_summary -delay_type min -max_paths 20 -file $OUT_DIR_ABS/$PROJECT_NAME/timing_min_${CONFIG}.rpt
report_clock_interaction -file $OUT_DIR_ABS/$PROJECT_NAME/clock_interaction_${CONFIG}.rpt
report_clock_utilization -file $OUT_DIR_ABS/$PROJECT_NAME/clock_util_${CONFIG}.rpt
# report_timing_exceptions 在 Vivado 2026.1 中不存在，移除

puts "=== DONE ==="
close_project
exit 0
