# mkit-sql as MK Studio's query language: is it really wired through the ::engine seam, store, UI and lock?
#   REAL_MK=1 xvfb-run -a tclkit tests/run.tcl tests/test_engine_wiring.tcl
# (MKS_ENGINE=mkql would start the program with the built-in dialect instead; this test is about the default.)
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
set ::mkstudio_root [file join $here .. mkstudio.vfs]
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) [tmp mks_home_wiring] ; file mkdir $::env(HOME)
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 200]> want <[string range $want 0 200]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
proc run1 {sql db} { set p [lindex [::engine::parseScript $sql] 0] ; return [::engine::execute [lindex $p 0] $db] }

# ---- the engine in the seam ----------------------------------------------------------------------------------------------------
ok engine_is_mkit_sql [string match "mkit-sql * (standard SQL)" $::engine::name] $::engine::name
check engine_version_matches_the_vendored_copy $::mkitsql::version [lindex [split [string trim [read [set h [open $::mkstudio_root/lib/mkitsql/SOURCE r]]]] "\n"] 0 end]
catch {close $h}
ok engine_uses_the_store_backend [expr {$::mkitsql::backend eq "studio"}] $::mkitsql::backend
ok engine_keywords_offered_to_the_editor [expr {"SELECT" in $::engine::keywords && "LIMIT" in $::engine::keywords}]
ok engine_token_pattern_for_the_highlighter [expr {$::engine::tokenRe eq $::mkitsql::tokenRe && [catch {regexp $::engine::tokenRe x}] == 0}]
# Stop button and progress callback are the SAME variables inside the engine (not copies)
set ::engine::cancel 1 ; check cancel_is_shared $::mkitsql::cancel 1 ; set ::engine::cancel 0
check cancel_is_shared_back $::mkitsql::cancel 0

# the list bug of Tcl 8.5 / 8.6.3 is detected (and worked around) only where it exists
if {[package vcompare [info patchlevel] 8.6.4] >= 0} { check list_bug_absent_on_a_current_tcl $::store::listBug 0 } else { check list_bug_present_on_the_2014_runtimes $::store::listBug 1 }

# ---- parsing: offsets for the editor, syntax errors the editor can underline ------------------------------------------------------
set sql "SELECT 1;\nSELECT 2 AS two;"
set parts [::engine::parseScript $sql]
check parse_two_statements [llength $parts] 2
lassign [lindex $parts 1] h first end text
check parse_offsets_cover_the_text [string trim [string range $sql $first [expr {$end - 1}]]] "SELECT 2 AS two"
set rc [catch {::engine::parseScript "SELEC 1"} msg opts]
check syntax_error_raised $rc 1
set code [dict get $opts -errorcode]
check syntax_error_code_family [lrange $code 0 1] {MKQL SYNTAX}
ok syntax_error_has_offset_and_length [expr {[llength $code] >= 4 && [string is integer -strict [lindex $code 2]] && [string is integer -strict [lindex $code 3]]}] $code

# ---- running against a database opened through MK Studio's store -----------------------------------------------------------------
set f [tmp wiring_sample.mk] ; foreach x [glob -nocomplain $f $f.*] { file delete $x }
set tag [::store::createSample $f]
::store::commit $tag
set r [run1 "SELECT name FROM $tag.departments ORDER BY budget DESC LIMIT 2" $tag]
check select_kind [dict get $r kind] rowset
check select_columns [dict get $r cols] {name}
ok select_rows_in_order [expr {[llength [dict get $r rows]] == 2 && [lindex [dict get $r rows] 0 0] eq "Research"}] [dict get $r rows]
set r [run1 "SELECT id, name, skills FROM $tag.employees WHERE id <= 2" $tag]
check subview_column_is_marked [lindex [dict get $r types] 2] V
ok subview_drill_info [expr {[dict get $r drill] ne ""}] $r
# a change made through SQL is a change in MK Studio's open database: dirty, then committed through the SAME store
set dirty0 [::store::dirty $tag]
set r [run1 "INSERT INTO $tag.departments (id, name, location, budget) VALUES (6, 'Wiring', 'Nowhere', 1.5)" $tag]
check insert_kind [dict get $r kind] message
ok store_sees_the_change [expr {[::store::dirty $tag] > $dirty0}]
check row_count_in_the_store [::store::size $tag.departments] 6
::store::commit $tag
ok commit_through_the_store_leaves_no_record [expr {![file exists $f.commit]}]
ok commit_wrote_the_checksum [file exists $f.sum]
ok lock_is_held_while_open [file exists $f.lock]
::store::closeFile $tag
ok lock_released_on_close [expr {![file exists $f.lock]}]
# reopened: the SQL change is really in the file
set tag [::store::openFile $f]
set r [run1 "SELECT COUNT(*) AS n FROM $tag.departments WHERE name = 'Wiring'" $tag]
check change_persisted [lindex [dict get $r rows] 0 0] 1
# ROLLBACK through SQL discards (MK Studio's roll back and the engine's are one mechanism)
run1 "DELETE FROM $tag.departments WHERE id = 6" $tag
run1 "ROLLBACK" $tag
check rollback_restores [::store::size $tag.departments] 6
# MERGE counts as a change for the UI (the patch in docs.tcl) - the kind list names it
set src [read [set h [open $::mkstudio_root/lib/app-mkstudio/docs.tcl r]]] ; close $h
ok ui_refreshes_after_merge [string match "*insert update delete merge create drop alter commit rollback*" $src]
# a damaged-file / second-process view: the engine refuses writes to a file someone else holds
::store::closeFile $tag
set h [open $f.lock w] ; puts -nonewline $h "424242 some-other-machine" ; close $h
set rc [catch {::store::openFile $f} msg opts]
check foreign_lock_refuses_a_writer $rc 1
check foreign_lock_error_code [lrange [dict get $opts -errorcode] 0 1] {STORE LOCKED}
file delete $f.lock
foreach x [glob -nocomplain $f $f.*] { file delete $x }
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
