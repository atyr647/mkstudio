# Drives the real UI code paths that need no dialogs.  wish tests/gui_logic.tcl
set here [file dirname [file normalize [info script]]]
set ::mkstudio_root [file join $here .. mkstudio.vfs]
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) /tmp/mks_home_logic ; file mkdir $::env(HOME)
::app::main {}
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <$got> want <$want>"} }
set f /tmp/logic_demo.mk ; file delete $f
set tag [::store::createSample $f] ; ::app::afterDbChange
# data doc: edit, reject bad value, add row
set id [::app::openData $tag.products products]
set g [::app::docFrame $id].g
check rows [::grid::count $g] 8
check edit [catch {::ddoc::commit $id 0 name "Renamed"}] 0
check edited [lindex [::store::rows $tag.products {name} 0 1] 0 0] Renamed
check badint [catch {::ddoc::commit $id 0 stock "lots"} m] 1
check badmsg [string match "*holds whole numbers*" $m] 1
::ddoc::addRow $id
check added [::store::size $tag.products] 9
check gridnew [::grid::count $g] 9
check pending [expr {[::store::dirty $tag] > 0}] 1
# commit then rollback
::app::commit $tag
check clean [::store::dirty $tag] 0
::store::deleteRows $tag.products {0 1 2}
::store::rollback $tag
check rolled [::store::size $tag.products] 9
# designer ops
set d [::app::openDesign $tag.products products]
check addsub [::design::apply $d [list ::store::restructure $tag.products [concat [::store::layout $tag.products] [list {tags V {{t S {}}}}]]]] 1
check layout [lindex [::store::layout $tag.products] end 1] V
check rename [::design::apply $d [list ::store::rebuildColumn $tag.products price cost D]] 1
check renamed [expr {[::store::findCol [::store::layout $tag.products] cost] ne ""}] 1
check validate [::design::validate $d [dict create name cost]] "A column called 'cost' already exists."
# CSV
check csv [::app::parseCsv "a,b\n1,\"x,\"\"y\"\"\"\n"] [list {a b} [list 1 "x,\"y\""]]
# drill-down opens a query tab
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
