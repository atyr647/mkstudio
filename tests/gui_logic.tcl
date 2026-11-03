# Drives the real UI code paths that need no dialogs.  wish tests/gui_logic.tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
set ::mkstudio_root [file join $here .. mkstudio.vfs]
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) [tmp mks_home_logic] ; file mkdir $::env(HOME)
::app::main {}
set pass 0 ; set fail 0
proc lmap_file {} { set o {} ; foreach t [::store::tags] { lappend o [::store::path $t] } ; return $o }
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <$got> want <$want>"} }
set f [tmp logic_demo.mk] ; file delete $f
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
::grid::selectLast $g2 ; ::grid::select $g2 {3 4}
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

# the '#' row-number column must keep its own width/alignment after every load (a reconfigure resets it)
set gt [::app::docFrame $u].g.t
check rn_width [expr {[$gt column rn -width] >= 40 && [$gt column rn -width] <= 90}] 1
check rn_anchor [$gt column rn -anchor] e

# Add Column from the data tab: same validation, grid reloads with the new column
set pc [::app::openData $tag.products products]
check addcol_validate [::design::validateMk $tag.products [dict create name sku]] "A column called 'sku' already exists."
check addcol_ok [::design::validateMk $tag.products [dict create name weight]] ""
::store::restructure $tag.products [concat [::store::layout $tag.products] [list {weight D {}}]]
::app::dataChanged 1
check addcol_grid [lindex $::grid::G([::app::docFrame $pc].g,cols) end] weight
# the Add Column button is disabled on subview tabs
set sv [::app::openData $tag.employees!0.skills skills0]
check addcol_disabled_on_subview [[::app::docFrame $sv].bar.col instate disabled] 1
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


# ---- Help menu: updates and crash reports -----------------------------------------------------------------------------------
set labels {}
set last [.mb.help.m index end]
for {set i 0} {$i <= $last} {incr i} { if {[.mb.help.m type $i] ne "separator"} { lappend labels [.mb.help.m entrycget $i -label] } }
check help_updates [expr {"Check for Updates..." in $labels}] 1
check help_auto_updates [expr {"Check for Updates Automatically" in $labels}] 1
check help_crash_folder [expr {"Open Crash Reports Folder" in $labels}] 1
# stub the dialogs: record what was asked, answer with $::answer
set ::asked {} ; set ::answer ""
rename ::ui::ask ::ui::ask_real
proc ::ui::ask {title message {buttons {OK}} {icon ""}} { lappend ::asked [list $title $message $buttons] ; return $::answer }
rename ::ui::problem ::ui::problem_real
proc ::ui::problem {message {title "Something went wrong"}} { lappend ::asked [list $title $message {}] ; return "" }
# a check that fails (no network here, bogus feed): manual check says so
set ::env(MKS_UPDATE_API) file:///nonexistent/releases.json
set ::answer Close
::app::checkUpdates 1
check update_failure_dialog [lindex $::asked end 0] "Check for updates"
check update_failure_text [string match "*could not be completed*" [lindex $::asked end 1]] 1
set n [llength $::asked]
::app::checkUpdates 0                      ;# the quiet check never opens a dialog
check update_quiet_failure_silent [llength $::asked] $n
# a newer release: quiet check only writes the status line, manual check shows the dialog
proc ::update::check {{c ""} {p ""}} { return [dict create version 9.9.9 tag v9.9.9 pre 0 notes "Shiny new things" page https://example.test/r assets {}] }
::app::checkUpdates 0
check update_quiet_status [string match "*9.9.9 is available*" [.sb.msg cget -text]] 1
check update_quiet_no_dialog [llength $::asked] $n
set ::answer Later
::app::checkUpdates 1
check update_dialog_title [lindex $::asked end 0] "Update available"
check update_dialog_notes [string match "*Shiny new things*" [lindex $::asked end 1]] 1
check update_dialog_no_install_from_source [expr {"Update Now" in [lindex $::asked end 2]}] 0
check update_dialog_has_release_page [expr {"Release Page" in [lindex $::asked end 2]}] 1

# ---- a database that no longer matches its checksum --------------------------------------------------------------------------
set df [tmp logic_damaged.mk] ; foreach x [glob -nocomplain $df*] { file delete $x }
set dt [::store::createSample $df] ; ::store::setCell $dt.products 0 name "first save" ; ::store::commit $dt ; ::store::closeFile $dt
set dt [::store::openFile $df] ; ::store::setCell $dt.products 0 name "second save" ; ::store::commit $dt ; ::store::closeFile $dt
check backup_exists [file exists $df.bak] 1
set mt [file mtime $df] ; set h [open $df rb] ; set d [read $h] ; close $h
set pos [expr {[string length $d] / 2}] ; scan [string index $d $pos] %c oc
set h [open $df wb] ; puts -nonewline $h [string replace $d $pos $pos [format %c [expr {($oc + 1) % 256}]]] ; close $h ; file mtime $df $mt
# Cancel: nothing opens
set ::asked {} ; set ::answer Cancel
check damaged_cancel [::app::openOne $df] ""
check damaged_dialog [lindex $::asked 0 0] "Database may be damaged"
check damaged_offers_restore [expr {"Restore Backup" in [lindex $::asked 0 2]}] 1
check damaged_cancel_leaves_closed [expr {$df in [lmap_file]}] 0
# Restore Backup
set ::asked {} ; set ::answer "Restore Backup"
set rt [::app::openOne $df]
check restore_opened [expr {$rt ne ""}] 1
check restore_data_is_the_backup [::store::cell $rt.products 0 name] "first save"
check restore_keeps_damaged [file exists $df.damaged] 1
check restore_status [string match "*Restored*backup*" [.sb.msg cget -text]] 1
::app::closeDB $rt 1
# Open Anyway on a file with no backup
file delete $df.bak ; file delete $df.damaged
set h [open $df rb] ; set d [read $h] ; close $h ; set mt [file mtime $df]
set h [open $df wb] ; puts -nonewline $h [string replace $d $pos $pos [format %c [expr {($oc + 2) % 256}]]] ; close $h ; file mtime $df $mt
set ::asked {} ; set ::answer "Open Anyway"
set at [::app::openOne $df]
check damaged_no_backup_buttons [lindex $::asked 0 2] {"Open Anyway" Cancel}
check damaged_open_anyway [expr {$at ne ""}] 1
if {$at ne ""} { ::app::closeDB $at 1 }
rename ::ui::ask {} ; rename ::ui::ask_real ::ui::ask
rename ::ui::problem {} ; rename ::ui::problem_real ::ui::problem
unset ::env(MKS_UPDATE_API)

# CSV
check csv [::app::parseCsv "a,b\n1,\"x,\"\"y\"\"\"\n"] [list {a b} [list 1 "x,\"y\""]]
# drill-down opens a query tab
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
