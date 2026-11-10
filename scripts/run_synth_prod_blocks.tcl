# =============================================================================
# run_synth_prod_blocks.tcl
#
# 生产配置 N=2^14=16384, Q_WIDTH=45 分模块 DCP 综合流程
#
# 目标：绕过 68 GB 主机内存墙（完整 e2e_ckks_mult_ctrl_m4 综合峰值 ~33.7 GB）
#
# 策略：
#   - 每个叶子子模块独立 OOC 综合 + export_dcp
#   - 每个子模块内存峰值独立，累加 < 68 GB
#   - 得到子模块级面积/时序报告（论文可用）
#   - 导出 DCP 供 Phase 2 集成
#
# 三个子模块（覆盖 e2e_ckks_mult_ctrl_m4 全部重计算）：
#   approx_poly_mult × 4 实例（含 poly_mult → 2× ntt_unit → 2× ntt_mem_tdp_prod → BRAM IP）
#   keyswitch_pipe   × 1 实例（含 2× poly_mult）
#   rescale          × 2 实例（自包含，无 BRAM）
#
# 关键 Vivado 2026.1 要点：
#   - add_ip_repo 已失效（invalid command name）
#   - add_files xci 不会创建 IP 对象，elaborate 找不到 ntt_mem_bram
#   - hdl/blk_mem_gen_v8_4_syn_rfs.vhd 是加密 VHDL，无法直接 add_files
#   - 唯一可行：create_ip + set_property + generate_target 在每个项目内重建 IP
# =============================================================================

set PROJ_DIR        "[file normalize [file dirname [file dirname [info script]]]]"
set RTL_DIR         "$PROJ_DIR/rtl"
set IP_REPO         "$PROJ_DIR/ip_repo"

# 输出目录由 Python 通过 PROD_OUT_DIR 传入（支持 --log-n 12 的 _n12 后缀），
# 默认回退到 N=2^14 目录
if {[info exists ::env(PROD_OUT_DIR)]} {
    set OUT_DIR     [file normalize $::env(PROD_OUT_DIR)]
} else {
    set OUT_DIR     [file normalize "$PROJ_DIR/reports/synth/prod_blocks_au25p"]
}
file mkdir $OUT_DIR

# IP 生成目录放在各自输出目录下，避免两个并发 Vivado 进程争抢同一个 ip_repo
set IP_GEN_DIR      "$OUT_DIR/ip_gen/ntt_mem_bram"

set PART            "xcau25p-ffvb676-1-e"
set COMPONENT_NAME  "ntt_mem_bram"

# --- Prod 参数（2026-10-06：Q_IN 从 q0 统一为 q3，与 N_INV + mod45_fastred 硬编码一致）---
# 2026-10-06：新增 PROD_LOG_N 环境变量支持降 N（2^14 -> 2^12）路径
if {[info exists ::env(PROD_LOG_N)]} {
    set LOG_N $::env(PROD_LOG_N)
} else {
    set LOG_N 14
}
set N               [expr {1 << $LOG_N}]
set Q_WIDTH         45
set Q_IN            17592186175489
set Q_OUT           17592186372097
if {[info exists ::env(PROD_N_INV)]} {
    set N_INV       $::env(PROD_N_INV)
} else {
    set N_INV       17591112433657        ;# N^-1 mod q3 @ N=2^14
}
set USE_FASTRED     1

# --- IP 参数（随 LOG_N）---
set MEM_SIZE_WORDS  [expr {1 << $LOG_N}]
set DATA_WIDTH      45
set ADDR_WIDTH      $LOG_N
set CLK_FREQ_MHZ    100

# --- 文件列表 ---
# 注意：不加 IP 的 .v / .vhd 文件！IP 通过 create_ip 在每个项目内重建
set COMMON_FILES [list \
    "$RTL_DIR/m1/mult_43x43_horner4.sv" \
    "$RTL_DIR/m1/ntt_butterfly.sv" \
    "$RTL_DIR/m1/ntt_unit.sv" \
    "$RTL_DIR/m1/ntt_mem_tdp.sv" \
    "$RTL_DIR/m1/ntt_mem_tdp_prod.sv" \
    "$RTL_DIR/m2/mod45_fastred.sv" \
    "$RTL_DIR/m1/ckks_bram.sv" \
    "$RTL_DIR/m2/poly_mult.sv"]

# 内存墙规避参数
set MEM_PARAM "set_param synth.elaboration.rodinMoreOptions {rt::set_parameter dissolveMemorySizeLimit 800000}"


# =============================================================================
# 过程：create_bram_ip — 在项目内重建 BRAM IP
# =============================================================================
proc create_bram_ip {} {
    global PART COMPONENT_NAME IP_GEN_DIR \
           MEM_SIZE_WORDS DATA_WIDTH CLK_FREQ_MHZ

    puts "  Creating BRAM IP ($COMPONENT_NAME)..."

    # -dir 必须先存在；每个输出目录独立，避免并发综合争抢
    file mkdir $IP_GEN_DIR

    # 2026.1 正确 VLNV: xilinx.com:ip:blk_mem_gen:8.4
    # 必须 -module_name，不接受 -import_file
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

    # create_ip 返回 file 路径，需用 get_ips 转对象
    set ip_obj [get_ips $COMPONENT_NAME]

    # CONFIG 设置
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

    # 生成目标
    catch { generate_target all $ip_obj } err_gen
    if {[string length $err_gen] > 0} {
        puts "  WARN generate_target: $err_gen"
    }

    puts "  BRAM IP created and generated."
    return 0
}


# =============================================================================
# 过程：synth_one_block <top_mod> <generic_list> <extra_files>
# =============================================================================
proc synth_one_block {top_mod generic_list extra_files} {
    global PART OUT_DIR COMMON_FILES MEM_PARAM IP_GEN_DIR

    set PROJ_NAME "prod_$top_mod"
    set PROJ_DIR_ABS "$OUT_DIR/$PROJ_NAME"

    puts ""
    puts "============================================================"
    puts "=== Synthesizing: $top_mod  (OOC, prod config) ==="
    puts "=== Project: $PROJ_DIR_ABS ==="
    puts "============================================================"

    catch { close_project }

    # 项目
    create_project $PROJ_NAME $PROJ_DIR_ABS -part $PART -force

    # 先在项目内重建 BRAM IP（供 ntt_mem_tdp_prod 使用）
    # 关键：create_ip + generate_target 生成 IP 目标文件，
    #       但不会自动加到 sources_1。必须显式 add_files。
    create_bram_ip

    # 显式加入 IP 综合 VHDL（三个文件按依赖顺序）
    #   1. misc/blk_mem_gen_v8_4.vhd       → 声明 entity blk_mem_gen_v8_4_13
    #   2. hdl/blk_mem_gen_v8_4_syn_rfs.vhd → 加密 RAM 实现（Vivado 内部解密）
    #   3. synth/ntt_mem_bram.vhd           → wrapper（我们的 ntt_mem_tdp_prod 引用它）
    set f_misc [add_files -fileset [get_filesets sources_1] \
        "$IP_GEN_DIR/ntt_mem_bram/misc/blk_mem_gen_v8_4.vhd"]
    set f_hdl  [add_files -fileset [get_filesets sources_1] \
        "$IP_GEN_DIR/ntt_mem_bram/hdl/blk_mem_gen_v8_4_syn_rfs.vhd"]
    set f_syn  [add_files -fileset [get_filesets sources_1] \
        "$IP_GEN_DIR/ntt_mem_bram/synth/ntt_mem_bram.vhd"]

    # 关键：VHDL library 属性设置
    #   synth/ntt_mem_bram.vhd 引用 LIBRARY blk_mem_gen_v8_4_XX，
    #   必须把 misc/ 和 hdl/ 的 VHDL 放入同名 library，否则 elaborate 找不到
    #   库名随 Vivado 版本/器件族变化，逐一尝试
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
        puts "  WARN: 无法设置 VHDL library，用默认（可能 elaborate 失败）"
    }

    # 加 RTL 源文件
    add_files -fileset [get_filesets sources_1] $COMMON_FILES
    if {[llength $extra_files] > 0} {
        add_files -fileset [get_filesets sources_1] $extra_files
    }
    set_property top $top_mod [current_fileset]

    # 内存墙规避
    catch { eval $MEM_PARAM }

    # 综合（OOC + 生产参数）
    # Task #64：-define CKKS_BRAM_IP 走 ntt_mem_bram IP 路径（绕开 45-bit BRAM 推断失败）
    set SYNTH_CMD "synth_design -top $top_mod -part $PART -mode out_of_context -define CKKS_BRAM_IP"
    foreach g $generic_list {
        append SYNTH_CMD " -generic $g"
    }
    puts ">>> $SYNTH_CMD"
    eval $SYNTH_CMD

    # 时钟约束（100 MHz = 10 ns）
    catch { create_clock -period 10.000 -name clk [get_ports clk] } err
    if {[string length $err] > 0} {
        puts "  WARN create_clock: $err"
    }

    # 报告
    report_utilization -file "$OUT_DIR/${top_mod}_util.rpt"
    report_timing_summary -max_paths 15 -file "$OUT_DIR/${top_mod}_timing.rpt"
    report_timing_summary -delay_type min -max_paths 15 -file "$OUT_DIR/${top_mod}_timing_min.rpt"
    report_clock_interaction -file "$OUT_DIR/${top_mod}_clock_interaction.rpt"

    # 导出 DCP（2026.1: export_dcp 已移除，改用 write_checkpoint）
    catch { write_checkpoint -force "$OUT_DIR/${top_mod}.dcp" } err_dcp
    if {[string length $err_dcp] > 0} {
        puts "  WARN export_dcp: $err_dcp"
    } else {
        puts "  DCP exported: $OUT_DIR/${top_mod}.dcp"
    }

    close_project
    puts "=== DONE: $top_mod ==="
}


# =============================================================================
# Phase 1: 三个叶子子模块 OOC 综合
# =============================================================================
puts ""
puts "###### Phase 1: Leaf Sub-Module OOC Synthesis ######"
puts "Out dir: $OUT_DIR"
puts "Part:    $PART"
puts "Params:  LOG_N=$LOG_N, Q_WIDTH=$Q_WIDTH, USE_FASTRED=$USE_FASTRED"
puts ""

# --- 单块冒烟模式：Python 通过环境变量 SYNTH_ONLY 传递 ---
set ONLY ""
if {[info exists ::env(SYNTH_ONLY)]} {
    set ONLY $::env(SYNTH_ONLY)
}
if {[llength $ONLY] > 0} {
    puts ">>> Single-block mode: $ONLY"
} else {
    puts ">>> Full mode: all 3 blocks"
}

# --- Block 1: approx_poly_mult (含 poly_mult, 2 NTT, BRAM IP) ---
if {$ONLY eq "" || $ONLY eq "approx_poly_mult"} {
synth_one_block "approx_poly_mult" \
    [list \
        "LOG_N=$LOG_N" \
        "Q_WIDTH=$Q_WIDTH" \
        "Q_VALUE=$Q_IN" \
        "N_INV=$N_INV" \
        "USE_FASTRED=$USE_FASTRED"] \
    [list "$RTL_DIR/m4/approx_poly_mult.sv"]
}

# --- Block 2: keyswitch_pipe (含 2× poly_mult) ---
if {$ONLY eq "" || $ONLY eq "keyswitch_pipe"} {
synth_one_block "keyswitch_pipe" \
    [list \
        "LOG_N=$LOG_N" \
        "Q_WIDTH=$Q_WIDTH" \
        "Q_VAL=$Q_IN" \
        "N_INV=$N_INV" \
        "USE_FASTRED=$USE_FASTRED"] \
    [list "$RTL_DIR/m3/keyswitch_pipe.sv"]
}

# --- Block 3: rescale (自包含，无 BRAM) ---
if {$ONLY eq "" || $ONLY eq "rescale"} {
synth_one_block "rescale" \
    [list \
        "LOG_N=$LOG_N" \
        "Q_WIDTH=$Q_WIDTH" \
        "Q_IN=$Q_IN" \
        "Q_OUT=$Q_OUT"] \
    [list "$RTL_DIR/m3/rescale.sv"]
}

# --- Block 4: e2e_ckks_mult_ctrl_m4 顶层（2026-10-06 Task #63：时分复用后
#     直接综合顶层，实测含 FSM/缓冲/路由的完整面积，不再依赖子模块累加估算）---
if {$ONLY eq "" || $ONLY eq "e2e_ckks_mult_ctrl_m4"} {
synth_one_block "e2e_ckks_mult_ctrl_m4" \
    [list \
        "LOG_N=$LOG_N" \
        "Q_WIDTH=$Q_WIDTH" \
        "Q_IN=$Q_IN" \
        "Q_OUT=$Q_OUT" \
        "N_INV=$N_INV" \
        "USE_FASTRED=$USE_FASTRED"] \
    [list "$RTL_DIR/m4/e2e_ckks_mult_ctrl_m4.sv" \
           "$RTL_DIR/m4/approx_poly_mult.sv" \
           "$RTL_DIR/m3/keyswitch_pipe.sv" \
           "$RTL_DIR/m3/rescale.sv" \
           "$RTL_DIR/m4/gear_controller.sv" \
           "$RTL_DIR/m4/noise_monitor.sv" \
           "$RTL_DIR/m4/adaptive_gear_ctrl.sv"]
}

puts ""
puts "###### Phase 1 COMPLETE ######"
puts "DCPs:"
foreach f [glob "$OUT_DIR/*.dcp"] {
    set sz [file size $f]
    puts "  $f  ($sz bytes)"
}

exit 0
