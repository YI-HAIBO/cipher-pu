# =============================================================================
# e34_rns_netlist.tcl — 方案B A-1: 从 xcku5p RNS ROUTED DCP 导出 funcsim 网表
#
# 输入:  reports/impl/rns_n12_ku5p/e2e_impl_routed.dcp   (1W2R 后 MET, WNS+0.077ns)
# 输出:  scripts/gl_power/out_rns/gl_netlist.v
#         scripts/gl_power/out_rns/gl_ports.txt
#         scripts/gl_power/out_rns/dcp_names.txt
# =============================================================================
set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set DCP  "$PROJ_DIR/reports/impl/rns_n12_ku5p/e2e_impl_routed.dcp"
set OUT  "$PROJ_DIR/scripts/gl_power/out_rns"

file mkdir $OUT

proc log {msg} { puts ">>> $msg"; flush stdout }

if {![file exists $DCP]} { log "ERROR: DCP not found: $DCP"; exit 1 }

log "=== 方案B: RNS routed netlist + net-name dump ==="
open_checkpoint $DCP

# --- port list ---
set fp [open "$OUT/gl_ports.txt" w]
foreach p [get_ports] {
    set dir [get_property DIRECTION $p]
    set w   [get_property WIDTH $p]
    puts $fp "$dir $w $p"
}
close $fp
log "ports -> $OUT/gl_ports.txt"

# --- funcsim netlist ---
write_verilog -mode funcsim -force "$OUT/gl_netlist.v"
log "netlist -> $OUT/gl_netlist.v"

# --- net names (hierarchical, for SAIF filtering) ---
set fn [open "$OUT/dcp_names.txt" w]
set nnets 0
foreach n [get_nets -hierarchical] {
    puts $fn "NET $n"
    incr nnets
}
close $fn
log "nets dumped: $nnets -> $OUT/dcp_names.txt"

set top [get_property top [current_design]]
log "TOP=$top"
log "=== 方案B RNS NETLIST EXPORT COMPLETE ==="
exit
