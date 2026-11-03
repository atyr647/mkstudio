# Execution behaviour of the optimised executor vs the original simple one - beyond "same rows":
#   tclkit tests/test_engine_semantics.tcl
#   * error ORDER: a query with one failing row fails with the SAME message, or succeeds, in both
#   * row ORDER: unsorted results come out in row order, ties keep row order (also when streamed)
#   * side effects: a failing or cancelled UPDATE / DELETE / INSERT changes NOTHING (all or nothing)
#   * cancellation: a scan stops at the next chunk with the same message
#   * the executors agree on what a statement changed (counts)
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
source $here/mkql_reference.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 200]> want <[string range $want 0 200]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }

set N 3000
set f [tmp semantics.mk] ; foreach x [glob -nocomplain $f*] { file delete $x }
set tag [store::openFile $f -create]
store::createView $tag t {{id I {}} {g I {}} {name S {}} {score D {}} {s V {{x S {}}}}}
for {set i 0} {$i < $N} {incr i} {
    set r [store::appendRow $tag.t {id g name score} [list $i [expr {$i % 5}] "n[expr {$i % 17}]" [expr {($i * 7) % 11}]]]
    if {$i % 9 == 0} { store::appendRow $tag.t!$r.s {x} [list s$i] }
}
store::commit $tag
proc snapshot {} { global tag ; set o {} ; for {set k 0} {$k < [store::size $tag.t]} {incr k} { lappend o [store::captureRow $tag.t $k] } ; return $o }
proc both {sql} {
    global tag
    set stmt [lindex [mkql::parseScript $sql] 0 0]
    set a [catch {mkql::execStatement $stmt $tag} ra]
    set b [catch {mkqlref::execSelect [lindex $stmt 1] $tag} rb]
    return [list $a $ra $b $rb]
}
proc rowsOf {r} { if {[dict exists $r provider]} { set p [dict get $r provider] ; return [{*}$p rows 0 [{*}$p count]] } ; return [dict get $r rows] }

# ---- 1. error order: row 700 is the only row that fails ------------------------------------------------------
# 100 / (id - 700) divides by zero on exactly one row.  Whether the executors reach that row depends on
# the WHERE, LIMIT and ORDER BY - they must agree on every variant, and when both fail, on the message.
set bad "100 / (id - 700)"
set matrix [list \
    "SELECT $bad FROM t" \
    "SELECT $bad FROM t WHERE id < 700" \
    "SELECT $bad FROM t WHERE id <= 700" \
    "SELECT $bad FROM t WHERE id <> 700" \
    "SELECT id FROM t WHERE $bad > 0" \
    "SELECT id FROM t WHERE id < 100 AND $bad > 0" \
    "SELECT id FROM t WHERE $bad > 0 AND id < 100" \
    "SELECT id FROM t WHERE g = 2 AND $bad > 0" \
    "SELECT id FROM t WHERE g = 3 AND $bad > 0" \
    "SELECT id FROM t WHERE g = 0 AND $bad > 0" \
    "SELECT $bad FROM t LIMIT 100" \
    "SELECT $bad FROM t LIMIT 800" \
    "SELECT $bad FROM t ORDER BY id LIMIT 5" \
    "SELECT $bad FROM t ORDER BY id DESC LIMIT 5" \
    "SELECT $bad FROM t ORDER BY score LIMIT 5" \
    "SELECT id FROM t ORDER BY $bad LIMIT 5" \
    "SELECT id FROM t ORDER BY id LIMIT 5" \
    "SELECT SUM($bad) FROM t" \
    "SELECT SUM($bad) FROM t WHERE id < 700" \
    "SELECT g, COUNT(*) FROM t GROUP BY g HAVING SUM($bad) > 0" \
    "SELECT id, $bad AS v FROM t WHERE g = 1 ORDER BY id" \
    "SELECT COUNT(*) FROM t WHERE $bad > 0" \
    "SELECT COUNT(*) FROM t WHERE id < 700" \
    "SELECT id FROM t WHERE id BETWEEN 600 AND 800 AND $bad > 0" \
    "SELECT id FROM t WHERE id BETWEEN 600 AND 699 AND $bad > 0" \
    "SELECT id FROM t WHERE name = 'n3' AND $bad > 0" \
    "SELECT id FROM t WHERE score >= 20 AND $bad > 0" \
    "SELECT id FROM t WHERE id IN (1, 2, 700) AND $bad > 0" \
    "SELECT id FROM t WHERE id IN (1, 2, 3) AND $bad > 0" \
]
foreach sql $matrix {
    lassign [both $sql] a ra b rb
    if {$a != $b} { check "error-order: $sql" [expr {$a ? "fails: $ra" : "succeeds"}] [expr {$b ? "fails: $rb" : "succeeds"}] ; continue }
    if {$a} { check "error-order message: $sql" $ra $rb } else {
        check "error-order result: $sql" [rowsOf $ra] [dict get $rb rows]
    }
}
# the same, with streaming forced on
set ::mkql::lazyMin 1
foreach sql $matrix {
    lassign [both $sql] a ra b rb
    if {$a != $b} { check "lazy error-order: $sql" [expr {$a ? "fails: $ra" : "succeeds"}] [expr {$b ? "fails: $rb" : "succeeds"}] ; continue }
    if {$a} { check "lazy error-order message: $sql" $ra $rb } else { check "lazy error-order result: $sql" [rowsOf $ra] [dict get $rb rows] }
}
set ::mkql::lazyMin 20000

# ---- 2. row order ---------------------------------------------------------------------------------------------------
foreach sql {
    "SELECT id FROM t WHERE g = 2"
    "SELECT id, name FROM t WHERE score > 4 AND g < 3"
    "SELECT id, g FROM t ORDER BY g"
    "SELECT id, g FROM t ORDER BY g DESC"
    "SELECT id, name FROM t ORDER BY name, g DESC"
    "SELECT id, score FROM t WHERE g IN (1, 3) ORDER BY score DESC LIMIT 40 OFFSET 7"
    "SELECT id FROM t ORDER BY score LIMIT 25"
} {
    foreach lm {20000 1} {
        set ::mkql::lazyMin $lm
        lassign [both $sql] a ra b rb
        check "row order (lazyMin $lm): $sql" [expr {$a || $b ? "error" : [rowsOf $ra]}] [expr {$a || $b ? "error" : [dict get $rb rows]}]
    }
}
set ::mkql::lazyMin 20000

# ---- 3. all or nothing -----------------------------------------------------------------------------------------------------
set before [snapshot]
foreach {name sql} {
    update_fails_midway        "UPDATE t SET name = 'x', score = 100 / (id - 2000)"
    update_fails_on_last_row   "UPDATE t SET name = 'y', score = 100 / (id - 2999)"
    update_type_error          "UPDATE t SET id = 'not a number' WHERE g = 1"
    delete_fails_midway        "DELETE FROM t WHERE 100 / (id - 1500) > 0"
    insert_bad_second_row      "INSERT INTO t (id, g, name, score) VALUES (9001, 1, 'ok', 1), (9002, 1, 'bad', 'oops')"
} {
    set rc [catch {mkql::run $sql $tag} msg]
    check "$name: fails" $rc 1
    check "$name: changed nothing" [snapshot] $before
}
# the same through the bulk rebuild path
set ::store::rebuildFloor 1
foreach {name sql} {
    rebuild_update_fails   "UPDATE t SET name = 'x', score = 100 / (id - 2500)"
    rebuild_delete_fails   "DELETE FROM t WHERE g = 0 AND 100 / (id - 2900) > 0"
} {
    check "$name: fails" [catch {mkql::run $sql $tag}] 1
    check "$name: changed nothing" [snapshot] $before
}
set ::store::rebuildFloor 1000
# cancelled during evaluation: nothing changed, same message as a cancelled SELECT
set ::mkql::progressHook {set ::engine::cancel 1}
set rc [catch {mkql::run "UPDATE t SET name = 'cancelled' WHERE name <> 'zz'" $tag} msg]
set ::mkql::progressHook {}
check cancelled_update_fails $rc 1
ok cancelled_update_message [string match "*cancel*" [string tolower $msg]] $msg
check cancelled_update_changed_nothing [snapshot] $before
# ... and a statement that is NOT cancelled changes everything it should
check update_counts [dict get [mkql::run "UPDATE t SET score = score + 1 WHERE g = 4" $tag] affected] [expr {$N / 5}]
store::rollback $tag

# ---- 4. cancellation of reads ------------------------------------------------------------------------------------------------
foreach sql {
    "SELECT id FROM t WHERE name <> 'n1'"
    "SELECT id, name FROM t WHERE UPPER(name) = 'N5'"
    "SELECT g, COUNT(*) FROM t WHERE name <> 'zz' GROUP BY g"
} {
    set ::mkql::progressHook {set ::engine::cancel 1}
    set a [catch {mkql::run $sql $tag} ma]
    set b [catch {mkqlref::execSelect [lindex [lindex [mkql::parseScript $sql] 0 0] 1] $tag} mb]
    set ::mkql::progressHook {}
    check "cancel: $sql" [list $a $ma] [list $b $mb]
}
# a Cancel left over from the last statement does not poison the next one
set ::engine::cancel 1
check stale_cancel_ignored [catch {mkql::run "SELECT id FROM t WHERE g = 1" $tag}] 0
# ... including column reads outside a query (the grid's sort)
set ::engine::cancel 1
check stale_cancel_ignored_by_column_reads [llength [store::column $tag.t score]] $N
set ::engine::cancel 0
# a cancel DURING a long column read (top-k, streaming ORDER BY) is honoured
set big [tmp semantics_big.mk] ; foreach x [glob -nocomplain $big*] { file delete $x }
set tb [store::openFile $big -create]
store::createView $tb v {{id I {}} {score D {}}}
for {set i 0} {$i < 120000} {incr i} { store::appendRow $tb.v {id score} [list $i [expr {($i * 37) % 1009}]] }
set ::mkql::progressHook {set ::engine::cancel 1}
set rc [catch {mkql::run "SELECT id FROM v ORDER BY score DESC LIMIT 5" $tb} msg]
set ::mkql::progressHook {}
check cancelled_column_read $rc 1
ok cancelled_column_read_message [string match "*cancel*" [string tolower $msg]] $msg
check cancelled_read_left_no_half_cache [llength [store::cacheGet $tb [list col $tb.v score]]] 0
check cache_still_works_afterwards [dict get [mkql::run "SELECT id FROM v ORDER BY score DESC LIMIT 2" $tb] kind] rowset
store::closeFile $tb

puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
