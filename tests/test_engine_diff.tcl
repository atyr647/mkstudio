# Differential test of the optimised executor:   tclkit tests/test_engine_diff.tcl
#
# Thousands of random queries (random predicates, expressions, aggregates, grouping, ordering,
# limits) run through the optimised executor (pushdown, compiled expressions, streaming
# aggregates, top-k) and through the ORIGINAL row-at-a-time executor kept in
# tests/mkql_reference.tcl.  Results must be identical: columns, types, rows, row ids, flags -
# or both must raise an error (strict equivalence: a fast path is only used when it can be proved
# not to hide an error; which offending row is reported may differ).  UPDATE and DELETE are checked against the reference too.
#
#   MKS_FUZZ   number of random queries per data set (default 1500)
#   MKS_SEED   random seed (default 1)
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
source $here/mkql_reference.tcl

set N [expr {[info exists ::env(MKS_FUZZ)] ? $::env(MKS_FUZZ) : 1500}]
set seed [expr {[info exists ::env(MKS_SEED)] ? $::env(MKS_SEED) : 1}]
expr {srand($seed)}
set lazyUsed 0 ; set suppressed 0 ; set pass 0 ; set fail 0 ; set errBoth 0 ; set shown 0 ; set pushed 0
proc check {name ok {detail ""}} {
    global pass fail shown
    if {$ok} { incr pass } else { incr fail ; if {[incr shown] <= 8} { puts "FAIL $name\n$detail" } }
}
proc pick {l} { lindex $l [expr {int(rand() * [llength $l])}] }
proc chance {p} { expr {rand() < $p} }

proc firstDiff {got want} {
    set n [expr {max([llength $got], [llength $want])}]
    for {set i 0} {$i < $n} {incr i} {
        if {[lindex $got $i] ne [lindex $want $i]} { return "  first difference at row $i:\n    got  [string range [lindex $got $i] 0 300]\n    want [string range [lindex $want $i] 0 300]" }
    }
    return ""
}
proc snapshot {tag size} {
    set out {}
    for {set k 0} {$k < [store::size $tag.t]} {incr k} { lappend out [store::captureRow $tag.t $k] }
    return $out
}
proc lmap_col {rows} { set o {} ; foreach r $rows { lappend o [lindex $r 0] } ; return $o }

# ---- data ---------------------------------------------------------------------------------------
set cvocab {{} x y X abc ABC 7 07 7.0 10 9 {b c} it's Zed zed}
set bvocab {0.5 1.5 2.0 2.5 -1 10 3.25 0 7}
set avocab {-3 0 1 2 2 3 5 7 7 7 9 12}
proc build {path n} {
    global cvocab bvocab avocab
    file delete $path
    set t [store::openFile $path -create]
    store::createView $t t {{id I {}} {a I {}} {b D {}} {c S {}} {l L {}} {e S {}} {f F {}} {bin B {}} {s V {{x S {}}}}}
    for {set i 0} {$i < $n} {incr i} {
        set r [store::appendRow $t.t {id a b c l e f bin} [list $i [pick $::avocab] [pick $::bvocab] [pick $::cvocab] \
            [pick {0 5000000000 -3 7 7 100}] [expr {[chance 0.7] ? "" : "e$i"}] [pick {0.5 1.25 -3.5 100}] [binary format c3 [list [expr {int(rand()*256)}] 0 [expr {int(rand()*256)}]]]]]
        for {set k 0} {$k < int(rand() * 4)} {incr k} { store::appendRow $t.t!$r.s {x} [list s$k] }
    }
    return $t
}

# ---- random queries -----------------------------------------------------------------------------
set numCols {id a b l}
proc lit {} {
    switch [expr {int(rand() * 9)}] {
        0 - 1 - 2 { return [pick {-3 0 1 2 3 5 7 9 12 100}] }
        3 { return [pick {0.5 2.5 7.0 3.25 -1.5 1e3}] }
        4 { return 5000000000 }
        5 { return '[pick {x X abc ABC 7 07 {} {it''s} {b c} Zed}]' }
        6 { return '[pick {7 7.0 10 9 abc x}]' }
        default { return [pick {1 2 4 6 8}] }
    }
}
proc col {} { return [pick {id a b c l e s a a c id}] }
proc ncol {} { return [pick {id a b l a id s}] }
proc cmpop {} { return [pick {= = <> < <= > >=}] }
proc expr1 {depth} {
    if {$depth <= 0 || [chance 0.35]} { return [expr {[chance 0.55] ? [col] : [lit]}] }
    switch [expr {int(rand() * 12)}] {
        0 - 1 { return "([expr1 [expr {$depth-1}]] [pick {+ - * / %}] [expr1 [expr {$depth-1}]])" }
        2 { return "([expr1 [expr {$depth-1}]] || [expr1 [expr {$depth-1}]])" }
        3 { return "-[ncol]" }
        4 { return "UPPER([col])" }
        5 { return "LENGTH([col])" }
        6 { return "ABS([ncol] - [lit])" }
        7 { return "COALESCE([col], [lit])" }
        8 { return "SUBSTR([col], 2, 2)" }
        9 { return "ROUND([ncol] * 1.5)" }
        10 { return "CONCAT([col], '-', [col])" }
        default { return "REPLACE([col], 'b', 'Q')" }
    }
}
proc pred {depth} {
    if {$depth <= 0 || [chance 0.45]} {
        switch [expr {int(rand() * 12)}] {
            0 - 1 - 2 - 3 { return "[col] [cmpop] [lit]" }
            4 { return "[lit] [cmpop] [col]" }
            5 { return "[ncol] BETWEEN [lit] AND [lit]" }
            6 { return "[col] [pick {IN {NOT IN}}] ([lit], [lit], [lit])" }
            7 { return "[col] [pick {LIKE {NOT LIKE}}] [pick {'x%' '%b%' 'a_c' 'A%' '7%' '%'}]" }
            8 { return "[col] IS [pick {NULL {NOT NULL}}]" }
            9 { return "[expr1 2] [cmpop] [expr1 1]" }
            10 { return "[ncol] NOT BETWEEN [lit] AND [lit]" }
            default { return "[ncol] [cmpop] [lit]" }
        }
    }
    switch [expr {int(rand() * 4)}] {
        0 - 1 { return "([pred [expr {$depth-1}]] AND [pred [expr {$depth-1}]])" }
        2 { return "([pred [expr {$depth-1}]] OR [pred [expr {$depth-1}]])" }
        default { return "NOT ([pred [expr {$depth-1}]])" }
    }
}
proc whereClause {} {
    if {[chance 0.2]} { return "" }
    # mostly a conjunction, so pushdown is exercised
    set parts {}
    for {set i 0} {$i < 1 + int(rand() * 3)} {incr i} { lappend parts [pred [expr {[chance 0.3] ? 2 : 0}]] }
    return " WHERE [join $parts { AND }]"
}
proc orderClause {nsel names} {
    if {[chance 0.4]} { return "" }
    set keys {}
    for {set i 0} {$i < 1 + int(rand() * 2)} {incr i} {
        set k [pick [list [col] [ncol] [ncol] [pick $names] [expr {1 + int(rand() * $nsel)}] [expr1 1]]]
        lappend keys "$k [pick {ASC DESC {} DESC}]"
    }
    return " ORDER BY [join $keys {, }]"
}
proc limitClause {} {
    set r [expr {rand()}]
    if {$r < 0.45} { return "" }
    if {$r < 0.9} { return " LIMIT [pick {0 1 3 10 50 1000}][expr {[chance 0.3] ? " OFFSET [pick {0 1 5 40}]" : ""}]" }
    return ""
}
proc genSelect {} {
    set kind [expr {int(rand() * 10)}]
    set where [whereClause]
    if {$kind < 4} {
        # plain projection
        if {[chance 0.2]} { set items * ; set names {id a b c l e s} ; set nsel 7 } else {
            set items {} ; set names {} ; set nsel [expr {1 + int(rand() * 3)}]
            for {set i 0} {$i < $nsel} {incr i} {
                set e [expr {[chance 0.5] ? [col] : [expr1 2]}]
                lappend items "$e AS f$i" ; lappend names f$i
            }
            set items [join $items {, }]
        }
        set d [expr {[chance 0.12] ? "DISTINCT " : ""}]
        return "SELECT $d$items FROM t$where[orderClause $nsel $names][limitClause]"
    }
    if {$kind < 8} {
        # aggregates, maybe grouped
        set aggs {}
        for {set i 0} {$i < 1 + int(rand() * 3)} {incr i} {
            lappend aggs [pick [list COUNT(*) COUNT([col]) "COUNT(DISTINCT [col])" SUM([ncol]) AVG([ncol]) MIN([col]) MAX([col]) MAX([ncol]) "SUM([ncol]) / COUNT(*)" "SUM(DISTINCT [ncol])" "MIN([ncol]) + MAX([ncol])"]]
        }
        set grp [pick {{} {} a c {a, c} l e id}]
        set names {} ; set items {}
        set sel [expr {$grp ne "" ? "$grp, " : ""}]
        set k 0
        foreach a $aggs { append sel "$a AS g$k, " ; lappend names g$k ; incr k }
        set sel [string range $sel 0 end-2]
        set q "SELECT $sel FROM t$where"
        if {$grp ne ""} { append q " GROUP BY $grp" }
        if {[chance 0.25]} { append q " HAVING [pick [list {COUNT(*) > 1} {SUM(a) > 3} {MAX(b) >= 2} {COUNT(*) >= 0}]]" }
        if {[chance 0.5]} { append q " ORDER BY [pick [concat $names {1 2}]] [pick {ASC DESC {}}]" }
        return $q[limitClause]
    }
    # shortcut shapes
    return [pick [list \
        "SELECT COUNT(*) FROM t$where" \
        "SELECT COUNT(*), COUNT(*) FROM t$where" \
        "SELECT id, [ncol] FROM t$where ORDER BY [ncol] [pick {ASC DESC}] LIMIT [pick {1 3 10 25}]" \
        "SELECT * FROM t$where ORDER BY [ncol] [pick {ASC DESC}], id LIMIT [pick {1 5 20}] OFFSET [pick {0 2 7}]" \
        "SELECT id FROM t$where ORDER BY [pick {a b l}] [pick {ASC DESC}] LIMIT [pick {0 1 2 50}]"]]
}

# ---- comparison ---------------------------------------------------------------------------------
proc runBoth {sql db} {
    set stmt [lindex [mkql::parseScript $sql] 0 0]
    set a [catch {mkql::execStatement $stmt $db} ra]
    set b [catch {mkqlref::execSelect [lindex $stmt 1] $db} rb]
    return [list $a $ra $b $rb]
}
proc normalise {r} {
    # compare everything that the grid / callers see
    set out {}
    foreach k {cols types rows rowids source drill truncated editable} { lappend out $k [dict get $r $k] }
    return $out
}
proc compareQuery {sql db} {
    global errBoth suppressed lazyUsed
    lassign [runBoth $sql $db] a ra b rb
    # (which row raises first may differ once rows are skipped or fetched in another order, so only
    # "both fail" is required, not the same message)
    if {$a && $b} { incr errBoth ; incr ::pass ; return }
    if {$a != $b} { check "error-mismatch: $sql" 0 "  fast ([expr {$a ? {error} : {ok}}]): [string range $ra 0 200]\n   ref ([expr {$b ? {error} : {ok}}]): [string range $rb 0 200]" ; return }
    set x [normalise $ra] ; set y [normalise $rb]
    check "result: $sql" [expr {$x eq $y}] "  fast: [string range $x 0 300]\n   ref: [string range $y 0 300]"
    if {$x ne $y} return
    # the same query as a lazy (streaming) result must also be identical, rows and row ids included
    set ::mkql::lazyMin 1 ; set save $::engine::maxRows ; set ::engine::maxRows 1000000000
    set stmt [lindex [mkql::parseScript $sql] 0 0]
    set a2 [catch {mkql::execStatement $stmt $db} rl]
    set b2 [catch {mkqlref::execSelect [lindex $stmt 1] $db} rr]
    set ::mkql::lazyMin 20000 ; set ::engine::maxRows $save
    if {$a2 != $b2} { check "lazy error mismatch: $sql" 0 "  lazy: [string range $rl 0 200]\n   ref: [string range $rr 0 200]" ; return }
    if {$a2} return
    if {[dict exists $rl provider]} {
        incr ::lazyUsed
        set p [dict get $rl provider]
        set n [{*}$p count]
        set rows [{*}$p rows 0 $n]
        set ids {} ; for {set k 0} {$k < $n} {incr k} { lappend ids [{*}$p rowid $k] }
        dict set rl rows $rows ; dict set rl rowids $ids
        {*}$p destroy
    }
    set x [normalise $rl] ; set y [normalise $rr]
    check "lazy result: $sql" [expr {$x eq $y}] "  lazy: [string range $x 0 300]\n   ref: [string range $y 0 300]"
}

foreach {size} {0 1 40 300 1200} {
    set f [tmp diff_$size.mk]
    set tag [build $f $size]
    store::commit $tag
    set before $pass
    set count [expr {$size > 300 ? $N / 3 : $N}]
    for {set i 0} {$i < $count} {incr i} {
        set sql [genSelect]
        # reference must not see a cancel flag left over by the previous query
        compareQuery $sql $tag
    }
    puts "  size $size: [expr {$pass - $before}] queries identical"

    # --- DELETE / UPDATE: the table afterwards must equal an independent model, byte for byte ---
    # (every column type incl. bytes, floats and subview rows), through the in-place path AND through the
    # rebuild path that store.tcl uses for bulk changes (forced here by lowering its threshold).
    set rows0 {} ; for {set k 0} {$k < [store::size $tag.t]} {incr k} { lappend rows0 [store::captureRow $tag.t $k] }
    foreach floor {1000 1} {
        set ::store::rebuildFloor $floor
        for {set i 0} {$i < 20 && $size > 0} {incr i} {
            set w [pred [expr {[chance 0.3] ? 2 : 0}]]
            if {[chance 0.5]} { set w "[pred 0] AND [pred 0]" }
            lassign [runBoth "SELECT _rowid FROM t WHERE $w" $tag] a ra b rb
            if {$a || $b} { continue }
            set idset [dict create] ; foreach k [lmap_col [dict get $rb rows]] { dict set idset $k 1 }
            # DELETE
            set want {} ; set k 0
            foreach r $rows0 { if {![dict exists $idset $k]} { lappend want $r } ; incr k }
            if {[catch {mkql::run "DELETE FROM t WHERE $w" $tag} err]} { check "delete ran: $w" 0 $err ; store::rollback $tag ; continue }
            set snap [snapshot $tag $size]
            check "delete (floor $floor): $w" [expr {$snap eq $want}] "  [llength $snap] rows, want [llength $want]\n[firstDiff $snap $want]"
            store::rollback $tag
            # UPDATE of a number, a string and a float column
            set want {} ; set k 0
            foreach r $rows0 {
                if {[dict exists $idset $k]} {
                    set v [dict get $r vals]
                    dict set v a [expr {[dict get $v a] + 100}]
                    dict set v e "[dict get $v c]!"
                    dict set r vals $v
                }
                lappend want $r ; incr k
            }
            if {[catch {mkql::run "UPDATE t SET a = a + 100, e = c || '!' WHERE $w" $tag} err]} { check "update ran: $w" 0 $err ; store::rollback $tag ; continue }
            set snap [snapshot $tag $size]
            check "update (floor $floor): $w" [expr {$snap eq $want}] [firstDiff $snap $want]
            store::rollback $tag
        }
    }
    set ::store::rebuildFloor 1000
    # several bulk changes in ONE transaction: in place vs rebuilt must end in the same table
    for {set i 0} {$i < 15 && $size > 0} {incr i} {
        set stmts [list "DELETE FROM t WHERE [pred 0]" "UPDATE t SET e = c || '#', a = a * 2 WHERE [pred 0]" \
            "DELETE FROM t WHERE [pred 0] AND [pred 0]" "UPDATE t SET e = 'zz' WHERE [pred 0]"]
        set res {}
        foreach floor {1000 1} {
            set ::store::rebuildFloor $floor
            set failed 0
            foreach st $stmts { if {[catch {mkql::run $st $tag}]} { set failed 1 ; break } }
            lappend res [expr {$failed ? "error" : [snapshot $tag $size]}]
            store::rollback $tag
        }
        set ::store::rebuildFloor 1000
        check "chain of bulk changes: [join $stmts {; }]" [expr {[lindex $res 0] eq [lindex $res 1]}] "  in-place and rebuilt tables differ"
    }
    store::closeFile $tag
}

puts "  $lazyUsed of the queries also ran as lazy streaming results, identical"
puts "  $errBoth of the queries raised an error in both executors"
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
