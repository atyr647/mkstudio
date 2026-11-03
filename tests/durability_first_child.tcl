# durability_first_child.tcl -- the FIRST commit of a brand-new database through MK Studio's store; killed part-way by
# test_durability.tcl (strace fault injection).      tclkit tests/durability_first_child.tcl <db>
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set t [store::openFile [lindex $argv 0] -create]
store::createView $t items {id:I label:S}
for {set i 0} {$i < 300} {incr i} { store::appendRow $t.items {id label} [list $i "row number $i with some text to fill pages"] }
store::commit $t
store::closeFile $t
