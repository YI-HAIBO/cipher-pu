# =============================================================================
# gl_netlist.tcl — M4/E30 Step 1
#
# 从 OOC 综合 DCP 导出 funcsim 门级网表（网名与 DCP 对齐 → SAIF 高标注率）
#
# 输入: reports/synth/prod_blocks_au25p_n12/e2e_ckks_mult_ctrl_m4.dcp (N=2^12)
# 输出: scripts/gl_power/out/gl_netlist.v
#       scripts/gl_power/out/gl_ports.txt   （端口清单，供 TB 适配）
# =============================================================================
set PROJ_DIR "[file normalize [file dirname [file dirname [file dirname [info script]]]]]"
set DCP  "$PROJ_DIR/reports/synth/prod_blocks_au25p_n12/e2e_ckks_mult_ctrl_m4.dcp"
set OUT  "$PROJ_DIR/scripts/gl_power/out"

file mkdir $OUT

proc log {msg} { puts ">>> $msg"; flush stdout }

log "=== M4/E30: export funcsim netlist ==="
log "DCP: $DCP"

if {![file exists $DCP]} { log "ERROR: DCP not found"; exit 1 }

open_checkpoint $DCP

# --- 端口清单导出（供 TB 适配）---
set fp [open "$OUT/gl_ports.txt" w]
foreach p [get_ports] {
    set dir [get_property DIRECTION $p]
    set w   [get_property WIDTH $p]
    puts $fp "$dir $w $p"
}
close $fp
log "port list -> $OUT/gl_ports.txt"

# --- funcsim 网表 ---
write_verilog -mode funcsim -force "$OUT/gl_netlist.v"
log "netlist  -> $OUT/gl_netlist.v"

# --- 顶层模块名确认 ---
set top [get_property top [current_design]]
log "TOP=$top"

log "=== NETLIST EXPORT COMPLETE ==="
exit 0
