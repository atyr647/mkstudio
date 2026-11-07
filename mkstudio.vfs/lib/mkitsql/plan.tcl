# plan.tcl -- query planner and executor for mkit-sql.
#
# compileQuery bq outerMaps  ->  plan id        (bound query -> executable plan)
# runPlan id outer           ->  list of tuples (NULL is the ::mkitsql::N sentinel)
#
# A tuple is a plain Tcl list.  Table scans produce  [loaded columns..., %cur]
# where %cur is the row's Metakit cursor path ("demo.people!3"); joins simply
# concatenate tuples.  WHERE conjuncts are pushed down to the scans they belong
# to, and equality conditions between the two sides of a join become hash joins.

namespace eval ::mkitsql {
    variable planSeq 0
    variable plans
    variable subCache
    variable memo ; variable memoCount 0 ; variable maxMemo 200000 ; variable memoUsed 0 ; variable memoBytes 16777216   ;# remembered answers of correlated subqueries (see rt::memoPut)
    variable ticks 0
    variable maxSetRows 5000000
    variable lookupSeq 0
    variable scanSeq 0
    variable scanCache
    variable scanRuns
    array set scanCache {}
    array set scanRuns {}
    variable lookupIdx
    array set lookupIdx {}
    variable wtable
    array set wtable {}
    variable maxRecursion 100000
    variable maxWorkRows 5000000
    variable chunk 2000
    variable capRows 0          ;# >0: stop scanning after this many rows (plain queries only)
    variable pushdown 1         ;# 1 = let Metakit narrow scans with mk::select (see pushSpec)
    variable pushMin 500        ;# ... on tables of at least this many rows
    variable pushScans 0        ;# how many scans Metakit narrowed (for tests and EXPLAIN)
    array set plans {}
    array set subCache {}
}

# ============================================================================
#  Helpers
# ============================================================================
proc ::mkitsql::splitAnd {e} {
    if {$e eq ""} { return {} }
    if {[lindex $e 0] eq "bin" && [lindex $e 1] eq "and"} {
        return [concat [splitAnd [lindex $e 2]] [splitAnd [lindex $e 3]]]
    }
    return [list $e]
}
proc ::mkitsql::joinAnd {exprs} {
    set r ""
    foreach e $exprs { if {$r eq ""} { set r $e } else { set r [list bin and $r $e] } }
    return $r
}
proc ::mkitsql::subset {a b} {
    foreach x $a { if {[lsearch -exact $b $x] < 0} { return 0 } }
    return 1
}

# Compile a list of bound conjuncts into one filter proc ("" if none).
proc ::mkitsql::compileFilter {exprs map outerMaps} {
    if {![llength $exprs]} { return "" }
    set ctx [dict create maps [concat [list $map] $outerMaps]]
    lassign [compileCond [joinAnd $exprs] $ctx] p t
    return $p
}

# Remove and return pool conjuncts whose local sources are a non-empty subset of `ids`.
proc ::mkitsql::takePool {stVar ids} {
    upvar 1 $stVar st
    set keep {} ; set take {}
    foreach c [dict get $st pool] {
        lassign $c e srcs
        if {[llength $srcs] && [subset $srcs $ids]} { lappend take $e } else { lappend keep $c }
    }
    dict set st pool $keep
    return $take
}

# ============================================================================
#  Compiling queries
# ============================================================================
proc ::mkitsql::compileQuery {bq outerMaps} {
    variable planSeq ; variable plans
    set id [incr planSeq]
    switch -- [dict get $bq kind] {
        select { set p [compileSelect $bq $outerMaps] }
        values {
            # a list of plain literals (INSERT ... VALUES (1, 'a'), ...) needs no code at all: compiling one proc per row
            # made a 10,000-row INSERT take 2.4 s; the rows are used as they are
            variable N
            set allLit 1 ; set lits {}
            foreach row [dict get $bq rows] {
                set tuple {}
                foreach e $row {
                    if {[lindex $e 0] ne "lit"} { set allLit 0 ; break }
                    # (never route data through an expr ternary: it would turn the text '007' into 7)
                    if {[lindex $e 1] eq "null"} { lappend tuple $N } else { lappend tuple [lindex $e 2] }
                }
                if {!$allLit} break
                lappend lits $tuple
            }
            if {$allLit} {
                set p [dict create kind values lits $lits]
            } else {
                set procs {}
                foreach row [dict get $bq rows] {
                    lassign [compileList $row [dict create maps [concat [list {}] $outerMaps]]] pr ts
                    lappend procs $pr
                }
                set p [dict create kind values procs $procs]
            }
        }
        setop {
            set p [dict create kind setop op [dict get $bq op] all [dict get $bq all] \
                left [compileQuery [dict get $bq left] $outerMaps] \
                right [compileQuery [dict get $bq right] $outerMaps]]
        }
        recursive {
            set p [dict create kind recursive all [dict get $bq all] tid [dict get $bq tid] \
                anchor [compileQuery [dict get $bq anchor] $outerMaps] \
                step [compileQuery [dict get $bq step] $outerMaps]]
        }
        query {
            set order {}
            foreach o [dict get $bq order] {
                lassign $o e dir nulls
                set idx [lindex $e 1]
                lappend order [list $idx $dir $nulls [lindex [dict get $bq outTypes] $idx]]
            }
            set p [dict create kind query body [compileQuery [dict get $bq body] $outerMaps] \
                order $order limit [dict get $bq limit] offset [dict get $bq offset]]
        }
        default { error "compileQuery: [dict get $bq kind]" }
    }
    dict set p names [dict get $bq outNames]
    dict set p types [dict get $bq outTypes]
    dict set p letters [dict get $bq outLetters]
    dict set p drill [dict get $bq outDrill]
    set plans($id) $p
    return $id
}

# ---- tuple layout of the sources -------------------------------------------
proc ::mkitsql::sourceLayout {s} {
    variable needed ; variable curCol
    set id [dict get $s id]
    set names {} ; set props {} ; set subs {} ; set dcols {} ; set bcols {}
    switch -- [dict get $s kind] {
        table - lateral {
            set pseudo {}
            foreach k [array names needed $id,*] { if {[string first "\uFDD4" $k] > 0} { lappend pseudo [string range $k [string length $id,] end] } }
            foreach c [dict get $s cols] {
                lassign $c n t l isSub
                if {$l eq "B"} {
                    # parts of a blob read without the blob (see blobPart in bind.tcl): b<U+FDD4>size, b<U+FDD4>range<U+FDD4>..; and
                    # b<U+FDD4>ref<U+FDD4>limit (lazyBlobItems), read like a blob after the filter, for the rows that pass (late reads)
                    set ln [string tolower $n]
                    foreach p [lsort $pseudo] {
                        if {![string equal -length [expr {[string length $ln] + 1}] $p "$ln\uFDD4"]} continue
                        if {[string equal -length [expr {[string length $ln] + 5}] $p "$ln\uFDD4ref\uFDD4"]} { lappend bcols [llength $props] }
                        lappend props $n[string range $p [string length $ln] end]
                    }
                }
                if {![info exists needed($id,[string tolower $n])]} continue
                if {$isSub} { lappend subs $n } else {
                    if {$l in {F D}} { lappend dcols [llength $props] }     ;# floating-point columns: -0.0 is read as 0.0
                    if {$l eq "B"} { lappend bcols [llength $props] }       ;# blobs: may be read after the filter (late reads, scanPlain)
                    lappend props $n
                }
            }
            foreach n $props { lappend names [string tolower $n] }
            foreach n $subs { lappend names [string tolower $n] }
            lappend names [string tolower $curCol]
        }
        default {
            foreach c [dict get $s cols] { lappend names [string tolower [lindex $c 0]] }
        }
    }
    return [dict create names $names props $props subs $subs dcols $dcols bcols $bcols]
}

# ---- SELECT ----------------------------------------------------------------
proc ::mkitsql::compileSelect {bs outerMaps} {
    variable curCol
    set srcs [dict get $bs srcs]
    set lay [dict create]
    foreach s $srcs { dict set lay [dict get $s id] [sourceLayout $s] }

    # WHERE conjuncts and the sources each one touches
    set pool {}
    foreach e [splitAnd [dict get $bs where]] { lappend pool [list $e [localSrcs $e]] }
    set st [dict create lay $lay outer $outerMaps pool $pool]

    set from [dict get $bs from]
    if {$from eq ""} {
        set root [dict create plan {kind one} srcs {} width 0 map {}]
    } else {
        set root [cfNode $from 1 st]
    }
    set rootMap [dict get $root map]
    set rest {}
    foreach c [dict get $st pool] { lappend rest [lindex $c 0] }
    set whereProc [compileFilter $rest $rootMap $outerMaps]

    set p [dict create kind select src [dict get $root plan] where $whereProc \
        distinct [dict get $bs distinct]]

    # ---- aggregation
    set preCtx [dict create maps [concat [list $rootMap] $outerMaps]]
    set items [dict get $bs items]
    set having [dict get $bs having]
    set order [dict get $bs order]
    if {[dict get $bs isAgg]} {
        variable rwG ; variable rwAggs
        set rwG [dict get $bs group] ; set rwAggs {}
        set ng [llength $rwG]
        set items2 {}
        foreach e $items { lappend items2 [rwAgg $e] }
        set having2 [expr {$having eq "" ? "" : [rwAgg $having]}]
        set order2 {}
        foreach o $order {
            lassign $o e dir nulls
            lappend order2 [list [expr {[lindex $e 0] eq "outcol" ? $e : [rwAgg $e]}] $dir $nulls]
        }
        set aggNodes $rwAggs
        # compile group keys and aggregate arguments against the pre-aggregation tuple
        set gkey ""
        if {$ng} { lassign [compileList $rwG $preCtx] gkey _ }
        set argNodes {} ; set specs {}
        foreach a $aggNodes {
            lassign $a _ name distinct args
            set ai [llength $argNodes]
            if {[lindex $args 0 0] eq "star"} {
                lappend argNodes {lit int 1}
                set kind cstar
            } else {
                set a0 [lindex $args 0]
                set t0 [dryType $a0]
                if {$name in {SUM AVG} && $t0 eq "text"} { set a0 [list cast $a0 double] ; set t0 real }
                lappend argNodes $a0
                set kind [string tolower $name]
                if {$name eq "GROUP_CONCAT"} { set kind string_agg }
            }
            set sepIdx -1
            if {$name in {STRING_AGG GROUP_CONCAT} && [llength $args] > 1} {
                set sepIdx [llength $argNodes]
                lappend argNodes [lindex $args 1]
            }
            set sortKind [expr {[isNumType [expr {$kind in {min max} ? [dryType [lindex $args 0]] : "int"}]] ? "n" : "s"}]
            if {$kind in {sum avg min max} && [dryType [lindex $args 0]] eq "interval"} { set sortKind i }
            lappend specs [list $kind $distinct $ai $sepIdx $sortKind]
        }
        lassign [compileList $argNodes $preCtx] aargs _
        dict set p agg [dict create gkey $gkey ng $ng aargs $aargs specs $specs]
        set gmap {}
        set gj 0
        foreach g $rwG {
            if {[lindex $g 0] eq "ref" && [lindex $g 1] == 0} { dict set gmap [lindex $g 2],[string tolower [lindex $g 3]] $gj }
            incr gj
        }
        set ctx [dict create maps [concat [list $gmap] $outerMaps]]
        set items $items2 ; set having $having2 ; set order $order2
        set baseWidth [expr {$ng + [llength $aggNodes]}]
    } else {
        set ctx $preCtx
        set baseWidth [dict get $root width]
    }

    # ---- window functions: each call becomes a slot appended to the tuple
    set winSpecs {}
    set anyWin 0
    foreach e $items { if {[hasWin $e]} { set anyWin 1 } }
    foreach o $order { if {[lindex $o 0 0] ne "outcol" && [hasWin [lindex $o 0]]} { set anyWin 1 } }
    if {$anyWin} {
        variable rwWins ; variable rwBase
        set rwWins {} ; set rwBase $baseWidth
        set items2 {}
        foreach e $items { lappend items2 [rwWin $e] }
        set order2 {}
        foreach o $order {
            lassign $o e dir nulls
            lappend order2 [list [expr {[lindex $e 0] eq "outcol" ? $e : [rwWin $e]}] $dir $nulls]
        }
        set items $items2 ; set order $order2
        foreach w $rwWins { lappend winSpecs [compileWindow $w $ctx] }
        dict set p windows $winSpecs
    }
    if {$having ne ""} {
        lassign [compileCond $having $ctx] hp _
        dict set p having $hp
    }
    lassign [compileList $items $ctx] itemsProc itemTypes
    dict set p items $itemsProc
    dict set p itemTypes $itemTypes

    # ---- ORDER BY
    set ospec {} ; set ekeyNodes {}
    foreach o $order {
        lassign $o e dir nulls
        if {[lindex $e 0] eq "outcol"} {
            lappend ospec [list out [lindex $e 1] $dir $nulls [lindex [dict get $bs outTypes] [lindex $e 1]]]
        } else {
            lappend ospec [list key [llength $ekeyNodes] $dir $nulls [dryType $e]]
            lappend ekeyNodes $e
        }
    }
    if {[llength $ekeyNodes]} {
        lassign [compileList $ekeyNodes $ctx] okeys _
        dict set p okeys $okeys
    }
    dict set p order $ospec
    dict set p limit [dict get $bs limit]
    dict set p offset [dict get $bs offset]

    # ---- row ids for editable (plain, single-table) results
    set plain 0 ; set curPos -1 ; set source ""
    if {![dict get $bs isAgg] && ![dict get $bs distinct] && [llength $srcs] == 1 && !$anyWin} {
        set s [lindex $srcs 0]
        if {[dict exists $s path]} {
            set plain 1
            set curPos [dict get $rootMap [dict get $s id],[string tolower $curCol]]
            set source [dict get $s path]
        }
    }
    dict set p curPos $curPos
    dict set p plain $plain
    dict set p source $source
    # may the scan stop early once enough rows were produced?
    dict set p stoppable [expr {![dict get $bs isAgg] && ![dict get $bs distinct] && ![llength $ospec] && [llength $srcs] <= 1 && $whereProc eq "" && !$anyWin}]
    return $p
}

# ---- aggregate rewriting ---------------------------------------------------
proc ::mkitsql::rwAgg {node} {
    variable rwG ; variable rwAggs ; variable aggs
    set j [lsearch -exact $rwG $node]
    if {$j >= 0} { return [list slot $j [dryType $node]] }
    switch -- [lindex $node 0] {
        func {
            if {[lsearch -exact $aggs [lindex $node 1]] >= 0} {
                foreach a [lindex $node 3] {
                    if {[lindex $a 0] ne "star" && [hasAgg $a]} {
                        fail "Aggregate function calls cannot be nested"
                    }
                }
                set k [lsearch -exact $rwAggs $node]
                if {$k < 0} { set k [llength $rwAggs] ; lappend rwAggs $node }
                return [list slot [expr {[llength $rwG] + $k}] [aggType $node]]
            }
        }
        ref {
            if {[lindex $node 1] == 0} {
                fail "Column '[lindex $node 3]' must appear in the GROUP BY clause or be used in an aggregate function"
            }
            return $node
        }
        sub - exists {
            checkGroupedRefs [lindex $node 2]
            return $node
        }
        insub {
            checkGroupedRefs [lindex $node 4]
            return [lreplace $node 1 1 [rwAgg [lindex $node 1]]]
        }
        quant {
            checkGroupedRefs [lindex $node 5]
            return [lreplace $node 3 3 [rwAgg [lindex $node 3]]]
        }
        lit - slot { return $node }
    }
    return [mapChildren $node ::mkitsql::rwAgg]
}

# Can `a = b` be evaluated as a hash lookup?  Returns {a' b'} (numeric keys of
# different kinds are both converted to double) or "" when the types do not allow it.
proc ::mkitsql::keyPair {a b} {
    set ta [dryType $a] ; set tb [dryType $b]
    set na [isNumType $ta] ; set nb [isNumType $tb]
    if {$na && $nb} {
        if {$ta ne $tb && !($ta in {int bool} && $tb in {int bool})} {
            return [list [list cast $a double] [list cast $b double]]
        }
        return [list $a $b]
    }
    if {!$na && !$nb && $ta ne "null" && $tb ne "null"} { return [list $a $b] }
    return ""
}

# Does the expression refer to an enclosing query (level >= 1)?
proc ::mkitsql::hasOuterRef {node} {
    switch -- [lindex $node 0] {
        ref { return [expr {[lindex $node 1] >= 1}] }
        lit - slot { return 0 }
        sub - exists - insub { return 1 }
    }
    foreach c [exprChildren $node] { if {[hasOuterRef $c]} { return 1 } }
    return 0
}

# A subquery inside a grouped query may refer to the enclosing query's GROUP BY columns
# (they are read from the aggregated tuple), but not to ungrouped ones.
proc ::mkitsql::checkGroupedRefs {refs} {
    variable rwG
    foreach r $refs {
        lassign $r lvl sid name
        if {$lvl != 1} continue
        set ok 0
        foreach g $rwG {
            if {[lindex $g 0] eq "ref" && [lindex $g 1] == 0 && [lindex $g 2] == $sid && [string tolower [lindex $g 3]] eq $name} { set ok 1 }
        }
        if {!$ok} {
            fail "Column '$name' must appear in the GROUP BY clause or be used in an aggregate function (it is used inside a subquery)"
        }
    }
}

# ---- window rewriting ------------------------------------------------------
proc ::mkitsql::rwWin {node} {
    variable rwWins ; variable rwBase
    switch -- [lindex $node 0] {
        win {
            set k [lsearch -exact $rwWins $node]
            if {$k < 0} { set k [llength $rwWins] ; lappend rwWins $node }
            return [list slot [expr {$rwBase + $k}] [winType $node]]
        }
        lit - slot - ref - sub - exists { return $node }
    }
    return [mapChildren $node ::mkitsql::rwWin]
}

# Compile one window call into a plan dict for runWindows.
proc ::mkitsql::compileWindow {w ctx} {
    lassign $w _ name distinct args spec
    set part [dict get $spec partition]
    set ords [dict get $spec order]
    set exprs $part
    set otypes {} ; set dirs {} ; set nulls {}
    foreach o $ords {
        lappend exprs [lindex $o 0]
        lappend otypes [dryType [lindex $o 0]]
        lappend dirs [lindex $o 1] ; lappend nulls [lindex $o 2]
    }
    set argNodes {}
    set sortKind s
    if {[lindex $args 0 0] ne "star"} {
        foreach a $args { lappend argNodes $a }
        if {$name in {SUM AVG} && [dryType [lindex $argNodes 0]] eq "text"} {
            lset argNodes 0 [list cast [lindex $argNodes 0] double]
        }
        if {[llength $argNodes]} { set sortKind [expr {[isNumType [dryType [lindex $argNodes 0]]] ? "n" : "s"}] }
        if {$name in {SUM AVG MIN MAX} && [dryType [lindex $argNodes 0]] eq "interval"} { set sortKind i }
    }
    lassign [compileList [concat $exprs $argNodes] $ctx] wp _
    return [dict create fn $name np [llength $part] no [llength $ords] nargs [llength $argNodes] \
        star [expr {[lindex $args 0 0] eq "star"}] proc $wp dirs $dirs nulls $nulls otypes $otypes \
        frame [dict get $spec frame] sortKind $sortKind distinct $distinct \
        exclude [specGet $spec exclude ""] ignorenulls [specGet $spec ignorenulls 0]]
}

# ---- FROM tree -------------------------------------------------------------
# Each returns a dict:  plan  srcs (ids, in tuple order)  width  map
proc ::mkitsql::cfNode {t pushable stVar} {
    upvar 1 $stVar st
    switch -- [lindex $t 0] {
        src  { return [cfLeaf [lindex $t 1] $pushable st] }
        join { return [cfJoin $t $pushable st] }
    }
    error "cfNode: [lindex $t 0]"
}

# ---- pushing simple conditions into Metakit -------------------------------------------------------------
# A top-level AND conjunct of the form  column OP constant,  column BETWEEN a AND b  or  column IN (constants)  on a
# stored number or text column can be decided inside Metakit by mk::select, so only the rows that can match are
# read.  This only NARROWS the rows: the complete WHERE is still evaluated on every candidate, so a condition that
# is pushed loosely (a strict < as <=, a double as a range) can never change a result.  Anything that is not
# certain to select a superset of the true matches is left to the normal filter.
# Returns {conds in} : conds = {{exact|min|max column value}...}, in = {} or {column {conds-per-value...}}.
proc ::mkitsql::pushSpec {s id conjuncts} {
    variable pushdown
    if {!$pushdown} { return {} }
    set cols [dict create]
    foreach c [dict get $s cols] {
        lassign $c n t l isSub
        if {!$isSub} { dict set cols [string tolower $n] [list $n $l] }
    }
    set conds {} ; set in {}
    foreach c $conjuncts {
        switch -- [lindex $c 0] {
            bin {
                lassign $c _ op a b
                if {$op ni {= < <= > >=}} continue
                if {[lindex $a 0] eq "ref" && [lindex $b 0] eq "lit"} {
                    set col $a ; set k $b
                } elseif {[lindex $b 0] eq "ref" && [lindex $a 0] eq "lit"} {
                    set col $b ; set k $a ; set op [string map {< > > < <= >= >= <=} $op]
                } else continue
                set r [pushOne $cols $id $col $op $k]
                if {[llength $r]} { lappend conds {*}$r }
            }
            between {
                lassign $c _ e lo hi neg
                if {$neg || [lindex $e 0] ne "ref" || [lindex $lo 0] ne "lit" || [lindex $hi 0] ne "lit"} continue
                set r1 [pushOne $cols $id $e >= $lo] ; set r2 [pushOne $cols $id $e <= $hi]
                if {[llength $r1] && [llength $r2]} { lappend conds {*}$r1 {*}$r2 }
            }
            like {
                # col LIKE 'abc%' / '%abc%' (case-sensitive, no _): Metakit's own -glob decides it in C; the full LIKE is still evaluated on the candidates
                lassign $c _ e pat esc neg ci
                if {$neg || $ci || $esc ne "" || [lindex $e 0] ne "ref" || [lindex $pat 0] ne "lit" || [lindex $pat 1] ne "text"} continue
                set r [pushLike $cols $id $e [lindex $pat 2]]
                if {[llength $r]} { lappend conds {*}$r }
            }
            in {
                lassign $c _ e items neg
                if {$neg || [llength $in] || [lindex $e 0] ne "ref" || ![llength $items] || [llength $items] > 64} continue
                set per {} ; set okAll 1
                foreach it $items {
                    if {[lindex $it 0] ne "lit"} { set okAll 0 ; break }
                    set r [pushOne $cols $id $e = $it]
                    if {![llength $r]} { set okAll 0 ; break }
                    lappend per $r
                }
                if {$okAll} { set in [list [lindex $e 3] $per] }
            }
        }
    }
    if {![llength $conds] && ![llength $in]} { return {} }
    # equalities narrow most, so Metakit should apply them first
    set conds [lsort -index 0 $conds]
    return [list $conds $in]
}
# column LIKE pattern -> {{glob column pattern}} for a text column, a pattern without _ and with at least one literal character, else {}
proc ::mkitsql::pushLike {cols id ref pat} {
    lassign $ref _ lvl src name rty
    if {$lvl != 0 || $src != $id} { return {} }
    set key [string tolower $name]
    if {![dict exists $cols $key]} { return {} }
    lassign [dict get $cols $key] cname letter
    if {$letter ne "S" || [string first _ $pat] >= 0 || $pat eq ""} { return {} }
    set g "" ; set lit 0 ; set afterPct 0
    foreach ch [split $pat ""] {
        if {$ch eq "%"} { if {!$afterPct} { append g "*" } ; set afterPct 1 ; continue }
        set afterPct 0
        if {$ch in {* ? [ ] \\}} { append g "\\" }
        append g $ch ; set lit 1
    }
    if {!$lit} { return {} }
    return [list [list glob $cname $g]]
}
# one comparison  column OP literal  ->  list of {kind column value} conditions, or {} when it cannot be pushed safely
proc ::mkitsql::pushOne {cols id ref op k} {
    lassign $ref _ lvl src name rty
    if {$lvl != 0 || $src != $id} { return {} }
    set key [string tolower $name]
    if {![dict exists $cols $key]} { return {} }
    lassign [dict get $cols $key] cname letter
    lassign $k _ kt kv
    if {$kt eq "null"} { return {} }
    switch -- $letter {
        I - L {
            if {$kt eq "int"} { set x $kv } elseif {$kt eq "real" && [string is double -strict $kv] && $kv == entier($kv) && abs($kv) < 9e15} { set x [expr {entier($kv)}] } else { return {} }
            if {![string is wideinteger -strict $x]} { return {} }
            if {$letter eq "I" && ($x < -2147483647 || $x > 2147483646)} { return {} }
            if {$letter eq "L" && ($x < -9223372036854775806 || $x > 9223372036854775806)} { return {} }
            switch -- $op {
                =  { return [list [list exact $cname $x]] }
                >= { return [list [list min $cname $x]] }
                >  { return [list [list min $cname [expr {$x + 1}]]] }
                <= { return [list [list max $cname $x]] }
                <  { return [list [list max $cname [expr {$x - 1}]]] }
            }
        }
        D {
            if {$kt ni {int real} || ![string is double -strict $kv] || abs($kv) > 1e300} { return {} }
            switch -- $op {
                =  { return [list [list min $cname $kv] [list max $cname $kv]] }   ;# -exact compares the text of a double
                >= - > { return [list [list min $cname $kv]] }
                <= - < { return [list [list max $cname $kv]] }
            }
        }
        S {
            if {$op ne "=" || $kt ni {text datetime}} { return {} }
            return [list [list exact $cname $kv]]
        }
    }
    return {}
}

# Positions (in the scan's props) of the blob columns that none of the scan's own conditions mentions: reading them can wait
# until a row has passed the filter (`late` in a scan node).  Every reference anywhere in the conditions counts, also inside
# subqueries, so a blob the filter can see is always read first.
proc ::mkitsql::lateBlobs {lay bcols id conds} {
    set used [dict create]
    foreach c $conds { refNames $c $id used }
    set out {}
    foreach k $bcols {
        if {![dict exists $used [string tolower [lindex [dict get $lay props] $k]]]} { lappend out $k }
    }
    return $out
}
proc ::mkitsql::refNames {node id usedVar} {
    upvar 1 $usedVar used
    if {[catch {llength $node} n] || $n < 2 || [lindex $node 0] eq "lit"} return
    if {[lindex $node 0] eq "ref" && $n == 5} {
        if {[lindex $node 2] eq $id} { dict set used [string tolower [lindex $node 3]] 1 }
        return
    }
    foreach x $node { refNames $x $id used }
}

proc ::mkitsql::cfLeaf {s pushable stVar {latmap {}}} {
    upvar 1 $stVar st
    variable curCol ; variable derivedBq
    set id [dict get $s id]
    set lay [dict get $st lay $id]
    set map {} ; set i 0
    foreach n [dict get $lay names] { dict set map $id,$n $i ; incr i }
    set width $i
    set filter "" ; set lookup {} ; set sfilter "" ; set dfilter "" ; set push {}
    set late [dict get $lay bcols]
    if {$pushable} {
        set own [takePool st [list $id]]
        # blobs the filter does not look at are read only for the rows it lets through
        if {[llength $late]} { set late [lateBlobs $lay $late $id $own] }
        if {[dict get $s kind] eq "table"} {
            # `inner = <expression of an enclosing query>` becomes a hash lookup, built once per statement
            variable lookupSeq
            set kl {} ; set kr {} ; set rest {}
            foreach c $own {
                set done 0
                if {[lindex $c 0] eq "bin" && [lindex $c 1] eq "="} {
                    foreach {a b} [list [lindex $c 2] [lindex $c 3] [lindex $c 3] [lindex $c 2]] {
                        if {[localSrcs $a] eq [list $id] && ![hasOuterRef $a] && [localSrcs $b] eq {} && [hasOuterRef $b]} {
                            set kp [keyPair $a $b]
                            if {$kp ne ""} { lappend kl [lindex $kp 0] ; lappend kr [lindex $kp 1] ; set done 1 ; break }
                        }
                    }
                }
                if {!$done} { lappend rest $c }
            }
            if {[llength $kl]} {
                set outer [dict get $st outer]
                lassign [compileList $kl [dict create maps [concat [list $map] $outer]]] ikey _
                lassign [compileList $kr [dict create maps [concat [list {}] $outer]]] okey _
                set lookup [dict create lid [incr lookupSeq] ikey $ikey okey $okey]
                set own $rest
            }
        }
        set filter [compileFilter $own $map [dict get $st outer]]
        # conjuncts that do not depend on an enclosing query can be applied once and cached
        set stat {} ; set dyn {}
        foreach c $own { if {[hasOuterRef $c]} { lappend dyn $c } else { lappend stat $c } }
        set sfilter [compileFilter $stat $map [dict get $st outer]]
        set dfilter [compileFilter $dyn $map [dict get $st outer]]
        if {[dict get $s kind] eq "table"} { set push [pushSpec $s $id $stat] }
    }
    if {!$pushable} { set sfilter "" ; set dfilter "" }
    switch -- [dict get $s kind] {
        table {
            variable scanSeq
            set plan [dict create kind scan path [dict get $s path] props [dict get $lay props] dcols [dict get $lay dcols] \
                subs [dict get $lay subs] filter $filter sfilter $sfilter dfilter $dfilter lookup $lookup push $push sid [incr scanSeq] late $late]
        }
        lateral {
            if {[dict exists $s plevel]} {
                # the subview belongs to a row of an enclosing query: find that row's cursor in the outer tuple
                set pl [dict get $s plevel]
                set om [lindex [dict get $st outer] [expr {$pl - 1}]]
                set key [dict get $s parent],[string tolower $curCol]
                if {![dict exists $om $key]} { fail "Cannot read the subview '[dict get $s sub]' of the enclosing query here" }
                set plan [dict create kind lateralouter level $pl pos [dict get $om $key] sub [dict get $s sub] \
                    props [dict get $lay props] dcols [dict get $lay dcols] subs [dict get $lay subs] filter $filter]
            } else {
                set plan [dict create kind lateral parent [dict get $s parent] sub [dict get $s sub] \
                    props [dict get $lay props] dcols [dict get $lay dcols] subs [dict get $lay subs] filter $filter]
            }
        }
        derived {
            if {[dict exists $s lateralq] && [dict get $s lateralq]} {
                set plan [dict create kind latderived \
                    sub [compileQuery $derivedBq([dict get $s id]) [concat [list $latmap] [dict get $st outer]]] filter $filter]
            } else {
                set om [expr {[dict exists $s outerok] && [dict get $s outerok] ? [dict get $st outer] : {}}]
                set plan [dict create kind derived sub [compileQuery $derivedBq([dict get $s id]) $om] filter $filter]
            }
        }
        wref {
            set plan [dict create kind wref tid [dict get $s tid] filter $filter]
        }
        info {
            set plan [dict create kind info which [dict get $s which] db [dict get $s db] filter $filter]
        }
        default { error "cfLeaf: [dict get $s kind]" }
    }
    return [dict create plan $plan srcs [list $id] width $width map $map]
}

proc ::mkitsql::cfJoin {t pushable stVar} {
    upvar 1 $stVar st
    variable curCol
    lassign $t _ type l r on
    set outer [dict get $st outer]
    set lres [cfNode $l [expr {$pushable && $type in {inner cross left}}] st]
    if {[lindex $r 0] eq "src" && [dict exists [lindex $r 1] lateralq] && [dict get [lindex $r 1] lateralq]} {
        if {$type in {right full}} { fail "RIGHT / FULL JOIN is not supported with LATERAL" }
        set rres [cfLeaf [lindex $r 1] [expr {$pushable && $type in {inner cross}}] st [dict get $lres map]]
    } else {
        set rres [cfNode $r [expr {$pushable && $type in {inner cross right}}] st]
    }
    set lsrcs [dict get $lres srcs] ; set rsrcs [dict get $rres srcs]
    set wl [dict get $lres width] ; set wr [dict get $rres width]
    set lmap [dict get $lres map] ; set rmap [dict get $rres map]
    set cmap $lmap
    dict for {k v} $rmap { dict set cmap $k [expr {$v + $wl}] }

    set rplan [dict get $rres plan]
    set latDerived [expr {[dict get $rplan kind] eq "latderived"}]
    set lateral [expr {[dict get $rplan kind] eq "lateral" || $latDerived}]
    set curPos -1
    if {$lateral && !$latDerived} {
        set parent [dict get $rplan parent]
        set key $parent,[string tolower $curCol]
        if {![dict exists $lmap $key]} { fail "A subview can only be joined to the table that owns it" }
        set curPos [dict get $lmap $key]
        if {$type in {right full}} { fail "RIGHT / FULL JOIN is not supported with a subview" }
    }

    set conds [splitAnd $on]
    set post {}
    if {$pushable && $type in {inner cross}} {
        set conds [concat $conds [takePool st [concat $lsrcs $rsrcs]]]
    }
    # equality conditions between the two sides become hash-join keys
    set lkeys {} ; set rkeys {} ; set resid {}
    foreach c $conds {
        set done 0
        if {!$lateral && [lindex $c 0] eq "bin" && [lindex $c 1] eq "="} {
            set a [lindex $c 2] ; set b [lindex $c 3]
            set sa [localSrcs $a] ; set sb [localSrcs $b]
            if {[llength $sa] && [llength $sb]} {
                if {[subset $sa $lsrcs] && [subset $sb $rsrcs]} { set kl $a ; set kr $b ; set ok 1
                } elseif {[subset $sb $lsrcs] && [subset $sa $rsrcs]} { set kl $b ; set kr $a ; set ok 1
                } else { set ok 0 }
                if {$ok} {
                    set tl [dryType $kl] ; set tr [dryType $kr]
                    set nl [isNumType $tl] ; set nr [isNumType $tr]
                    if {$nl && $nr} {
                        if {$tl ne $tr && !($tl in {int bool} && $tr in {int bool})} {
                            set kl [list cast $kl double] ; set kr [list cast $kr double]
                        }
                        lappend lkeys $kl ; lappend rkeys $kr ; set done 1
                    } elseif {!$nl && !$nr && $tl ne "null" && $tr ne "null"} {
                        lappend lkeys $kl ; lappend rkeys $kr ; set done 1
                    }
                }
            }
        }
        if {!$done} { lappend resid $c }
    }
    set lkp "" ; set rkp ""
    if {[llength $lkeys]} {
        lassign [compileList $lkeys [dict create maps [concat [list $lmap] $outer]]] lkp _
        lassign [compileList $rkeys [dict create maps [concat [list $rmap] $outer]]] rkp _
    }
    set residProc [compileFilter $resid $cmap $outer]
    if {$pushable && $type in {left right full}} {
        set post [takePool st [concat $lsrcs $rsrcs]]
    }
    set postProc [compileFilter $post $cmap $outer]

    set plan [dict create kind join type $type left [dict get $lres plan] right $rplan \
        wl $wl wr $wr lkey $lkp rkey $rkp resid $residProc post $postProc \
        lateral $lateral latderived $latDerived curPos $curPos]
    return [dict create plan $plan srcs [concat $lsrcs $rsrcs] width [expr {$wl + $wr}] map $cmap]
}

# ---- information_schema ----------------------------------------------------
proc ::mkitsql::letterSqlName {l} {
    switch -- $l {
        S { return VARCHAR } I { return INTEGER } L { return BIGINT } F { return REAL }
        D { return "DOUBLE PRECISION" } B { return BLOB } V { return TABLE }
    }
    return $l
}
proc ::mkitsql::infoRows {which {ctx {}}} {
    set rows {}
    foreach tag [::mkitsql::db::tags] {
        foreach v [::mkitsql::db::views $tag] {
            if {$which eq "tables"} {
                lappend rows [list [cleanText $tag] [cleanText $v] "BASE TABLE" [::mkitsql::db::size $tag.$v]]
            } else {
                set i 0
                foreach c [::mkitsql::db::layout $tag.$v] {
                    lappend rows [list [cleanText $tag] [cleanText $v] [cleanText [lindex $c 0]] [incr i] [letterSqlName [lindex $c 1]] [lindex $c 1]]
                }
            }
        }
    }
    return $rows
}

# ============================================================================
#  Subquery runtime   (all of these stop reading as soon as they know the answer)
# ============================================================================
proc ::mkitsql::tick {} {
    variable ticks ; variable cancel ; variable progressHook
    if {[incr ticks] % 100 == 0} {
        if {$cancel} { fail "Cancelled" }
        if {$progressHook ne ""} { {*}$progressHook }
    }
}
# A correlated subquery's answer depends only on the outer values it reads (`key`, built by subKey): the answer is remembered per key
# for the statement, so many outer rows with the same key cost one run.  Bounded: past maxMemo remembered keys new ones are computed
# but not kept.  `key` is "" when the answer cannot be shared (RANDOM() inside, or nothing to key on).
proc ::mkitsql::rt::memoGet {id key var} {
    upvar 1 $var v
    variable ::mkitsql::memo
    if {[info exists memo($id,$key)]} { set v $memo($id,$key) ; return 1 }
    return 0
}
proc ::mkitsql::rt::memoPut {id key v} {
    variable ::mkitsql::memo ; variable ::mkitsql::memoCount ; variable ::mkitsql::maxMemo ; variable ::mkitsql::memoUsed ; variable ::mkitsql::memoBytes
    # bounded by the number of keys AND by their size (an IN (...) answer is a whole set of values)
    if {$memoCount >= $maxMemo} { return $v }
    set size [expr {[string length $key] + [string length $v] + 100}]
    if {$memoUsed + $size > $memoBytes} { return $v }
    set memo($id,$key) $v ; incr memoCount ; incr memoUsed $size
    return $v
}
proc ::mkitsql::rt::scalar {id r0 outer {key ""}} {
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    if {!$corr && [info exists ::mkitsql::subCache($id)]} { return $::mkitsql::subCache($id) }
    set m [expr {$key ne "" && $::mkitsql::planMemo($id)}]
    if {$m && [memoGet $id $key v]} { return $v }
    set rows [::mkitsql::collectPlan $id [linsert $outer 0 $r0] 2]
    switch -- [llength $rows] {
        0 { set v $::mkitsql::N }
        1 { set v [lindex $rows 0 0] }
        default { ::mkitsql::fail "More than one row returned by a subquery used as an expression" }
    }
    if {!$corr} { set ::mkitsql::subCache($id) $v }
    if {$m} { memoPut $id $key $v }
    return $v
}
proc ::mkitsql::rt::exists {id r0 outer {key ""}} {
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    if {!$corr && [info exists ::mkitsql::subCache($id)]} { return $::mkitsql::subCache($id) }
    set m [expr {$key ne "" && $::mkitsql::planMemo($id)}]
    if {$m && [memoGet $id $key v]} { return $v }
    set v [expr {[llength [::mkitsql::collectPlan $id [linsert $outer 0 $r0] 1]] > 0}]
    if {!$corr} { set ::mkitsql::subCache($id) $v }
    if {$m} { memoPut $id $key $v }
    return $v
}
# the distinct values of a one-column subquery as {dict hasNull}; refuses sets too big to hold
proc ::mkitsql::valueSet {id r0 outer} {
    variable S
    set c [newId] ; set S($c,set) [dict create] ; set S($c,null) 0
    streamPlan $id [linsert $outer 0 $r0] [list ::mkitsql::setSink $c]
    set r [list $S($c,set) $S($c,null)]
    array unset S $c,*
    return $r
}
proc ::mkitsql::setSink {c chunk} {
    variable S ; variable N ; variable maxSetRows
    foreach row $chunk {
        set x [lindex $row 0]
        if {$x eq $N} { set S($c,null) 1 } else { dict set S($c,set) $x 1 }
    }
    if {[dict size $S($c,set)] > $maxSetRows} {
        fail "A subquery used with IN / ANY / ALL returned more than $maxSetRows distinct values.  Rewrite it as a JOIN, or raise ::mkitsql::maxSetRows"
    }
    return 0
}
# v op ANY / ALL (subquery)
proc ::mkitsql::rt::quant {id nm kind ck v r0 outer {key ""}} {
    set N $::mkitsql::N
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    set m [expr {$key ne "" && $::mkitsql::planMemo($id)}]
    if {!$corr && [info exists ::mkitsql::subCache($id)]} {
        set vals $::mkitsql::subCache($id)
    } elseif {$m && [memoGet $id $key vals]} {
    } else {
        set vals {}
        foreach r [::mkitsql::collectPlan $id [linsert $outer 0 $r0]] { lappend vals [lindex $r 0] }
        if {!$corr} { set ::mkitsql::subCache($id) $vals }
        if {$m} { memoPut $id $key $vals }
    }
    set cmp ::mkitsql::rt::${nm}_$ck
    set sawNull 0
    foreach x $vals {
        set c [$cmp $v $x]
        if {$c eq $N} { set sawNull 1 ; continue }
        if {$kind eq "any"} { if {$c} { return 1 } } else { if {!$c} { return 0 } }
    }
    if {$sawNull} { return $N }
    return [expr {$kind eq "all"}]
}

proc ::mkitsql::rt::insub {id v r0 outer {key ""}} {
    set N $::mkitsql::N
    if {$v eq $N} {
        # NULL IN (empty set) is false, otherwise unknown
        set rows [::mkitsql::collectPlan $id [linsert $outer 0 $r0] 1]
        return [expr {[llength $rows] ? $N : 0}]
    }
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    set m [expr {$key ne "" && $::mkitsql::planMemo($id)}]
    if {!$corr && [info exists ::mkitsql::subCache($id)]} {
        lassign $::mkitsql::subCache($id) set hasNull
    } elseif {$m && [memoGet $id $key sv]} {
        lassign $sv set hasNull
    } else {
        lassign [::mkitsql::valueSet $id $r0 $outer] set hasNull
        if {!$corr} { set ::mkitsql::subCache($id) [list $set $hasNull] }
        if {$m} { memoPut $id $key [list $set $hasNull] }
    }
    if {[dict exists $set $v]} { return 1 }
    # numeric equality such as 2 vs 2.0
    if {[string is double -strict $v]} {
        dict for {k _} $set { if {[string is double -strict $k] && $k == $v} { return 1 } }
    }
    return [expr {$hasNull ? $N : 0}]
}

# ============================================================================
#  EXPLAIN: describe how a compiled query runs
# ============================================================================
proc ::mkitsql::execExplain {q} {
    variable plans
    set bq [bindQuery $q]
    set id [compileQuery $bq {}]
    set lines [explainPlan $id 0]
    set rows {}
    foreach l $lines { lappend rows [list $l] }
    return [rowset {plan} {""} $rows]
}
proc ::mkitsql::explainPlan {id depth} {
    variable plans ; variable pushMin
    set p $plans($id) ; set ind [string repeat "  " $depth] ; set out {}
    switch -- [dict get $p kind] {
        select {
            set src [dict get $p src]
            set what "SELECT"
            if {[dict get $p distinct]} { append what " DISTINCT" }
            lappend out "$ind$what"
            set i2 "$ind  "
            if {[dict exists $p limit] && [dict get $p limit] ne ""} {}
            # the order the stages run in: source, filter, aggregate, windows, project, distinct, sort, limit
            lappend out "${i2}source:"
            lappend out {*}[explainSource $src [expr {$depth + 2}]]
            if {[dict get $p where] ne ""} { lappend out "${i2}FILTER on rows that survive the joins (WHERE conditions that span several tables)" }
            if {[dict exists $p agg]} {
                set a [dict get $p agg] ; set specs [dict get $a specs]
                set countAll [expr {[dict get $p where] eq "" && [dict get $a ng] == 0 && [llength $specs] == 1 && [lindex $specs 0 0] eq "cstar" \
                    && [dict get $src kind] eq "scan" && [dict get $src filter] eq "" && [dict get $src lookup] eq ""}]
                if {$countAll} {
                    lappend out "${i2}COUNT(*) answered from the row count: no rows are read"
                } else {
                    set nd 0 ; foreach s $specs { if {[lindex $s 1] && [lindex $s 0] in {count sum avg string_agg}} { incr nd } }
                    set txt "AGGREGATE: [expr {[dict get $a ng] ? "[dict get $a ng] group column(s), hash table" : "one group"}], [llength $specs] function(s)"
                    if {$nd} { append txt "; $nd DISTINCT aggregate(s) de-duplicate in separate spill-capable branches" }
                    lappend out "$i2$txt (spills to disk beyond ::mkitsql::memBytes)"
                }
                if {[dict exists $p having]} { lappend out "${i2}HAVING filter" }
            }
            if {[dict exists $p windows]} { lappend out "${i2}WINDOW: [llength [dict get $p windows]] function(s), one sorted pass per window when the input exceeds the budget" }
            if {[dict get $p distinct]} { lappend out "${i2}DISTINCT: streaming hash set, spills to disk beyond the budget" }
            if {[llength [dict get $p order]]} { lappend out "${i2}SORT on [llength [dict get $p order]] key(s): top-N heap when LIMIT is small, else external merge sort" }
            if {[dict get $p limit] ne "" || ([dict get $p offset] ne "" && [dict get $p offset] > 0)} {
                lappend out "${i2}LIMIT [dict get $p limit] OFFSET [expr {[dict get $p offset] eq "" ? 0 : [dict get $p offset]}]"
            }
        }
        values { lappend out "${ind}VALUES ([expr {[dict exists $p lits] ? [llength [dict get $p lits]] : [llength [dict get $p procs]]}] row(s))" }
        setop {
            lappend out "${ind}[string toupper [dict get $p op]][expr {[dict get $p all] ? { ALL} : {}}]: sorted comparison of the two inputs, spills to disk beyond the budget"
            lappend out {*}[explainPlan [dict get $p left] [expr {$depth + 1}]]
            lappend out {*}[explainPlan [dict get $p right] [expr {$depth + 1}]]
        }
        recursive {
            lappend out "${ind}RECURSIVE CTE ([expr {[dict get $p all] ? {UNION ALL} : {UNION}}]): the anchor, then the recursive step repeated until it adds no rows"
            lappend out "$ind  anchor:" ; lappend out {*}[explainPlan [dict get $p anchor] [expr {$depth + 2}]]
            lappend out "$ind  step:" ; lappend out {*}[explainPlan [dict get $p step] [expr {$depth + 2}]]
        }
        query {
            set txt "QUERY"
            if {[llength [dict get $p order]]} { append txt ", ORDER BY [llength [dict get $p order]] key(s)" }
            if {[dict get $p limit] ne ""} { append txt ", LIMIT [dict get $p limit]" }
            lappend out "$ind$txt"
            lappend out {*}[explainPlan [dict get $p body] [expr {$depth + 1}]]
        }
    }
    return $out
}
proc ::mkitsql::explainSource {n depth} {
    variable pushMin
    set ind [string repeat "  " $depth] ; set out {}
    switch -- [dict get $n kind] {
        scan {
            set path [dict get $n path]
            set rows [expr {[catch {::mkitsql::db::size $path} sz] ? "?" : $sz}]
            set txt "SCAN $path ($rows rows)"
            set push [expr {[dict exists $n push] ? [dict get $n push] : ""}]
            if {[dict exists $n lookup] && [dict get $n lookup] ne ""} {
                append txt " - HASH LOOKUP on the join key (built once per statement)"
            } elseif {$push ne ""} {
                lassign $push conds in
                set parts {}
                foreach c $conds { lappend parts "[lindex $c 0] [lindex $c 1] [lindex $c 2]" }
                if {$in ne ""} { lappend parts "[lindex $in 0] IN ([llength [lindex $in 1]] values)" }
                append txt " - METAKIT-SIDE NARROWING ([join $parts {, }])"
                if {$rows ne "?" && $rows < $pushMin} { append txt " (not used below $pushMin rows)" }
            } elseif {[dict get $n filter] ne ""} {
                append txt " - full scan, every row tested"
            } else { append txt " - full scan" }
            if {[dict get $n filter] ne "" && $push ne ""} { append txt "; remaining conditions tested on the candidates" }
            lappend out "$ind$txt"
        }
        join {
            set type [string toupper [dict get $n type]]
            if {[dict get $n lateral]} {
                lappend out "${ind}$type JOIN LATERAL: the right side runs once per left row"
            } elseif {[dict get $n lkey] ne ""} {
                lappend out "${ind}$type JOIN: equality join - hash join, or sort-merge join when the right side exceeds the memory budget"
            } else {
                lappend out "${ind}$type JOIN: no equality key - nested loop over a spooled right side"
            }
            if {[dict get $n resid] ne ""} { lappend out "$ind  with an extra join condition tested per pair" }
            lappend out "$ind  left:" ; lappend out {*}[explainSource [dict get $n left] [expr {$depth + 2}]]
            lappend out "$ind  right:" ; lappend out {*}[explainSource [dict get $n right] [expr {$depth + 2}]]
        }
        lateral - lateralouter { lappend out "${ind}SUBVIEW [dict get $n sub] of each row" }
        derived - latderived { lappend out "${ind}SUBQUERY:" ; lappend out {*}[explainPlan [dict get $n sub] [expr {$depth + 1}]] }
        wref { lappend out "${ind}CTE result (computed once)" }
        info { lappend out "${ind}[dict get $n which]" }
    }
    return $out
}
