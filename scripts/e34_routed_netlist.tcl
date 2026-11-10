# =============================================================================
# e34_routed_netlist.tcl — E34 step 2a: export funcsim netlist + net names
#                             from the ROUTED DCP
#
# Input:  reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp
# Output: scripts/gl_power/out_routed/gl_netlist.v
#         scripts/gl_power/out_routed/gl_ports.txt
#         scripts/gl_power/out_routed/dcp_names.txt   (NET <name> per line)
# =============================================================================
set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set DCP  "$PROJ_DIR/reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp"
set OUT  "$PROJ_DIR/scripts/gl_power/out_routed"

file mkdir $OUT

proc log {msg} { puts ">>> $msg"; flush stdout }

if {![file exists $DCP]} { log "ERROR: DCP not found: $DCP"; exit 1 }

log "=== E34 step 2a: routed netlist + net-name dump ==="
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
log "=== E34 STEP 2A COMPLETE ==="
exit
