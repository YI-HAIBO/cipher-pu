# =============================================================================
# e34_routed_power.tcl — E34 step 1: P&R-level power on the routed DCP
#
# Input:  reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp  (Vivado 2026.1, routed)
# Output: reports/experiments/e34_routed_power/e34_routed_default.rpt
#         reports/experiments/e34_routed_power/e34_routed_util.rpt
#
# This upgrades the paper's power story from OOC-synthesis-level to
# place-and-route-level (routing capacitances included) for the default
# (vector-less propagation) activity. A SAIF-annotated routed run follows
# in step 2.
# =============================================================================
set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set DCP  "$PROJ_DIR/reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp"
set OUT  "$PROJ_DIR/reports/experiments/e34_routed_power"

file mkdir $OUT

proc log {msg} { puts ">>> $msg"; flush stdout }

if {![file exists $DCP]} { log "ERROR: DCP not found: $DCP"; exit 1 }

log "=== E34: routed-level power ==="
log "DCP: $DCP"

open_checkpoint $DCP

set state [get_property IS_IMPLEMENTED [current_design]]
log "design state: $state"
set nclk [llength [get_clocks -quiet]]
log "existing clocks: $nclk ([join [get_clocks -quiet] {, }])"

# --- default activity (vector-less propagation) ---
report_power -no_propagation -file "$OUT/e34_routed_default.rpt"
log "default-activity power -> $OUT/e34_routed_default.rpt"

# --- utilization + timing on routed design ---
report_utilization -file "$OUT/e34_routed_util.rpt"
log "utilization -> $OUT/e34_routed_util.rpt"

# --- summary scrape (printed to log for quick grep) ---
set pw [open "$OUT/e34_routed_default.rpt" r]
set txt [read $pw]
close $pw
foreach line [split $txt "\n"] {
    if {[string match "*Total On-Chip Power*" $line] || [string match "*Dynamic*" $line] || [string match "*Device Static*" $line] || [string match "*Clock*" $line] || [string match "*Confidence*" $line]} {
        log "POWER: $line"
    }
}

log "=== E34 STEP1 COMPLETE ==="
exit
