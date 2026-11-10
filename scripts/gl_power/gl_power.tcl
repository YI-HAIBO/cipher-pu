# =============================================================================
# gl_power.tcl — M4/E30: SAIF-driven report_power on the OOC synthesis DCP
#
# Why the OOC synthesis DCP (not the routed M5 DCP):
#   write_verilog -mode funcsim keeps RTL net names on a synthesis DCP
#   (read_saif annotation ~99%), while post-route funcsim drops internal
#   net names (~6% annotation). Power on a synth DCP lacks routing loads,
#   so the absolute number is an estimate; the operating frequency is the
#   100 MHz (10 ns) constraint already present in the DCP, matching the
#   gate-level TB clock.
#
# Usage:
#   vivado -mode batch -source gl_power.tcl -tclargs <dcp> <saif> <out_rpt>
# =============================================================================
set dcp  [lindex $argv 0]
set saif [lindex $argv 1]
set rpt  [lindex $argv 2]

if {![file exists $dcp]}  { puts "ERROR: DCP not found: $dcp";  exit 1 }
if {![file exists $saif]} { puts "ERROR: SAIF not found: $saif"; exit 1 }

open_checkpoint $dcp

# --- sanity: clock exists (period 10 ns = 100 MHz, from OOC synthesis) ---
set nclk [llength [get_clocks -quiet]]
puts ">>> existing clocks: $nclk  ([join [get_clocks -quiet] {, }])"

# --- baseline: vector-less propagation (worst-case switching) ---
report_power -no_propagation -file ${rpt}_default.rpt

# --- read SAIF; strip_path = SAIF (DESIGN "...") header = DCP top name ---
set unmatched [file rootname $saif].unmatched.txt
set saif_design ""
set fh [open $saif r]
while {[gets $fh line] >= 0} {
    if {[string match "*DESIGN*" $line]} {
        set parts [split $line " "]
        foreach p $parts {
            if {[string match {*\"*} $p]} {
                set saif_design [string trim $p {"\t\r\n()}]
                break
            }
        }
        break
    }
}
close $fh
if {$saif_design eq ""} { puts "ERROR: could not read DESIGN from SAIF"; exit 1 }
puts ">>> SAIF design: $saif_design"

if {[catch {read_saif -strip_path $saif_design -out_file $unmatched $saif} err]} {
    puts "ERROR: read_saif failed: $err"
    exit 1
}

# annotation coverage from the unmatched file
if {[file exists $unmatched]} {
    set fh2 [open $unmatched r]
    set unmatched_txt [read $fh2]
    close $fh2
    foreach line [split $unmatched_txt "\n"] {
        if {[string match "*nets*" $line] || [string match "*match*" $line]} {
            puts ">>> unmatched: $line"
        }
    }
}

report_power -file $rpt -l 40

puts ">>> GL_POWER_OK"
exit
