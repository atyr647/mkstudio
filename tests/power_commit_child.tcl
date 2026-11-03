# power_commit_child.tcl -- one real commit through MK Studio's store (so with its commit record and syncs); run under
# strace fault injection by test_power_loss.tcl, which kills it at the Nth write to the database file.
#   tclkit tests/power_commit_child.tcl <db>
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set t [store::openFile [lindex $argv 0]]
store::setCell $t.items 7 label "edited label"
store::setCell $t.items 9 gen 41
for {set i 0} {$i < 20} {incr i} { store::appendRow $t.items {id gen label w} [list [expr {900 + $i}] 1 "new $i" 1.5] }
store::commit $t
store::closeFile $t
