# Lifetime of streaming results and of the derived-data cache:  tclkit tests/test_provider_lifecycle.tcl
#
# A streaming result reads live data.  The rule under test: it must be IMPOSSIBLE for it to return rows
# from a different database state than the one the query saw - after edits, restructuring, Roll Back,
# closing and reopening the file, a second database, a destroyed result. It either keeps showing exactly
# what the query returned (frozen) or says it is stale and returns nothing.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 120]> want <[string range $want 0 120]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
set ::mkql::lazyMin 50
set N 400

proc mkdb {name} {
    global N
    set f [tmp $name] ; foreach x [glob -nocomplain $f*] { file delete $x }
    set t [store::openFile $f -create]
    store::createView $t t {{id I {}} {name S {}} {score D {}}}
    for {set i 0} {$i < $N} {incr i} { store::appendRow $t.t {id name score} [list $i "row $i" [expr {$i * 1.5}]] }
    store::commit $t
    return [list $t $f]
}
proc query {sql tag} { mkql::run $sql $tag }
proc prov {res} { dict get $res provider }
proc firstRows {p {n 3}} { {*}$p rows 0 $n }

lassign [mkdb lifecycle_a.mk] A fa
set rA [query "SELECT id, name FROM t" $A]
set P [prov $rA]
ok provider_is_lazy [dict exists $rA provider]
check fresh_count [{*}$P count] $N
check fresh_not_stale [{*}$P stale] 0
set want [firstRows $P]
check fresh_first_row [lindex $want 0] {0 {row 0}}
store::commit $A
check commit_does_not_invalidate [{*}$P stale] 0

# ---- every kind of change makes the result stale, and a stale result returns NOTHING ----------------------
proc staleAfter {name script} {
    global A
    set r [query "SELECT id, name FROM t" $A] ; set p [prov $r]
    uplevel #0 $script
    check "$name: stale" [{*}$p stale] 1
    check "$name: no rows from another state" [{*}$p rows 0 5] {}
    check "$name: cell" [{*}$p cell 0 1] ""
    {*}$p destroy
}
staleAfter edit_cell { store::setCell $A.t 3 name "changed" }
store::rollback $A
staleAfter append_row { store::appendRow $A.t {id name score} [list 999 x 1.0] }
store::rollback $A
staleAfter delete_rows { store::deleteRows $A.t {1 2 3} }
store::rollback $A
staleAfter restructure { store::restructure $A.t [concat [store::layout $A.t] [list {extra I {}}]] }
store::rollback $A
staleAfter other_view { store::createView $A other {{x I {}}} }
store::rollback $A
set r [query "SELECT id, name FROM t" $A] ; set p [prov $r]
store::setCell $A.t 0 name "edited"
store::rollback $A
check rollback_makes_stale_even_though_data_equals_original [{*}$p stale] 1
{*}$p destroy

# ---- the engine's own writes freeze live results first --------------------------------------------------------
set r [query "SELECT id, name FROM t ORDER BY id DESC" $A] ; set p [prov $r]
set before [{*}$p rows 0 400]
query "UPDATE t SET name = 'zzz' WHERE id < 100" $A
check frozen_by_update [{*}$p rows 0 400] $before
check frozen_not_stale [{*}$p stale] 0
query "DELETE FROM t WHERE id >= 300" $A
check frozen_by_delete [{*}$p rows 0 400] $before
check frozen_count_unchanged [{*}$p count] $N
check frozen_rowid [{*}$p rowid 0] [expr {$N - 1}]
{*}$p sort 0 asc I
check frozen_sort_works [lindex [{*}$p rows 0 1] 0] {0 {row 0}}
{*}$p freeze                                    ;# idempotent
check freeze_twice_harmless [{*}$p count] $N
{*}$p destroy
store::rollback $A
# a SELECT does not freeze (nothing changed)
set r [query "SELECT id, name FROM t" $A] ; set p [prov $r]
query "SELECT COUNT(*) FROM t" $A
check select_keeps_live [{*}$p stale] 0
{*}$p destroy

# ---- closing the database --------------------------------------------------------------------------------------------------
set r [query "SELECT id, name FROM t" $A] ; set p [prov $r]
set before [{*}$p rows 0 400]
store::closeFile $A
check close_freezes_results [{*}$p rows 0 400] $before
check close_frozen_not_stale [{*}$p stale] 0
# reopen the SAME file: the frozen result is unaffected by what happens to the new handle
set A [store::openFile $fa]
store::setCell $A.t 0 name "after reopen"
check frozen_ignores_reopened_db [lindex [{*}$p rows 0 1] 0] {0 {row 0}}
{*}$p destroy
# too big to freeze (forced small limit): stays live, so closing makes it stale - and reopening must NOT revive it
set old $::mkql::freezeMax ; set ::mkql::freezeMax 10
store::rollback $A
set r [query "SELECT id, name FROM t" $A] ; set p [prov $r]
store::closeFile $A
check unfrozen_closed_is_stale [{*}$p stale] 1
check unfrozen_closed_returns_nothing [{*}$p rows 0 5] {}
set A [store::openFile $fa]                       ;# same file, probably the same tag name
check unfrozen_reopened_still_stale [{*}$p stale] 1
check unfrozen_reopened_returns_nothing [{*}$p rows 0 5] {}
set ::mkql::freezeMax $old
{*}$p destroy

# ---- two databases don't disturb each other --------------------------------------------------------------------------------------
lassign [mkdb lifecycle_b.mk] B fb
set rA [query "SELECT id FROM t" $A] ; set rB [query "SELECT id FROM t" $B]
set pa [prov $rA] ; set pb [prov $rB]
store::setCell $A.t 0 name "x"
check other_db_edit_stales_this [{*}$pa stale] 1
check other_db_edit_leaves_that_alone [{*}$pb stale] 0
store::closeFile $B
check closing_b_freezes_b [{*}$pb stale] 0
check closing_b_leaves_a_stale_state [{*}$pa stale] 1
{*}$pa destroy ; {*}$pb destroy

# ---- destroyed results behave ----------------------------------------------------------------------------------------------------------
set r [query "SELECT id FROM t" $A] ; set p [prov $r]
{*}$p destroy
check destroyed_count [{*}$p count] 0
check destroyed_stale [{*}$p stale] 1
check destroyed_rows [{*}$p rows 0 5] {}
check destroyed_destroy_again [catch {{*}$p destroy}] 0
check destroyed_sort_errors [catch {{*}$p sort 0 asc I}] 1

# ---- generations never repeat -----------------------------------------------------------------------------------------------------------------
set seen {}
proc note {tag} { global seen ; lappend seen [store::generation $tag] }
store::rollback $A
note $A ; store::setCell $A.t 1 name q ; note $A ; store::rollback $A ; note $A
store::commit $A ; note $A
store::closeFile $A ; lappend seen [store::generation $A]
set A [store::openFile $fa] ; note $A ; store::closeFile $A
set A [store::openFile $fa] ; note $A
set changing [lsearch -all -inline -not $seen -1]
check generation_unique_while_open [llength [lsort -unique $changing]] [expr {[llength $changing] - 1}]   ;# (a commit leaves it as it was: exactly one repeat)
check generation_minus_one_when_closed [lindex $seen 4] -1
store::closeFile $A

# ---- the derived-data cache ---------------------------------------------------------------------------------------------------------------------
lassign [mkdb cache_a.mk] CA fca
lassign [mkdb cache_b.mk] CB fcb
store::cacheClear
set ::store::cacheHits 0 ; set ::store::cacheMisses 0 ; set ::store::cacheEvictions 0
set big [lrepeat 1000 "some text value"]
set cost [store::estimateBytes $big]
ok estimate_is_plausible [expr {$cost > 1000 * 40 && $cost < 1000 * 200}] $cost
store::cacheConfigure -budget [expr {($cost * 2.5) / 1048576.0}]        ;# room for two
store::cachePut $CA [list a] $big ; store::cachePut $CA [list b] $big
check two_fit [dict get [store::cacheStats] entries] 2
store::cacheGet $CA [list a]                                             ;# a is now the most recently used
store::cachePut $CA [list c] $big                                        ;# evicts b, the least recently used
check lru_keeps_recent [list [llength [store::cacheGet $CA [list a]]] [llength [store::cacheGet $CA [list b]]] [llength [store::cacheGet $CA [list c]]]] {1 0 1}
check evictions_counted [dict get [store::cacheStats] evictions] 1
ok hits_and_misses [expr {[dict get [store::cacheStats] hits] >= 3 && [dict get [store::cacheStats] misses] >= 1}]
ok bytes_within_budget [expr {[dict get [store::cacheStats] bytes] <= [dict get [store::cacheStats] budget]}]
# entries of two databases share the budget; closing one drops only its entries
store::cachePut $CB [list x] $big
check shared_budget [dict get [store::cacheStats] entries] 2
store::closeFile $CB
check close_drops_only_that_db [llength [store::cacheGet $CA [list c]]] 1
check close_dropped_entries [dict get [store::cacheStats] entries] 1
# an entry bigger than the whole budget is not kept
store::cacheClear
store::cacheConfigure -budget 0.001
store::cachePut $CA [list huge] $big
check oversize_not_kept [dict get [store::cacheStats] entries] 0
# shrinking the budget evicts immediately
store::cacheConfigure -budget 10
store::cachePut $CA [list p] $big ; store::cachePut $CA [list q] $big
store::cacheConfigure -budget [expr {$cost * 1.2 / 1048576.0}]
check shrink_evicts [dict get [store::cacheStats] entries] 1
# a change invalidates: the cached value is not served for the new generation
store::cacheConfigure -budget 64
store::cacheClear
set col1 [store::column $CA.t score]
check column_cached [llength [store::cacheGet $CA [list col $CA.t score]]] 1
store::setCell $CA.t 0 score 999.5
check column_not_stale_after_edit [lindex [store::column $CA.t score] 0] 999.5
# cache off
store::cacheConfigure -budget 0
store::cacheClear
store::column $CA.t score
check cache_off_keeps_nothing [dict get [store::cacheStats] entries] 0
check cache_off_still_correct [lindex [store::column $CA.t score] 0] 999.5
store::cacheConfigure -budget 256
store::closeFile $CA
ok bad_option_rejected [catch {store::cacheConfigure -frobnicate 1}]

puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
