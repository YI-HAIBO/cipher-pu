# =============================================================================
# dump_nets.tcl — M4/E30
#
# Dump DCP net names so vcd_to_saif.py can filter the SAIF to real nets only.
#
# Usage:
#   vivado -mode batch -source dump_nets.tcl -tclargs <dcp> <out_txt>
# =============================================================================
set dcp [lindex $argv 0]
set out [lindex $argv 1]

if {![file exists $dcp]} { puts "ERROR: DCP not found: $dcp"; exit 1 }

open_checkpoint $dcp

set fh [open $out w]

set nets [get_nets -hierarchical -quiet]
puts $fh "# nets total: [llength $nets]"
foreach x $nets {
    set nm [get_property NAME $x]
    puts $fh "NET $nm"
}

close $fh
puts "DUMP_OK"
exit
