# child of test_widebig.tcl: add N rows of 1 MiB to column b3 of table t in one commit; says COMMITTING just before it, so the parent can kill it in the middle
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set ::store::durable 0
lassign $argv f n base
set db [store::openFile $f]
set pad [string repeat y 1048560]
for {set i 0} {$i < $n} {incr i} { store::appendRow $db.t {k b3} [list [expr {$base + $i}] "[format %08d [expr {$base + $i}]]$pad"] }
puts COMMITTING ; flush stdout
store::commit $db
puts DONE ; flush stdout
store::closeFile $db
