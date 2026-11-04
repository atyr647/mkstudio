# child of test_widebig.tcl: a new process opens the big file read-only and counts: writes "<rows> rows <last k>" to the file named by the second argument
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv f out
set db [store::openFile $f -readonly]
set n [store::size $db.t]
set r "$n rows [lindex [store::rows $db.t {k} 1499 1] 0]"
store::closeFile $db
set h [open $out w] ; puts $h $r ; close $h
# a GUI-subsystem Tk runtime would otherwise stay in its event loop after the script, and the parent that is waiting for this process would wait for ever
exit 0
