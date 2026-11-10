# =============================================================================
# e35_ablation_synth.tcl — E35: same-device ablation baselines (OOC synthesis)
#
# Variants (all xcau25p-ffvb676-1-e, N=2^12, Q_WIDTH=45, 100 MHz constraint):
#   abl0_block_sparse : gear 3 + block-level sparse masking (CIPHER-PU datapath)
#   abl1_element_sparse: gear 3 + element-wise sparse masking only
#   abl2_naive        : gear 0, full-precision conventional datapath
#   noise_monitor     : standalone closed-loop monitor (cost added analytically)
#   adaptive_gear_ctrl: standalone adaptive controller (cost added analytically)
#
# Usage (from Python driver): vivado -mode batch -source e35_ablation_synth.tcl
# Reads env E35_VARIANT to select a single variant (sequential runs).
# =============================================================================
set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set RTL_DIR  "$PROJ_DIR/rtl"
set OUT      "$PROJ_DIR/reports/experiments/e35_ablation"
file mkdir $OUT
set IP_GEN_DIR "$OUT/ip_gen/ntt_mem_bram"

set PART "xcau25p-ffvb676-1-e"
set COMPONENT_NAME "ntt_mem_bram"

set LOG_N    12
set N        [expr {1 << $LOG_N}]
set Q_WIDTH  45
set Q_IN     17592186175489
set Q_OUT    17592186372097
set N_INV    17587891208161

set MEM_SIZE_WORDS $N
set DATA_WIDTH     45
set ADDR_WIDTH     $LOG_N
set CLK_FREQ_MHZ   100

if {[info exists ::env(E35_VARIANT)]} {
    set VARIANT $::env(E35_VARIANT)
} else {
    set VARIANT "abl0_block_sparse"
}
puts ">>> E35 variant: $VARIANT"

set MEM_PARAM "set_param synth.elaboration.rodinMoreOptions {rt::set_parameter dissolveMemorySizeLimit 800000}"

# --- BRAM IP rebuild (same recipe as run_synth_prod_blocks.tcl) ---
proc create_bram_ip {} {
    global PART COMPONENT_NAME IP_GEN_DIR MEM_SIZE_WORDS DATA_WIDTH CLK_FREQ_MHZ
    file mkdir $IP_GEN_DIR
    set ip_instance ""
    foreach v {8.4 8.3} {
        set obj ""
        catch { set obj [create_ip -vendor xilinx.com -library ip -name blk_mem_gen \
                         -version $v -module_name $COMPONENT_NAME -dir $IP_GEN_DIR] }
        if {[llength $obj] > 0} { set ip_instance $obj; break }
    }
    if {[llength $ip_instance] == 0} { puts "ERROR create_ip failed"; return -1 }
    set ip_obj [get_ips $COMPONENT_NAME]
    proc set_cfg {ip_obj prop value} { catch { set_property $prop $value $ip_obj } }
    set_cfg $ip_obj CONFIG.Write_Depth_A $MEM_SIZE_WORDS
    set_cfg $ip_obj CONFIG.Write_Width_A $DATA_WIDTH
    set_cfg $ip_obj CONFIG.Write_Width_B $DATA_WIDTH
    set_cfg $ip_obj CONFIG.Read_Width_A  $DATA_WIDTH
    set_cfg $ip_obj CONFIG.Read_Width_B  $DATA_WIDTH
    set_cfg $ip_obj CONFIG.Memory_Type "True_Dual_Port_RAM"
    set_cfg $ip_obj CONFIG.use_bram_block "Stand_Alone"
    set_cfg $ip_obj CONFIG.Port_A_Clock $CLK_FREQ_MHZ
    set_cfg $ip_obj CONFIG.Port_B_Clock $CLK_FREQ_MHZ
    set_cfg $ip_obj CONFIG.Register_PortA_Output_of_Memory_Core true
    set_cfg $ip_obj CONFIG.Register_PortB_Output_of_Memory_Core true
    set_cfg $ip_obj CONFIG.Use_RSTA_Pin false
    set_cfg $ip_obj CONFIG.Use_RSTB_Pin false
    set_cfg $ip_obj CONFIG.Enable_A "Use_ENA_Pin"
    set_cfg $ip_obj CONFIG.Enable_B "Use_ENB_Pin"
    set_cfg $ip_obj CONFIG.Use_REGCEA_Pin true
    set_cfg $ip_obj CONFIG.Use_REGCEB_Pin true
    catch { generate_target all $ip_obj }
    return 0
}

set COMMON_FILES [list \
    "$RTL_DIR/m1/mult_43x43_horner4.sv" \
    "$RTL_DIR/m1/ntt_butterfly.sv" \
    "$RTL_DIR/m1/ntt_unit.sv" \
    "$RTL_DIR/m1/ntt_mem_tdp.sv" \
    "$RTL_DIR/m1/ntt_mem_tdp_prod.sv" \
    "$RTL_DIR/m2/mod45_fastred.sv" \
    "$RTL_DIR/m1/ckks_bram.sv" \
    "$RTL_DIR/m2/poly_mult.sv"]

set E2E_FILES [concat $COMMON_FILES [list \
    "$RTL_DIR/m4/approx_poly_mult.sv" \
    "$RTL_DIR/m3/keyswitch_pipe.sv" \
    "$RTL_DIR/m3/rescale.sv" \
    "$RTL_DIR/m4/e2e_ckks_mult_ctrl_m4.sv" \
    "$RTL_DIR/m4/ablation/e2e_ablation_wrapper.sv"]]

proc synth_variant {name top_mod generic_list file_list} {
    global PART OUT MEM_PARAM IP_GEN_DIR
    puts ""
    puts "============================================================"
    puts "=== E35: $name (top=$top_mod, OOC) ==="
    puts "============================================================"
    catch { close_project }
    create_project "e35_$name" "$OUT/prj_$name" -part $PART -force
    create_bram_ip
    set f_misc [add_files -fileset [get_filesets sources_1] "$IP_GEN_DIR/ntt_mem_bram/misc/blk_mem_gen_v8_4.vhd"]
    set f_hdl  [add_files -fileset [get_filesets sources_1] "$IP_GEN_DIR/ntt_mem_bram/hdl/blk_mem_gen_v8_4_syn_rfs.vhd"]
    set f_syn  [add_files -fileset [get_filesets sources_1] "$IP_GEN_DIR/ntt_mem_bram/synth/ntt_mem_bram.vhd"]
    set lib_set 0
    foreach libname {blk_mem_gen_v8_4_13 blk_mem_gen_v8_4_14 blk_mem_gen_v8_4_15
                     blk_mem_gen_v8_4_16 blk_mem_gen_v8_4 blk_mem_gen_v8_4_12} {
        set err ""
        catch { set_property library $libname $f_misc $f_hdl } err
        if {$err eq ""} { puts "  IP VHDL library=$libname"; set lib_set 1; break }
    }
    if {!$lib_set} { puts "  WARN: VHDL library not set" }
    add_files -fileset [get_filesets sources_1] $file_list
    set_property top $top_mod [current_fileset]
    catch { eval $MEM_PARAM }

    set SYNTH_CMD "synth_design -top $top_mod -part $PART -mode out_of_context -define CKKS_BRAM_IP"
    foreach g $generic_list { append SYNTH_CMD " -generic $g" }
    puts ">>> $SYNTH_CMD"
    eval $SYNTH_CMD

    catch { create_clock -period 10.000 -name clk [get_ports clk] } err_cc
    if {[string length $err_cc] > 0} { puts "  WARN create_clock: $err_cc" }

    report_utilization -file "$OUT/${name}_util.rpt"
    report_timing_summary -max_paths 10 -file "$OUT/${name}_timing.rpt"
    report_power -no_propagation -file "$OUT/${name}_power.rpt"
    catch { write_checkpoint -force "$OUT/${name}.dcp" } err_dcp
    puts "  DCP: $OUT/${name}.dcp"

    # scrape headline numbers to stdout for the driver
    set fh [open "$OUT/${name}_util.rpt" r]
    set utxt [read $fh]; close $fh
    foreach line [split $utxt "\n"] {
        if {[string match "*Slice LUTs*" $line] || [string match "*Block RAM Tile*" $line] || [string match "*DSPs*" $line]} {
            puts ">>> UTIL: $line"
        }
    }
    set fh [open "$OUT/${name}_power.rpt" r]
    set ptxt [read $fh]; close $fh
    foreach line [split $ptxt "\n"] {
        if {[string match "*Total On-Chip Power*" $line] || [string match "*Confidence*" $line]} {
            puts ">>> POWER: $line"
        }
    }
    close_project
    puts "=== DONE: $name ==="
}

set GL_E2E [list "LOG_N=$LOG_N" "Q_WIDTH=$Q_WIDTH" "Q_IN=$Q_IN" "Q_OUT=$Q_OUT" "N_INV=$N_INV" "USE_FASTRED=1"]

switch $VARIANT {
    "abl0_block_sparse" {
        synth_variant "abl0_block_sparse" "e2e_ablation_wrapper" \
            [concat $GL_E2E [list "ABL_MODE=0"]] $E2E_FILES
    }
    "abl1_element_sparse" {
        synth_variant "abl1_element_sparse" "e2e_ablation_wrapper" \
            [concat $GL_E2E [list "ABL_MODE=1"]] $E2E_FILES
    }
    "abl2_naive" {
        synth_variant "abl2_naive" "e2e_ablation_wrapper" \
            [concat $GL_E2E [list "ABL_MODE=2"]] $E2E_FILES
    }
    "ctrl_noise_monitor" {
        synth_variant "ctrl_noise_monitor" "noise_monitor" \
            [list "Q_WIDTH=$Q_WIDTH" "N=$N" "ACC_W=106"] \
            [list "$RTL_DIR/m4/noise_monitor.sv"]
    }
    "ctrl_adaptive_gear" {
        synth_variant "ctrl_adaptive_gear" "adaptive_gear_ctrl" \
            [list "ACC_W=106" "THRESH_G1=64'd500" "THRESH_G2=64'd200" "THRESH_G3=64'd50" "HYST_CNT=3"] \
            [list "$RTL_DIR/m4/adaptive_gear_ctrl.sv"]
    }
    default {
        puts "ERROR: unknown E35_VARIANT $VARIANT"
        exit 1
    }
}

puts ">>> E35_SYNTH_COMPLETE: $VARIANT"
exit 0
