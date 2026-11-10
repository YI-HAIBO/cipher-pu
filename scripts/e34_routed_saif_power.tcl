# =============================================================================
# e34_routed_saif_power.tcl — E34 step 2e: SAIF-annotated report_power on the
#                             ROUTED DCP
#
# Usage: vivado -mode batch -source e34_routed_saif_power.tcl
# =============================================================================
set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set DCP  "$PROJ_DIR/reports/impl/e2e_au25p_n12/e2e_impl_routed.dcp"
set SAIF "$PROJ_DIR/scripts/gl_power/out_routed/routed.saif"
set OUT  "$PROJ_DIR/reports/experiments/e34_routed_power"

proc log {msg} { puts ">>> $msg"; flush stdout }

if {![file exists $DCP]}  { log "ERROR: DCP not found: $DCP";  exit 1 }
if {![file exists $SAIF]} { log "ERROR: SAIF not found: $SAIF"; exit 1 }

open_checkpoint $DCP

log "=== E34 step 2e: SAIF power on routed DCP ==="
log "SAIF: $SAIF"

read_saif -strip_path e2e_ckks_mult_ctrl_m4 $SAIF

report_power -file "$OUT/e34_routed_saif.rpt" -l 40

# --- summary scrape ---
set pw [open "$OUT/e34_routed_saif.rpt" r]
set txt [read $pw]
close $pw
foreach line [split $txt "\n"] {
    if {[string match "*Total On-Chip Power*" $line] || [string match "*Dynamic*" $line] ||
        [string match "*Device Static*" $line] || [string match "*Confidence*" $line] ||
        [string match "*CLK%" $line] || [string match "*LOGIC*" $line] ||
        [string match "*BRAM*" $line] || [string match "*DSP*" $line]} {
        log "POWER: $line"
    }
}
log "=== E34 STEP 2E COMPLETE ==="
exit
