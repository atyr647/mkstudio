# child of test_widebig.tcl: a new process opens the big file read-only and counts: prints "<rows> rows <last k>"
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set db [store::openFile [lindex $argv 0] -readonly]
set n [store::size $db.t]
puts "$n rows [lindex [store::rows $db.t {k} 1499 1] 0]"
store::closeFile $db
