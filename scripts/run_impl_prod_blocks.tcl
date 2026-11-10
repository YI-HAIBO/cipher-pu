# =============================================================================
# run_impl_prod_blocks.tcl
#
# Phase 2: 顶层集成（3 DCP → link_design）+ 布局布线
#
# 策略：
#   - 读入 3 个叶子子模块 DCP（approx_poly_mult / keyswitch_pipe / rescale）
#   - 添加顶层 RTL（e2e_ckks_mult_ctrl_m4 + gear_controller + noise_monitor
#     + adaptive_gear_ctrl + ckks_bram）
#   - 重建 ntt_mem_bram IP（供顶层 ckks_bram 实例使用）
#   - link_design 完成顶层集成
#   - 加时钟约束 + 布局布线
#   - report_utilization + report_timing_summary
#
# 用法：
#   vivado -mode batch -source run_impl_prod_blocks.tcl
# =============================================================================

set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set RTL_DIR  "$PROJ_DIR/rtl"
set DCP_DIR  "$PROJ_DIR/reports/synth/prod_blocks_au25p_n12"
set OUT_DIR  "$PROJ_DIR/reports/impl/prod_blocks_au25p_n12"

# --- 参数（与 Phase 1 综合保持一致）---
set LOG_N           12
set N               [expr {1 << $LOG_N}]
set Q_WIDTH         45
set Q_IN            17592186175489
set Q_OUT           17592186372097
set N_INV           17587891208161
set USE_FASTRED     1
set PART            "xcau25p-ffvb676-1-e"

# --- IP 参数 ---
set MEM_SIZE_WORDS  [expr {1 << $LOG_N}]
set DATA_WIDTH      45
set ADDR_WIDTH      $LOG_N
set CLK_FREQ_MHZ    100
set COMPONENT_NAME  "ntt_mem_bram"
set IP_GEN_DIR      "$OUT_DIR/ip_gen/ntt_mem_bram"

# --- 时钟周期（100 MHz）---
set CLK_PERIOD      10.000

# =============================================================================
# 过程：create_bram_ip
# =============================================================================
proc create_bram_ip {} {
    global PART COMPONENT_NAME IP_GEN_DIR MEM_SIZE_WORDS DATA_WIDTH CLK_FREQ_MHZ

    puts "  Creating BRAM IP ($COMPONENT_NAME)..."
    file mkdir $IP_GEN_DIR

    set ip_instance ""
    foreach v {8.4 8.3} {
        set obj ""
        set err_create ""
        catch {
            set obj [create_ip \
                -vendor       xilinx.com \
                -library      ip \
                -name         blk_mem_gen \
                -version      $v \
                -module_name  $COMPONENT_NAME \
                -dir          $IP_GEN_DIR]
        } err_create
        if {[llength $obj] > 0} {
            set ip_instance $obj
            break
        }
    }

    if {[llength $ip_instance] == 0} {
        puts "  ERROR: create_ip failed"
        return -1
    }

    set ip_obj [get_ips $COMPONENT_NAME]

    proc set_cfg {ip_obj prop value} {
        catch { set_property $prop $value $ip_obj }
    }

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

    catch { generate_target all $ip_obj } err_gen
    if {[string length $err_gen] > 0} {
        puts "  WARN generate_target: $err_gen"
    }

    puts "  BRAM IP created and generated."
    return 0
}

# =============================================================================
# Phase 2: 顶层集成 + 布局布线
# =============================================================================
puts ""
puts "============================================================"
puts "###### Phase 2: Top-Level Integration + P&R ######"
puts "Out dir: $OUT_DIR"
puts "Part:    $PART"
puts "Params:  LOG_N=$LOG_N, Q_WIDTH=$Q_WIDTH, USE_FASTRED=$USE_FASTRED"
puts "============================================================"
puts ""

file mkdir $OUT_DIR
catch { close_project }

# --- 创建项目 ---
create_project prod_e2e_impl $OUT_DIR/prod_e2e_impl -part $PART -force

# --- 重建 BRAM IP ---
create_bram_ip

# --- 添加 IP 综合 VHDL ---
set f_misc [add_files -fileset [get_filesets sources_1] \
    "$IP_GEN_DIR/ntt_mem_bram/misc/blk_mem_gen_v8_4.vhd"]
set f_hdl  [add_files -fileset [get_filesets sources_1] \
    "$IP_GEN_DIR/ntt_mem_bram/hdl/blk_mem_gen_v8_4_syn_rfs.vhd"]
set f_syn  [add_files -fileset [get_filesets sources_1] \
    "$IP_GEN_DIR/ntt_mem_bram/synth/ntt_mem_bram.vhd"]

set lib_set 0
foreach libname {blk_mem_gen_v8_4_13 blk_mem_gen_v8_4_14 blk_mem_gen_v8_4_15
                 blk_mem_gen_v8_4_16 blk_mem_gen_v8_4 blk_mem_gen_v8_4_12} {
    set err ""
    catch { set_property library $libname $f_misc $f_hdl } err
    if {$err eq ""} {
        puts "  IP VHDL added to sources_1 with library=$libname"
        set lib_set 1
        break
    }
}
if {!$lib_set} {
    puts "  WARN: 无法设置 VHDL library，用默认"
}

# --- 读入子模块 DCP ---
puts ""
puts "--- Reading sub-module DCPs ---"
foreach dcp [list \
    "$DCP_DIR/approx_poly_mult.dcp" \
    "$DCP_DIR/keyswitch_pipe.dcp" \
    "$DCP_DIR/rescale.dcp"] {
    if {[file exists $dcp]} {
        puts "  read_checkpoint $dcp"
        read_checkpoint $dcp
    } else {
        puts "  ERROR: DCP not found: $dcp"
        exit 1
    }
}

# --- 添加顶层 RTL（不含子模块 RTL，子模块已从 DCP 读入）---
puts ""
puts "--- Adding top-level RTL ---"
set TOP_FILES [list \
    "$RTL_DIR/m1/ckks_bram.sv" \
    "$RTL_DIR/m4/e2e_ckks_mult_ctrl_m4.sv" \
    "$RTL_DIR/m4/gear_controller.sv" \
    "$RTL_DIR/m4/noise_monitor.sv" \
    "$RTL_DIR/m4/adaptive_gear_ctrl.sv"]
foreach f $TOP_FILES {
    if {[file exists $f]} {
        add_files -fileset [get_filesets sources_1] $f
        puts "  added: $f"
    } else {
        puts "  ERROR: file not found: $f"
        exit 1
    }
}

# --- 设置顶层 ---
set_property top e2e_ckks_mult_ctrl_m4 [current_fileset]

# --- 内存墙规避 ---
catch { set_param synth.elaboration.rodinMoreOptions {rt::set_parameter dissolveMemorySizeLimit 800000} }

# --- Elaborate + Link ---
puts ""
puts "--- link_design ---"
link_design -top e2e_ckks_mult_ctrl_m4 -part $PART \
    -generic LOG_N=$LOG_N \
    -generic Q_WIDTH=$Q_WIDTH \
    -generic Q_IN=$Q_IN \
    -generic Q_OUT=$Q_OUT \
    -generic N_INV=$N_INV \
    -generic USE_FASTRED=$USE_FASTRED

puts "  link_design done."

# --- 时钟约束 ---
puts ""
puts "--- Creating clock constraint ($CLK_PERIOD MHz) ---"
create_clock -period $CLK_PERIOD -name clk [get_ports clk]

# --- 布局布线 ---
puts ""
puts "--- Place & Route ---"
place_design -timing_effort Medium
route_design -timing_effort Medium

# --- 报告 ---
puts ""
puts "--- Reports ---"
report_utilization -file "$OUT_DIR/e2e_impl_util.rpt"
report_timing_summary -max_paths 20 -file "$OUT_DIR/e2e_impl_timing.rpt"
report_timing_summary -delay_type min -max_paths 20 -file "$OUT_DIR/e2e_impl_timing_min.rpt"
report_clock_interaction -file "$OUT_DIR/e2e_impl_clock_interaction.rpt"

# --- 导出 DCP ---
write_checkpoint -force "$OUT_DIR/e2e_impl.dcp"

puts ""
puts "###### Phase 2 COMPLETE ######"
puts "  DCP: $OUT_DIR/e2e_impl.dcp"
puts "  Util: $OUT_DIR/e2e_impl_util.rpt"
puts "  Timing: $OUT_DIR/e2e_impl_timing.rpt"

exit 0