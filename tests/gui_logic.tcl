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
# undo / redo of edits, added rows and deleted rows (including subview contents)
set u [::app::openData $tag.employees employees]
set n0 [::store::size $tag.employees]
set before [::store::captureRow $tag.employees 3]
set oldname [::store::cell $tag.employees 3 name]
::ddoc::commit $u 3 name "Changed Name"
check cellundo1 [::store::cell $tag.employees 3 name] "Changed Name"
::ddoc::undo $u
check cellundo2 [::store::cell $tag.employees 3 name] $oldname
::ddoc::redo $u
check cellredo [::store::cell $tag.employees 3 name] "Changed Name"
::ddoc::undo $u
set g2 [::app::docFrame $u].g
::grid::selectLast $g2 ; $g2.t selection set {r3 r4}
set nsub [::store::size $tag.employees]
::ddoc::push $u [list del [list [list 3 [::store::captureRow $tag.employees 3]] [list 4 [::store::captureRow $tag.employees 4]]]]
::store::deleteRows $tag.employees {3 4}
check del1 [::store::size $tag.employees] [expr {$nsub - 2}]
::ddoc::undo $u
check delundo [::store::size $tag.employees] $nsub
check delrestored [::store::captureRow $tag.employees 3] $before
::ddoc::addRow $u
check addundo0 [::store::size $tag.employees] [expr {$nsub + 1}]
::ddoc::undo $u
check addundo1 [::store::size $tag.employees] $nsub
# undo refuses when the data moved underneath it
::ddoc::commit $u 2 name "Zed"
::store::setCell $tag.employees 2 name "Changed elsewhere"
::ddoc::undo $u
check undorefused [::store::cell $tag.employees 2 name] "Changed elsewhere"

# commit then rollback
::app::commit $tag
check clean [::store::dirty $tag] 0
::store::deleteRows $tag.products {0 1 2}
::store::rollback $tag
check rolled [::store::size $tag.products] 9
# designer ops
set d [::app::openDesign $tag.products products]
check addsub [::design::applyChange $d [list ::store::restructure $tag.products [concat [::store::layout $tag.products] [list {tags V {{t S {}}}}]]]] 1
check layout [lindex [::store::layout $tag.products] end 1] V
check rename [::design::applyChange $d [list ::store::rebuildColumn $tag.products price cost D]] 1
check renamed [expr {[::store::findCol [::store::layout $tag.products] cost] ne ""}] 1
check validate [::design::validate $d [dict create name cost]] "A column called 'cost' already exists."
# every popup menu in the app must open (these were silently broken once by a name clash)
set ctx [::app::docFrame $u].g
foreach {what cmd} [list \
    "grid context menu"   [list ::grid::popupMenu $ctx 40 40 300 300] \
    "editor context menu" [list ::editor::popupMenu [::app::docFrame [::app::newQuery "SELECT 1" $tag 0]].ed 300 300] \
    "explorer db menu"    [list ::explorer::onMenu 30 20 200 200] \
    "tab list menu"       [list ::tabs::listMenu .main.center.tabs 300 100] \
    "menubar File"        [list ::menus::openBar .mb.file] \
    "menubar Edit"        [list ::menus::openBar .mb.edit] \
    "menubar View"        [list ::menus::openBar .mb.view] \
    "menubar Query"       [list ::menus::openBar .mb.query] \
    "menubar Help"        [list ::menus::openBar .mb.help] ] {
    set err [catch {uplevel #0 $cmd} msg]
    check "popup: $what ($msg)" [expr {!$err && [::menus::current] ne ""}] 1
    ::menus::closeAll
}
# keyboard navigation of a menu: Down, Down, Return runs the 2nd enabled item
set ::kbd 0
menu .kbtest -tearoff 0
.kbtest add command -label "First" -command {set ::kbd 1}
.kbtest add command -label "Second" -command {set ::kbd 2}
::menus::post .kbtest 100 100
::menus::key Down {} ; ::menus::key Down {} ; ::menus::key Return {}
update
check "menu keyboard" $::kbd 2

# CSV
check csv [::app::parseCsv "a,b\n1,\"x,\"\"y\"\"\"\n"] [list {a b} [list 1 "x,\"y\""]]
# drill-down opens a query tab
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
