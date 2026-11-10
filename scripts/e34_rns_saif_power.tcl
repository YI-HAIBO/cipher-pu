# =============================================================================
# e34_rns_saif_power.tcl — 方案B A-1 步骤5: SAIF-annotated report_power on RNS ROUTED DCP
#
# Input:  reports/impl/rns_n12_ku5p/e2e_impl_routed.dcp
#         scripts/gl_power/out_rns/routed.saif
# Output: reports/experiments/e34_rns_power/e34_rns_saif.rpt
# =============================================================================
set PROJ_DIR "[file normalize [file dirname [file dirname [info script]]]]"
set DCP  "$PROJ_DIR/reports/impl/rns_n12_ku5p/e2e_impl_routed.dcp"
set SAIF "$PROJ_DIR/scripts/gl_power/out_rns/routed.saif"
set OUT  "$PROJ_DIR/reports/experiments/e34_rns_power"

file mkdir $OUT

proc log {msg} { puts ">>> $msg"; flush stdout }

if {![file exists $DCP]}  { log "ERROR: DCP not found: $DCP";  exit 1 }
if {![file exists $SAIF]} { log "ERROR: SAIF not found: $SAIF"; exit 1 }

open_checkpoint $DCP

log "=== 方案B: SAIF power on RNS routed DCP ==="
log "SAIF: $SAIF"

read_saif -strip_path e2e_rns_top $SAIF

report_power -file "$OUT/e34_rns_saif.rpt" -l 40

# --- summary scrape ---
set pw [open "$OUT/e34_rns_saif.rpt" r]
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
log "=== 方案B RNS STEP 5 COMPLETE ==="
exit
