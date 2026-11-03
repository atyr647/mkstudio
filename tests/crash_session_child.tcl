# crash_session_child.tcl -- a "running copy of MK Studio" for test_crash.tcl: starts a session, leaves breadcrumbs, then waits to be killed.
#   tclkit tests/crash_session_child.tcl <crash-dir> <ready-file>
set here [file dirname [file normalize [info script]]]
set ::env(MKS_CRASH_DIR) [lindex $argv 0]
foreach f {version store crash} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
::crash::start
::crash::crumb "database opened"
::crash::crumb "query executed"
::crash::crumb "committed"
set h [open [lindex $argv 1] w] ; puts $h ready ; close $h
after 60000 exit
vwait forever
