# run.tcl -- run one test script the way CI does:   tclkit tests/run.tcl tests/some_test.tcl
#
# A Tk-enabled tclkit that hits an uncaught error in its startup script opens a modal
# error box.  On a machine with nobody to click it that hangs the job forever.  This
# wrapper catches everything, writes it to the log (see util.tcl / MKS_TEST_LOG),
# and exits non-zero.  A watchdog also stops a test that never finishes.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
set script [lindex $argv 0]
set argv [lrange $argv 1 end]
proc bgerror {msg} { puts "BACKGROUND ERROR: $msg\n$::errorInfo" ; exit 1 }
set ::timeoutMin [expr {[info exists ::env(MKS_TEST_TIMEOUT)] ? $::env(MKS_TEST_TIMEOUT) : 240}]   ;# seconds
after [expr {$::timeoutMin * 1000}] { puts "TIMEOUT: [lindex $::argv0 0] did not finish within $::timeoutMin seconds" ; exit 3 }
set ws [expr {[llength [info commands tk]] ? [tk windowingsystem] : "no display"}]
puts "== running [file tail $script] on Tcl [info patchlevel] ($ws)"
if {[catch {source $script} err opts]} {
    puts "UNCAUGHT ERROR: $err\n[dict get $opts -errorinfo]"
    exit 1
}
# A script that simply ends has passed.  (A Windows GUI tclkit would otherwise sit in its event loop until the watchdog
# fired: three tests did exactly that for 4 minutes each.)  Tests that need the event loop vwait inside the script.
exit 0
