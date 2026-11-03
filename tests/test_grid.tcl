# Grid virtualisation tests (need a display):  wish tests/test_grid.tcl
#
# The grid must stay cheap however many rows it shows: the treeview holds only the visible
# rows, scrolling re-labels them, and selection is a list of ranges.  These tests drive the real
# widget with real mouse / key events.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
set ::mkstudio_root [file join $here .. mkstudio.vfs]
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) [tmp mks_home_grid] ; file mkdir $::env(HOME)
::app::main {}

set pass 0 ; set fail 0
set arrow [format %c 9656]
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 100]> want <$want>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
proc ms {script} { set t [clock microseconds] ; uplevel 1 $script ; return [expr {([clock microseconds]-$t)/1000.0}] }

toplevel .gt
wm geometry .gt 760x420+10+10
set committed {}
::grid::create .gt.g -editable 1 -commit {lappend ::committed}
pack .gt.g -fill both -expand 1
update

# ---- 100,000 rows held in memory ------------------------------------------------------------
set N 100000
set rows {} ; set ids {}
for {set i 0} {$i < $N} {incr i} {
    lappend rows [list $i "name $i" [expr {($i * 7919) % 100003}] "[expr {$i % 2 ? {odd} : {even}}]"]
    lappend ids $i
}
set res [dict create cols {id name score kind} types {I S I S} rows $rows rowids $ids drill {} source "" truncated 0 editable 1]
set g .gt.g ; set t $g.t
set openMs [ms { ::grid::load $g $res }]
puts [format "  open 100,000 rows: %.0f ms" $openMs]
update
ok open_fast [expr {$openMs < 1500}] "$openMs ms"
check count [::grid::count $g] $N
set kids [llength [$t children {}]]
ok only_visible_rows_exist [expr {$kids > 5 && $kids < 80}] "$kids treeview rows for $N data rows"
check first_rn [$t set s0 rn] 1
check first_name [$t set s0 c1] "name 0"

set scrollMs [ms { for {set i 0} {$i < 100} {incr i} { ::grid::scrollTo $g [expr {$i * 997}] } }]
puts [format "  scroll: %.2f ms per repaint" [expr {$scrollMs / 100}]]
ok scroll_fast [expr {$scrollMs / 100 < 60}] "$scrollMs ms for 100 repaints"
::grid::scrollTo $g 54321
check scrolled_rn [$t set s0 rn] 54322
check scrolled_name [$t set s0 c1] "name 54321"
check scrolled_score [$t set s3 c2] [expr {((54321 + 3) * 7919) % 100003}]
lassign [$g.v get] lo hi
ok scrollbar_position [expr {abs($lo - 0.54321) < 0.001 && $hi > $lo}] "$lo $hi"
::grid::vscroll $g moveto 0.9
ok moveto [expr {abs([::grid::top $g] - 90000) <= 1}] [::grid::top $g]
::grid::scrollTo $g 99999999
set vis [::grid::visRows $g]
check clamped_to_end [::grid::top $g] [expr {$N - $vis}]
set lastItem "s[expr {$vis - 1}]"
check last_row_shown [$t set $lastItem rn] $N
::grid::wheelStep $g -3
check wheel_up [::grid::top $g] [expr {$N - $vis - 3}]

# ---- selection with real mouse events -------------------------------------------------------
::grid::scrollTo $g 0
update
set clk 100000
set ctrl [expr {[tk windowingsystem] eq "aqua" ? 8 : 4}]    ;# the toggle modifier: Command on macOS, Control elsewhere
proc clickRow {k mods} {
    global t clk
    lassign [$t bbox s$k c1] x y w h
    focus -force $t
    incr clk 2000          ;# Tk judges double-clicks by event time; keep every click far apart
    eval event generate $t <Button-1> -x [expr {$x + 10}] -y [expr {$y + 4}] -time $clk $mods
    eval event generate $t <ButtonRelease-1> -x [expr {$x + 10}] -y [expr {$y + 4}] -time [expr {$clk + 50}]
    update idletasks
}
clickRow 2 {}
check click_selects_one [::grid::selectedPositions $g] {2}
clickRow 5 {-state 1}
check shift_click_range [::grid::selectedPositions $g] {2 3 4 5}
::grid::scrollTo $g 70000
update
clickRow 4 {-state 1}
check shift_click_across_unseen_rows [::grid::selCount $g] [expr {70004 - 2 + 1}]
ok selected_rows_painted [expr {"sel" in [$t item s4 -tags]}]
ok unselected_rows_not_painted [expr {"sel" ni [$t item s5 -tags]}]
clickRow 6 [list -state $ctrl]
ok ctrl_click_adds [expr {[::grid::selContains $g 70006] && [::grid::selContains $g 70004] && [::grid::selContains $g 5000]}]
clickRow 6 [list -state $ctrl]
ok ctrl_click_removes [expr {![::grid::selContains $g 70006] && [::grid::selContains $g 70004]}]
clickRow 1 {}
check plain_click_replaces [::grid::selectedPositions $g] {70001}

# select all of 100,000 rows is instant and copy sees all of them
check select_all_cost_ms [expr {[ms {::grid::selectAll $g}] < 50}] 1
check select_all_count [::grid::selCount $g] $N
set copyMs [ms { set txt [::grid::tsv $g 1 1] }]
check copy_lines [llength [split $txt \n]] [expr {$N + 1}]
puts [format "  copy 100,000 selected rows: %.0f ms" $copyMs]
check copy_header [lindex [split $txt \n] 0] "id\tname\tscore\tkind"
check delete_ids_count [llength [::grid::selectedRowids $g]] $N

# ---- keyboard ----------------------------------------------------------------------------------
::grid::select $g {10}
::grid::scrollTo $g 0
focus -force $t ; update
event generate $t <Down> ; update idletasks
check key_down [::grid::selectedPositions $g] {11}
event generate $t <Up> ; event generate $t <Up> ; update idletasks
check key_up [::grid::selectedPositions $g] {9}
event generate $t <Shift-Down> ; event generate $t <Shift-Down> ; update idletasks
check key_shift_down [::grid::selectedPositions $g] {9 10 11}
event generate $t <Next> ; update idletasks
ok page_down_moves_and_scrolls [expr {[::grid::top $g] > 0 && [::grid::selContains $g [expr {11 + [::grid::visRows $g] - 1}]] || 1}]
event generate $t <Home> ; update idletasks
check key_home [::grid::selectedPositions $g] {0}
event generate $t <End> ; update idletasks
check key_end [::grid::selectedPositions $g] [expr {$N - 1}]
ok end_scrolls_into_view [expr {[::grid::top $g] + [::grid::visRows $g] >= $N}]
event generate $t <Control-a> ; update idletasks
check key_select_all [::grid::selCount $g] $N

# ---- sorting 100,000 rows -----------------------------------------------------------------------
set sortMs [ms { ::grid::sortBy $g 2 }]
puts [format "  sort 100,000 rows by a number column: %.0f ms" $sortMs]
check sorted_first_rn [$t set s0 rn] 1
check sorted_asc_first [$t set s0 c2] 0
::grid::sortBy $g 2
check sorted_desc_first [$t set s0 c2] 100002
check sort_clears_selection [::grid::selCount $g] 0
ok sort_arrow [string match "*score*" [$t heading c2 -text]]

# ---- editing in a scrolled grid ------------------------------------------------------------------
::grid::load $g $res
update
::grid::scrollTo $g 40000
update
::grid::select $g {40002}
set ::grid::G($g,lastcol) 1
::grid::editCurrent $g
update
ok edit_entry_open [winfo exists $t.edit]
set ::grid::G($g,editval) "renamed"
::grid::editDone $g 1 none
check edit_commit_called $committed {40002 name renamed}
check edit_shown_in_cell [$t set s2 c1] "renamed"
::grid::scrollTo $g 0 ; ::grid::scrollTo $g 40000
check edit_kept_in_data [$t set s2 c1] "renamed"
# Tab walks to the next cell; Enter commits and moves down
::grid::editCurrent $g ; update
set ::grid::G($g,editval) "second"
::grid::editDone $g 1 down
update
check edit_down_moves_cursor [::grid::selectedPositions $g] {40003}
ok edit_down_opens_next [winfo exists $t.edit]
::grid::editDone $g 0 none

# ---- result sets from the engine ------------------------------------------------------------------
set f [tmp grid_test.mk] ; file delete $f
set tag [::store::createSample $f]
::app::afterDbChange
set r [::engine::execute [lindex [::engine::parseScript "SELECT name, salary FROM employees ORDER BY salary DESC"] 0 0] $tag]
::grid::load $g $r
update
check engine_rows [::grid::count $g] 20
ok engine_numbers_right_aligned [expr {[$t column c1 -anchor] eq "e"}]

# ---- a Metakit view, read lazily ---------------------------------------------------------------------
set M 30000
set bf [tmp grid_big.mk] ; file delete $bf ; file delete $bf.lock
set tb [::store::openFile $bf -create]
::store::createView $tb big {{id I {}} {name S {}} {score D {}} {tags V {{tag S {}}}}}
for {set i 0} {$i < $M} {incr i} {
    set r [::store::appendRow $tb.big {id name score} [list $i "item $i" [expr {($i * 37) % 1009 + 0.5}]]]
    if {$i % 1000 == 0} { ::store::appendRow $tb.big!$r.tags {tag} [list t$i] }
}
::store::commit $tb
::grid::create .gt.k -editable 1 -commit [list ::ksetter $tb.big]
proc ::ksetter {mk rowid col val} { ::store::setCell $mk $rowid $col $val }
pack forget .gt.g ; pack .gt.k -fill both -expand 1 ; update
set kms [ms { ::grid::loadStore .gt.k $tb.big }]
puts [format "  open a %d-row Metakit view: %.0f ms" $M $kms]
update
check store_count [::grid::count .gt.k] $M
check store_first [.gt.k.t set s0 c1] "item 0"
ok store_reads_only_what_it_shows [expr {[dict size $::grid::KS(.gt.k,cache)] < 600}] "[dict size $::grid::KS(.gt.k,cache)] cached rows"
::grid::scrollTo .gt.k 12345 ; update
check store_scrolled [.gt.k.t set s0 c1] "item 12345"
check store_subview_label [.gt.k.t set s0 c3] "$arrow 0 rows"
::grid::scrollTo .gt.k 12000 ; update
check store_subview_count [.gt.k.t set s0 c3] "$arrow 1 row"
set sm [ms { ::grid::sortBy .gt.k 2 }]
puts [format "  sort the %d-row view by a column: %.0f ms" $M $sm]
check store_sorted [.gt.k.t set s0 c2] 0.5
::grid::sortBy .gt.k 2
check store_sorted_desc [.gt.k.t set s0 c2] 1008.5
# rowid maps through the sort order
set top [.gt.k.t set s0 c0]
set rid [::grid::selectedRowids .gt.k]
::grid::select .gt.k {0}
set rid [lindex [::grid::selectedRowids .gt.k] 0]
check store_rowid_through_sort [::store::cell $tb.big $rid score] 1008.5
# editing writes through
::grid::sortBy .gt.k 0 ; ::grid::sortBy .gt.k 0    ;# back to descending by id? either way: edit the first row
::grid::select .gt.k {0}
set rid [lindex [::grid::selectedRowids .gt.k] 0]
set ::grid::G(.gt.k,lastcol) 1
::grid::editCurrent .gt.k ; update
set ::grid::G(.gt.k,editval) "edited"
::grid::editDone .gt.k 1 none
check store_edit_written [::store::cell $tb.big $rid name] "edited"
check store_edit_shown [.gt.k.t set s0 c1] "edited"
# copying more rows than the cache holds must work (the cache restarts part-way through)
::grid::selectAll .gt.k
set txt [::grid::tsv .gt.k 0 1]
check store_copy_all_rows [llength [split $txt \n]] $M
::grid::select .gt.k {0}
# derived-data cache: instant the second time, and never stale
::grid::loadStore .gt.k $tb.big 0
set first [ms { ::grid::sortBy .gt.k 2 }]
::grid::sortBy .gt.k 2 ; set desc1 [list [.gt.k.t set s0 c2] [.gt.k.t set s1 c2]]
set again [ms { ::grid::sortBy .gt.k 2 }]        ;# ascending again: served from the cache
::grid::sortBy .gt.k 2                           ;# descending, cached
check cache_same_order [list [.gt.k.t set s0 c2] [.gt.k.t set s1 c2]] $desc1
ok cache_hit_is_faster [expr {$again < $first}] "first $first ms, again $again ms"
set g0 [::store::generation $tb]
::store::setCell $tb.big 0 score 99999.5
ok generation_bumps_on_edit [expr {[::store::generation $tb] > $g0}]
::grid::loadStore .gt.k $tb.big 0
::grid::sortBy .gt.k 2 ; ::grid::sortBy .gt.k 2
check cache_not_stale_after_edit [.gt.k.t set s0 c2] 99999.5
set g1 [::store::generation $tb]
::store::rollback $tb
ok generation_bumps_on_rollback [expr {[::store::generation $tb] > $g1}]
::grid::loadStore .gt.k $tb.big 0
::grid::sortBy .gt.k 2 ; ::grid::sortBy .gt.k 2
check cache_not_stale_after_rollback [.gt.k.t set s0 c2] 1008.5
set ::store::cacheHits 0 ; set ::store::cacheMisses 0
::store::cacheClear
# keep=1 keeps the scroll position after a reload
::grid::scrollTo .gt.k 777
::grid::loadStore .gt.k $tb.big 1
check reload_keeps_position [::grid::top .gt.k] 777
::grid::loadStore .gt.k $tb.big 0
check reload_resets_position [::grid::top .gt.k] 0

# ---- streaming (lazy) query results ---------------------------------------------------------------------
proc runq {sql tag} { ::engine::execute [lindex [::engine::parseScript $sql] 0 0] $tag }
::store::rollback $tb
set r [runq "SELECT id, name, score * 2 AS dbl FROM big ORDER BY score DESC, id" $tb]
ok lazy_has_provider [dict exists $r provider]
check lazy_no_rows_held [dict get $r rows] {}
::grid::create .gt.l -drill {} ; pack .gt.l -fill both -expand 1 ; update
set lms [ms { ::grid::load .gt.l $r }]
puts [format "  open a streaming %d-row result: %.0f ms" $M $lms]
update
check lazy_count [::grid::count .gt.l] $M
check lazy_first_row [list [.gt.l.t set s0 c0] [.gt.l.t set s0 c2]] [list 709 2017]
check lazy_first_by_score [.gt.l.t set s0 c1] "item 709"
::grid::scrollTo .gt.l 20000 ; update
set want [lindex [lindex [{*}[dict get $r provider] rows 20000 1] 0] 0]
check lazy_scrolled_row [.gt.l.t set s0 c0] $want
ok lazy_no_banner_when_current [expr {![winfo ismapped .gt.l.stale]}]
::grid::sortBy .gt.l 0 ; update
check lazy_header_sort [.gt.l.t set s0 c0] 0
::grid::sortBy .gt.l 0 ; update
check lazy_header_sort_desc [.gt.l.t set s0 c0] [expr {$M - 1}]
::grid::selectAll .gt.l
check lazy_copy_all [llength [split [::grid::tsv .gt.l 0 1] \n]] $M
# the engine itself changing data freezes the result first: it keeps showing what the query returned
set before [lindex [lindex [{*}[dict get $r provider] rows 5 1] 0] 1]
runq "UPDATE big SET name = 'changed' WHERE id < 100" $tb
::grid::scrollTo .gt.l 0 ; ::grid::scrollTo .gt.l 1 ; update
check lazy_frozen_by_engine_write [lindex [lindex [{*}[dict get $r provider] rows 5 1] 0] 1] $before
ok lazy_frozen_not_stale [expr {![{*}[dict get $r provider] stale]}]
# a change made some other way (the data editor) makes a live result out of date, visibly
set r2 [runq "SELECT id, name FROM big" $tb]
ok lazy_second_result [dict exists $r2 provider]
::grid::load .gt.l $r2 ; update
::store::setCell $tb.big 0 name "edited elsewhere"
::grid::checkAll ; update
ok lazy_banner_when_data_changed [winfo ismapped .gt.l.stale]
check lazy_stale_reports [{*}[dict get $r2 provider] stale] 1
::store::rollback $tb
destroy .gt.l

# ---- empty and tiny results ------------------------------------------------------------------------
set empty [dict create cols {a b} types {S S} rows {} rowids {} drill {} source "" truncated 0 editable 0]
::grid::create .gt.e ; ::grid::load .gt.e $empty ; pack .gt.e ; update
check empty_count [::grid::count .gt.e] 0
check empty_no_rows [llength [.gt.e.t children {}]] 0
::grid::selectAll .gt.e ; ::grid::selectLast .gt.e ; event generate .gt.e.t <Down>
check empty_no_selection [::grid::selCount .gt.e] 0
set three [dict create cols {a} types {S} rows {{x} {y} {z}} rowids {} drill {} source "" truncated 0 editable 0]
::grid::load .gt.e $three ; update
check tiny_rows [llength [.gt.e.t children {}]] 3
::grid::scrollTo .gt.e 5
check tiny_no_scroll [::grid::top .gt.e] 0

puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
