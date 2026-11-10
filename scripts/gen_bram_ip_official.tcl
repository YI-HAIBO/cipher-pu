# =============================================================================
# gen_bram_ip_official.tcl
#
# 用途：通过 Vivado 官方 Block Memory Generator (blk_mem_gen) IP 生成
#       NTT 系数存储器 IP，替代 Vivado 2026.1 对 2-write + 2-read TDP
#       在 16384x45 规模下的自动推断（Synth 8-2914）。
#
# 规格：
#   - Memory Size: 16384 words x 45 bits = 737,280 bits
#   - BRAM 组件：~20 x RAMB36E1 (每块 36,864 bits)
#   - Port A: Read/Write (synchronous, 1-cycle read latency)
#   - Port B: Read/Write (synchronous, 1-cycle read latency)
#   - Interface: clk, wea, waa, wda, web, wab, wdb, raa, rab, rda, rdb
#
# 运行方式（推荐）：
#   python scripts/gen_bram_ip_official.py
#
# 或直接从 Vivado batch 命令行运行：
#   vivado -mode batch -source scripts/gen_bram_ip_official.tcl
#
# 依赖：
#   - Vivado 2026.1
#   - 目标器件 xc7a200t-ffv1156-2 (Alveo U20)
#
# 2026.1 API 关键要点（实测）：
#   - create_ip 用 -vendor xilinx.com -library ip -version 8.4（不是 1.x）
#   - create_ip 必须 -module_name，不接受 -import_file / -notgui
#   - create_ip 返回**file 路径**而非 IP 对象
#   - 必须用 get_ips <module_name> 转换才能得到真正的 IP 对象
#   - get_property CONFIG.* 通配符失效；CONFIG.MEMORY_SIZE 等具体属性名可用
# =============================================================================

# -----------------------------------------------------------------------------
# 0. 配置参数
# -----------------------------------------------------------------------------
set PROJ_DIR        "ip_gen_workspace"
set OUT_DIR         "ip_repo/ntt_mem_bram"
set PART            "xc7a200t-ffv1156-2"
set MEM_SIZE_WORDS  16384      ;# 16384 words
set DATA_WIDTH      45         ;# 45 bits/word
set ADDR_WIDTH      14         ;# log2(16384) = 14
set CLK_FREQ_MHZ    100
set COMPONENT_NAME  "ntt_mem_bram"

puts "============================================================"
puts "NTT Memory BRAM IP Generator (Official blk_mem_gen 8.4)"
puts "============================================================"
puts "Memory Size  : ${MEM_SIZE_WORDS} x ${DATA_WIDTH} bits"
puts "Total Bits   : [expr {$MEM_SIZE_WORDS * $DATA_WIDTH}]"
puts "Target Part  : ${PART}"
puts "Component    : ${COMPONENT_NAME}"
puts "Output Dir   : ${OUT_DIR}"
puts "============================================================"

# -----------------------------------------------------------------------------
# 1. 清理并重建工作目录
# -----------------------------------------------------------------------------
catch { file delete -force $PROJ_DIR }
catch { file delete -force $OUT_DIR }
file mkdir $PROJ_DIR
file mkdir $OUT_DIR

# -----------------------------------------------------------------------------
# 2. 创建 Vivado 项目（IP 生成需要 project 上下文）
# -----------------------------------------------------------------------------
puts ""
puts "Step 1: Creating Vivado project..."
create_project bram_ip_gen [file normalize $PROJ_DIR] -part $PART -force

# -----------------------------------------------------------------------------
# 3. 创建 IP 实例
#    Vivado 2026.1 正确 VLNV: xilinx.com:ip:blk_mem_gen:8.4
#    必须提供 -module_name（不接受 -import_file）
# -----------------------------------------------------------------------------
puts ""
puts "Step 2: Creating IP instance (xilinx.com:ip:blk_mem_gen:8.4)..."

set ip_instance ""
set tried_versions {8.4 8.3}

foreach v $tried_versions {
    puts "  Trying version $v..."
    set err_create ""
    catch {
        set obj [create_ip \
            -vendor       xilinx.com \
            -library      ip \
            -name         blk_mem_gen \
            -version      $v \
            -module_name  $COMPONENT_NAME \
            -dir          $OUT_DIR]
    } err_create
    if {[llength $obj] > 0} {
        puts "  Version $v succeeded: $obj"
        set ip_instance $obj
        break
    } else {
        puts "  Version $v failed: [string range $err_create 0 200]"
    }
}

if {[llength $ip_instance] == 0} {
    puts "ERROR: create_ip failed for all candidate versions."
    catch { close_project }
    exit 1
}

# 关键：create_ip 返回 file 路径，需通过 get_ips 转换
set ip_obj [get_ips $COMPONENT_NAME]
puts "  IP object: $ip_obj (CLASS: [get_property CLASS $ip_obj])"

# -----------------------------------------------------------------------------
# 4. 配置 IP 属性（TDP: 2 写 + 2 读，同步读，输出寄存器）
#    16384 words × 45 bits
# -----------------------------------------------------------------------------
puts ""
puts "Step 3: Configuring IP properties..."

proc set_cfg {ip_obj prop value} {
    set err ""
    catch {
        set_property $prop $value $ip_obj
    } err
    if {[string length $err] > 0} {
        puts "  WARN ($prop): $err"
    }
}

# 组件名已由 create_ip -module_name 设置，不可重复设置（否则 Vivado 报 12-3523）

# 存储深度（words）—— 不是 Memory_Size，而是 Write_Depth_A
set_cfg $ip_obj CONFIG.Write_Depth_A $MEM_SIZE_WORDS

# 写/读端口宽度
set_cfg $ip_obj CONFIG.Write_Width_A $DATA_WIDTH
set_cfg $ip_obj CONFIG.Write_Width_B $DATA_WIDTH
set_cfg $ip_obj CONFIG.Read_Width_A  $DATA_WIDTH
set_cfg $ip_obj CONFIG.Read_Width_B  $DATA_WIDTH

# 存储类型（TDP：True_Dual_Port_RAM，两个读写端口）
set_cfg $ip_obj CONFIG.Memory_Type "True_Dual_Port_RAM"

# 使用 BRAM block（不是 distributed）
set_cfg $ip_obj CONFIG.use_bram_block "Stand_Alone"

# 时钟频率（Port A / Port B 各一个）
set_cfg $ip_obj CONFIG.Port_A_Clock $CLK_FREQ_MHZ
set_cfg $ip_obj CONFIG.Port_B_Clock $CLK_FREQ_MHZ

# 同步读输出寄存器（Memory Core 输出后加一级 FF）
set_cfg $ip_obj CONFIG.Register_PortA_Output_of_Memory_Core true
set_cfg $ip_obj CONFIG.Register_PortB_Output_of_Memory_Core true

# 关闭异步复位（不需要 RST_A/B pin）
set_cfg $ip_obj CONFIG.Use_RSTA_Pin false
set_cfg $ip_obj CONFIG.Use_RSTB_Pin false

# 使用 REGCE 使能控制（保留 ena/enb 引脚）
set_cfg $ip_obj CONFIG.Enable_A "Use_ENA_Pin"
set_cfg $ip_obj CONFIG.Enable_B "Use_ENB_Pin"
set_cfg $ip_obj CONFIG.Use_REGCEA_Pin true
set_cfg $ip_obj CONFIG.Use_REGCEB_Pin true

puts "  Config applied."

# 回读关键属性验证
puts ""
puts "  Verification (read-back):"
set check_props {CONFIG.Write_Depth_A CONFIG.Write_Width_A CONFIG.Write_Width_B \
                 CONFIG.Read_Width_A CONFIG.Read_Width_B CONFIG.Memory_Type \
                 CONFIG.use_bram_block CONFIG.Port_A_Clock CONFIG.Port_B_Clock \
                 CONFIG.Register_PortA_Output_of_Memory_Core \
                 CONFIG.Register_PortB_Output_of_Memory_Core}
foreach p $check_props {
    set val ""
    catch { set val [get_property $p $ip_obj] }
    puts "    $p = $val"
}

# -----------------------------------------------------------------------------
# 5. 生成 IP 目标（HDL + simulation）
# -----------------------------------------------------------------------------
puts ""
puts "Step 4: Generating IP targets (HDL + simulation)..."
set gen_err ""
set gen_rc [catch {
    generate_target all $ip_obj
} gen_err]
if {$gen_rc != 0} {
    puts "  ERROR generating targets: $gen_err"
    catch { close_project }
    exit 1
}
puts "  Targets generated."

# -----------------------------------------------------------------------------
# 6. 输出信息
# -----------------------------------------------------------------------------
set xci_file ""
catch { set xci_file [get_property IP_FILE $ip_obj] }
if {[string length $xci_file] == 0} {
    # 兜底：直接指向已知路径
    set xci_file "$OUT_DIR/$COMPONENT_NAME/$COMPONENT_NAME.xci"
}
puts ""
puts "============================================================"
puts "IP Generation Complete"
puts "============================================================"
puts "XCI file  : $xci_file"
puts ""
puts "Next steps:"
puts "  1. add_ip_repo -dir ip_repo"
puts "  2. In ntt_unit.sv, replace ntt_mem_tdp with ntt_mem_bram"
puts "============================================================"

catch { close_project }
exit 0
