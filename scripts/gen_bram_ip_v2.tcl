# gen_bram_ip_v2.tcl - 用 try-and-catch 探测所有 CONFIG 属性名
# 目的：一次跑就找出哪些属性名正确

set PROJ_DIR "bram_ip_v2_ws"
set OUT_DIR  "ip_repo/ntt_mem_bram"
set PART     "xc7a200t-ffv1156-2"

catch { file delete -force $PROJ_DIR }
catch { file delete -force $OUT_DIR }
file mkdir $PROJ_DIR
file mkdir $OUT_DIR

puts "=== Step 1: create_project ==="
create_project bram_ip_gen_v2 [file normalize $PROJ_DIR] -part $PART -force

puts ""
puts "=== Step 2: create_ip ==="
set result [create_ip \
    -vendor       xilinx.com \
    -library      ip \
    -name         blk_mem_gen \
    -version      8.4 \
    -module_name  ntt_mem_bram \
    -dir          $OUT_DIR]
puts "create_ip result: $result"

set ip_obj [get_ips ntt_mem_bram]
puts "IP obj: $ip_obj (CLASS: [get_property CLASS $ip_obj])"

puts ""
puts "=== Step 3: Probe CONFIG property names ==="
set candidates {
    "CONFIG.Memory_Size"
    "CONFIG.Write_Width_A"
    "CONFIG.Write_Width_B"
    "CONFIG.Read_Width_A"
    "CONFIG.Read_Width_B"
    "CONFIG.Memory_Type"
    "CONFIG.PortA_Way"
    "CONFIG.PortB_Type"
    "CONFIG.use_bram_block"
    "CONFIG.Input_Clock_1"
    "CONFIG.Input_Clock_2"
    "CONFIG.Register_PortA_Output"
    "CONFIG.Register_PortB_Output"
    "CONFIG.Register_PortA_Enable"
    "CONFIG.Register_PortB_Enable"
    "CONFIG.component_name"
    "CONFIG.Component_Name"
    "CONFIG.Init_File_Type"
    "CONFIG.Use_RSTA"
    "CONFIG.PortA_Name"
    "CONFIG.PortB_Name"
    "CONFIG.Read_Port_A_Type"
    "CONFIG.Read_Port_B_Type"
    "CONFIG.Write_Port_A_Type"
    "CONFIG.Write_Port_B_Type"
    "CONFIG.Write_Width_A_Units"
    "CONFIG.Read_Width_A_Units"
    "CONFIG.Read_Width_B_Units"
    "CONFIG.Write_Width_B_Units"
    "CONFIG.Primitive"
    "CONFIG.RAM_SIZE"
    "CONFIG.MemSize"
    "CONFIG.Addra_Width_A"
    "CONFIG.Addr_Width_A"
    "CONFIG.Address_Width_A"
    "CONFIG.Address_Width_B"
}
set valid_props {}
foreach prop $candidates {
    # 用一个安全默认值测试，不覆盖实际配置
    set err ""
    set rc [catch { set_property -quiet $prop {} $ip_obj } err]
    if {$rc == 0} {
        puts "  OK:   $prop"
        lappend valid_props $prop
    } else {
        # 只显示错误首行
        set err_first [split $err "\n"]
        puts "  FAIL: $prop  -> [lindex $err_first 0]"
    }
}

puts ""
puts "=== Step 4: Summary ==="
puts "Valid CONFIG properties: [llength $valid_props]"
foreach p $valid_props { puts "  $p" }

catch { close_project }
exit 0
