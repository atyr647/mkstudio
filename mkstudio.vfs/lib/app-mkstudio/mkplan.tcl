# mkplan.tcl -- the fast execution path of the built-in MKQL dialect.
#
# mkql.tcl owns parsing, binding and the value semantics (compare, arithmetic, functions...).
# This file only makes the same semantics run quickly:
#
#   * pushdown   - top-level AND conjuncts such as  col = 5, col >= 3, col BETWEEN a AND b,
#                  col IN (...)  and  text = 'x'  are answered inside Metakit by mk::select
#                  (milliseconds on 500,000 rows) instead of by looking at every row.  The full
#                  WHERE is still evaluated on the candidates unless every conjunct was pushed
#                  exactly, so pushdown can only ever make the candidate set smaller.
#   * compiling  - expressions are translated once into small Tcl procs working on a row *list*
#                  (no per-row dict, no AST walk); they call the very same helpers (compare,
#                  binv, fnv ...) as the interpreter, so results are identical.
#   * streaming  - GROUP BY keeps one accumulator per group instead of every row.
#   * shortcuts  - COUNT(*) without a filter, and ORDER BY <number column> ... LIMIT n, which
#                  reads one column and fetches only the winning rows.
#
# tests/test_engine_diff.tcl runs thousands of random queries through this path and through the
# original row-at-a-time executor (tests/mkql_reference.tcl) and requires identical results.
#
# Row layout inside a scan:  { used columns... , used subview row counts... , _rowid }.

namespace eval ::mkql {
    variable gen        ;# compile context: ns, nk (constant counter), consts
    variable cmap       ;# canonical column -> {index type}
    variable amap       ;# lower-case alias -> index in the extended row
    variable gseq 0
    variable pushdown 1   ;# tests switch these off to separate each fast path from the rest
    variable shortcuts 1  ;# top-k and COUNT(*) without reading rows
    array set cmap {} ; array set amap {}
    set gen [dict create ns "" nk 0 ks {}]
}

# ============================================================================
#  Code generation
# ============================================================================
proc ::mkql::genBegin {} {
    variable gen ; variable gseq
    set ns ::mkql::gen::q[incr gseq]
    namespace eval $ns {}
    set gen [dict create ns $ns nk 0 ks {}]
}
proc ::mkql::genEnd {} {
    variable gen
    set ns [dict get $gen ns]
    if {$ns ne ""} { catch {namespace delete $ns} }
    set gen [dict create ns "" nk 0 ks {}]
}
# A string constant lives in a namespace variable; code refers to it as $kN.
proc ::mkql::kword {v} {
    variable gen
    set n [dict get $gen nk] ; dict incr gen nk
    set name k$n
    dict lappend gen ks $name
    namespace eval [dict get $gen ns] [list variable $name $v]
    return "\$$name"
}
# "variable x" lines for the constants (and extra arrays) a body actually mentions
proc ::mkql::linkVars {body ks extra} {
    set pre ""
    foreach v $ks { if {[string first "\$$v" $body] >= 0} { append pre "variable $v\n" } }
    foreach v $extra { append pre "variable $v\n" }
    return $pre
}
# Define a proc in the generation namespace.  `extra` = variables to link.
proc ::mkql::genProc {name body {extra {}}} {
    variable gen
    set ns [dict get $gen ns]
    namespace eval $ns [list proc $name {r} [linkVars $body [dict get $gen ks] $extra]$body]
    return ${ns}::$name
}

# A fragment is {kind word num}:
#   B  word is a boolean expression usable inside expr { }
#   N  a value that is certainly a number; num is a literal / expression usable inside expr
#   V  any other value
# `word` is always usable as a command argument (or, for B, inside expr).
proc ::mkql::fB {code} { return [list B $code ""] }
proc ::mkql::fVal {f} {
    lassign $f k w n
    if {$k eq "B"} { return "\[expr \{$w\}\]" }
    return $w
}
proc ::mkql::fBool {f} {
    lassign $f k w n
    switch -- $k {
        B { return $w }
        N { return "($n != 0)" }
    }
    return "\[::mkql::truthy $w\]"
}
proc ::mkql::fNum {f} { return [lindex $f 2] }
proc ::mkql::isN {f} { return [expr {[lindex $f 0] eq "N"}] }

proc ::mkql::numLit {v} {
    # a literal for a value known to look like a number, or "" when it can't be used safely
    if {[catch {tonum $v} x]} { return "" }
    if {![string is double -strict $x] && ![string is wideinteger -strict $x]} { return "" }
    if {[string match -nocase *inf* $x] || [string match -nocase *nan* $x]} { return "" }
    return "($x)"
}

proc ::mkql::isConstAst {ast} {
    switch -- [lindex $ast 0] {
        num - str { return 1 }
        col - alias - agg - aggref - outcol { return 0 }
        fn { foreach a [lindex $ast 2] { if {![isConstAst $a]} { return 0 } } ; return 1 }
        bin - cmp - and - or { return [expr {[isConstAst [lindex $ast 2]] && [isConstAst [lindex $ast 3]]}] }
        not - neg - isnull { return [isConstAst [lindex $ast 1]] }
        like { return [expr {[isConstAst [lindex $ast 1]] && [isConstAst [lindex $ast 2]]}] }
        in {
            if {![isConstAst [lindex $ast 1]]} { return 0 }
            foreach a [lindex $ast 2] { if {![isConstAst $a]} { return 0 } }
            return 1
        }
        between { return [expr {[isConstAst [lindex $ast 1]] && [isConstAst [lindex $ast 2]] && [isConstAst [lindex $ast 3]]}] }
    }
    return 0
}

proc ::mkql::cConst {v} {
    set w [kword $v]
    if {[isnum $v]} {
        set nl [numLit $v]
        if {$nl ne ""} { return [list N $w $nl] }
    }
    return [list V $w ""]
}
proc ::mkql::isStrConst {f} { return [expr {[lindex $f 0] eq "V" && [string index [lindex $f 1] 0] eq "\$"}] }

# Compile a bound expression to a fragment.
proc ::mkql::cc {ast} {
    variable cmap ; variable amap ; variable aggBase
    if {[isConstAst $ast]} {
        if {![catch {ev $ast {}} v]} { return [cConst $v] }
        # would raise at run time (e.g. 1/0): keep it lazy so empty inputs still succeed
        return [list V "\[::mkql::ev [kword $ast] \{\}\]" ""]
    }
    switch -- [lindex $ast 0] {
        col {
            lassign $cmap([lindex $ast 1]) idx type
            set w "\[lindex \$r $idx\]"
            if {$type in {I L F D}} { return [list N $w $w] }
            return [list V $w ""]
        }
        alias {
            set lo [lindex $ast 1]
            if {![info exists amap($lo)]} { error "mkplan: alias $lo is not available here" }
            return [list V "\[lindex \$r $amap($lo)\]" ""]
        }
        aggref { return [list V "\[lindex \$r [expr {$aggBase + [lindex $ast 1]}]\]" ""] }
        neg {
            set a [cc [lindex $ast 1]]
            if {[isN $a]} { set w "\[::mkql::fmtnum \[expr \{-[fNum $a]\}\]\]" ; return [list N $w $w] }
            return [list V "\[::mkql::negv [fVal $a]\]" ""]
        }
        not { return [fB "!([fBool [cc [lindex $ast 1]]])"] }
        and { return [fB "([fBool [cc [lindex $ast 1]]] && [fBool [cc [lindex $ast 2]]])"] }
        or  { return [fB "([fBool [cc [lindex $ast 1]]] || [fBool [cc [lindex $ast 2]]])"] }
        cmp {
            set op [lindex $ast 1]
            set a [cc [lindex $ast 2]] ; set b [cc [lindex $ast 3]]
            set x $op
            if {$op eq "="} { set x == } elseif {$op eq "<>"} { set x != }
            if {[isN $a] && [isN $b]} { return [fB "([fNum $a] $x [fNum $b])"] }
            if {$op in {= <>} && ([isStrConst $a] && ![isnum [constText $ast 2]] || [isStrConst $b] && ![isnum [constText $ast 3]])} {
                set code "\[string equal [fVal $a] [fVal $b]\]"
                return [fB [expr {$op eq "=" ? $code : "!$code"}]]
            }
            return [fB "(\[::mkql::compare [fVal $a] [fVal $b]\] $x 0)"]
        }
        bin {
            set op [lindex $ast 1]
            set a [cc [lindex $ast 2]] ; set b [cc [lindex $ast 3]]
            if {$op in {+ - *} && [isN $a] && [isN $b]} {
                set w "\[::mkql::fmtnum \[expr \{[fNum $a] $op [fNum $b]\}\]\]"
                return [list N $w $w]
            }
            return [list V "\[::mkql::binv [kword $op] [fVal $a] [fVal $b]\]" ""]
        }
        like {
            set a [cc [lindex $ast 1]] ; set neg [lindex $ast 3]
            if {[isConstAst [lindex $ast 2]] && ![catch {ev [lindex $ast 2] {}} p]} {
                set re [kword [likeToRegexp $p]]
                return [fB "(\[regexp -nocase -- $re [fVal $a]\] != $neg)"]
            }
            set p [cc [lindex $ast 2]]
            return [fB "\[::mkql::likev [fVal $a] [fVal $p] $neg\]"]
        }
        in {
            set a [cc [lindex $ast 1]]
            set items {}
            foreach it [lindex $ast 2] { lappend items [fVal [cc $it]] }
            return [fB "\[::mkql::inv [fVal $a] \[list [join $items { }]\] [lindex $ast 3]\]"]
        }
        between {
            set a [cc [lindex $ast 1]] ; set lo [cc [lindex $ast 2]] ; set hi [cc [lindex $ast 3]] ; set neg [lindex $ast 4]
            if {[isN $a] && [isN $lo] && [isN $hi] && [regexp {^\[lindex \$r \d+\]$} [fNum $a]]} {
                set core "([fNum $a] >= [fNum $lo] && [fNum $a] <= [fNum $hi])"
                return [fB [expr {$neg ? "!$core" : $core}]]
            }
            return [fB "\[::mkql::betweenv [fVal $a] [fVal $lo] [fVal $hi] $neg\]"]
        }
        isnull {
            set a [cc [lindex $ast 1]]
            return [fB "([fVal $a] [expr {[lindex $ast 2] ? {ne} : {eq}}] \"\")"]
        }
        fn {
            set vals {}
            foreach a [lindex $ast 2] { lappend vals [fVal [cc $a]] }
            return [list V "\[::mkql::fnv [kword [lindex $ast 1]] \[list [join $vals { }]\]\]" ""]
        }
    }
    error "mkplan: cannot compile node [lindex $ast 0]"
}
# the (folded) text of a constant operand, for the string-equality fast path
proc ::mkql::constText {ast k} {
    set e [lindex $ast $k]
    if {![isConstAst $e] || [catch {ev $e {}} v]} { return 0 }
    return $v
}

proc ::mkql::compilePred {ast name} { return [genProc $name "expr \{[fBool [cc $ast]]\}"] }
proc ::mkql::compileList {asts name} {
    set vals {}
    foreach a $asts { lappend vals [fVal [cc $a]] }
    return [genProc $name "list [join $vals { }]"]
}
proc ::mkql::compileOne {ast name} { return [genProc $name "return [fVal [cc $ast]]"] }

# ============================================================================
#  Pushdown: which rows could possibly match?
# ============================================================================
# lrepeat with a count of 0 is an error in Tcl 8.5
proc ::mkql::rep {n v} { if {$n < 1} { return {} } ; return [lrepeat $n $v] }

proc ::mkql::flattenAnd {ast} {
    if {[lindex $ast 0] eq "and"} { return [concat [flattenAnd [lindex $ast 1]] [flattenAnd [lindex $ast 2]]] }
    return [list $ast]
}
proc ::mkql::colType {layout name} {
    foreach c $layout { if {[lindex $c 0] eq $name} { return [lindex $c 1] } }
    return ""
}
# bound node -> {column type} when it is a plain stored scalar column
proc ::mkql::plainCol {ast layout} {
    if {[lindex $ast 0] ne "col"} { return "" }
    set n [lindex $ast 1]
    if {$n eq "_rowid"} { return "" }
    set t [colType $layout $n]
    if {$t in {I L D S}} { return [list $n $t] }
    return ""
}
proc ::mkql::constOf {ast} {
    if {![isConstAst $ast] || [catch {ev $ast {}} v]} { return [list 0 ""] }
    return [list 1 $v]
}
# One comparison col OP v  ->  {exact conds} or {}.
proc ::mkql::pushCmp {t col op v} {
    set kind ""
    switch -- $op {
        =  { set kind exact ; set ex 1 }
        <= { set kind max ; set ex 1 }
        >= { set kind min ; set ex 1 }
        <  { set kind max ; set ex 0 }
        >  { set kind min ; set ex 0 }
        default { return {} }
    }
    switch -- $t {
        I - L {
            if {![isnum $v]} { return {} }
            set x [tonum $v]
            if {![string is wideinteger -strict $x]} { return {} }
            if {$t eq "I" && ($x < -2147483648 || $x > 2147483647)} { return {} }
        }
        D {
            if {![isnum $v] || [catch {tonum $v} x]} { return {} }
            if {![string is double -strict $x] && ![string is wideinteger -strict $x]} { return {} }
            if {abs($x) > 1e300} { return {} }
        }
        S {
            if {$op ne "=" || [isnum $v]} { return {} }
            set x $v
        }
        default { return {} }
    }
    return [list $ex [eqConds $t $kind $col $x]]
}
# Metakit's -exact compares a double column's TEXT ("7.0" != "7"), so equality on a double is a
# numeric range of width zero instead.
proc ::mkql::eqConds {t kind col x} {
    if {$kind eq "exact" && $t eq "D"} { return [list [list min $col $x] [list max $col $x]] }
    return [list [list $kind $col $x]]
}
proc ::mkql::flipOp {op} { return [string map {< > > < <= >= >= <=} $op] }

# -> {exact conds in}   in = {} or {col type values}
proc ::mkql::pushConj {c layout} {
    switch -- [lindex $c 0] {
        cmp {
            set op [lindex $c 1]
            set a [lindex $c 2] ; set b [lindex $c 3]
            set pc [plainCol $a $layout]
            lassign [constOf $b] okb vb
            if {$pc eq "" || !$okb} {
                set pc [plainCol $b $layout]
                lassign [constOf $a] oka va
                if {$pc eq "" || !$oka} { return {} }
                set op [flipOp $op] ; set vb $va
            }
            set r [pushCmp [lindex $pc 1] [lindex $pc 0] $op $vb]
            if {![llength $r]} { return {} }
            return [list [lindex $r 0] [lindex $r 1] {}]
        }
        between {
            if {[lindex $c 4]} { return {} }
            set pc [plainCol [lindex $c 1] $layout]
            lassign [constOf [lindex $c 2]] ok1 lo ; lassign [constOf [lindex $c 3]] ok2 hi
            if {$pc eq "" || !$ok1 || !$ok2 || [lindex $pc 1] eq "S"} { return {} }
            set r1 [pushCmp [lindex $pc 1] [lindex $pc 0] >= $lo] ; set r2 [pushCmp [lindex $pc 1] [lindex $pc 0] <= $hi]
            if {![llength $r1] || ![llength $r2]} { return {} }
            return [list 1 [concat [lindex $r1 1] [lindex $r2 1]] {}]
        }
        in {
            if {[lindex $c 3]} { return {} }
            set pc [plainCol [lindex $c 1] $layout]
            if {$pc eq "" || [llength [lindex $c 2]] > 64 || ![llength [lindex $c 2]]} { return {} }
            set vals {}
            foreach it [lindex $c 2] {
                lassign [constOf $it] ok v
                if {!$ok} { return {} }
                set r [pushCmp [lindex $pc 1] [lindex $pc 0] = $v]
                if {![llength $r]} { return {} }
                lappend vals [lindex $r 1]          ;# the conditions that select this one value
            }
            return [list 1 {} [list [lindex $pc 0] $vals]]
        }
    }
    return {}
}

# Decide how to find the candidate rows.  Returns {cand skip}: cand is "all" or an ascending
# list of row indices; skip=1 means the WHERE is already fully decided by cand.
proc ::mkql::planWhere {mk layout where} {
    variable pushdown
    if {$where eq ""} { return [list all 1] }
    if {!$pushdown} { return [list all 0] }
    set conds {} ; set exact 1 ; set inSpec {}
    foreach c [flattenAnd $where] {
        set r [pushConj $c $layout]
        if {![llength $r]} { set exact 0 ; continue }
        lassign $r ex cs in
        if {[llength $in]} {
            if {[llength $inSpec]} { set exact 0 ; continue }
            set inSpec $in
        }
        if {!$ex} { set exact 0 }
        lappend conds {*}$cs
    }
    if {![llength $conds] && ![llength $inSpec]} { return [list all 0] }
    # Metakit applies the criteria in the order given: equalities first narrow the rows most
    # (measured: 98 ms vs 466 ms for the same two criteria in the other order)
    set conds [lsort -index 0 $conds]
    if {[catch {
        if {[llength $inSpec]} {
            lassign $inSpec col alts
            set cand {}
            foreach alt [lsort -unique $alts] { lappend cand {*}[::store::select $mk [concat $alt $conds]] }
            set cand [lsort -integer -unique $cand]
        } else {
            set cand [::store::select $mk $conds]
        }
    }]} { return [list all 0] }
    return [list $cand $exact]
}

# ============================================================================
#  Scanning
# ============================================================================
# Feed rows (as flat lists, rowid last) to `consumer` chunk by chunk until it returns 1.
proc ::mkql::scanChunks {mk props subs cand consumer} {
    variable progressHook ; variable cancel
    set cancel 0
    set chunk 1000
    set np [llength $props]
    if {$cand eq "all"} { set total [::store::size $mk] } else { set total [llength $cand] }
    for {set first 0} {$first < $total} {incr first $chunk} {
        if {$cand eq "all"} {
            set ids {}
            set rows [::store::fetch $mk $props $first $chunk]
            set i $first
        } else {
            set ids [lrange $cand $first [expr {$first + $chunk - 1}]]
            set rows [::store::fetchAt $mk $props $ids]
        }
        set out {}
        set j 0
        foreach r $rows {
            set i [expr {$cand eq "all" ? $first + $j : [lindex $ids $j]}]
            foreach s $subs { lappend r [::store::subSize $mk $i $s] }
            lappend r $i
            lappend out $r
            incr j
        }
        if {[{*}$consumer $out]} { return }
        if {$progressHook ne ""} { uplevel #0 $progressHook }
        if {$cancel} { fail "Query cancelled" }
    }
}

# set up the column map for one statement: used props, then used subs, then _rowid
proc ::mkql::setupCols {layout props subs} {
    variable cmap ; variable amap
    array unset cmap ; array set cmap {} ; array unset amap ; array set amap {}
    set idx 0
    foreach p $props { set cmap($p) [list $idx [colType $layout $p]] ; incr idx }
    foreach s $subs { set cmap($s) [list $idx I] ; incr idx }
    set cmap(_rowid) [list $idx I]
    return [expr {$idx + 1}]
}

# Rows (flat lists) matching a bound WHERE, in row order.  stopAt 0 = all.
proc ::mkql::matchRows {mk layout props subs where stopAt} {
    lassign [planWhere $mk $layout $where] cand skip
    set pred ""
    genBegin
    set found {}
    set err [catch {
        if {!$skip && $where ne ""} { set pred [compilePred $where pred] }
        set ::mkql::_acc {}
        scanChunks $mk $props $subs $cand [list ::mkql::matchConsume $pred $stopAt]
        set found $::mkql::_acc
    } msg opts]
    genEnd
    set ::mkql::_acc {}
    if {$err} { return -options $opts $msg }
    return $found
}
proc ::mkql::matchConsume {pred stopAt rows} {
    foreach r $rows {
        if {$pred ne "" && ![$pred $r]} continue
        lappend ::mkql::_acc $r
        if {$stopAt && [llength $::mkql::_acc] >= $stopAt} { return 1 }
    }
    return 0
}
# Row indices only; with an exact pushdown no row is fetched at all.
proc ::mkql::matchIds {mk layout where} {
    lassign [planWhere $mk $layout $where] cand skip
    if {$skip} {
        if {$cand eq "all"} { set n [::store::size $mk] ; set cand {} ; for {set i 0} {$i < $n} {incr i} { lappend cand $i } }
        return $cand
    }
    lassign [usedLists $layout] props subs
    set w [setupCols $layout $props $subs]
    set rows [matchRows $mk $layout $props $subs $where 0]
    set ids {}
    foreach r $rows { lappend ids [lindex $r end] }
    return $ids
}

# ============================================================================
#  Aggregates
# ============================================================================
# Replace aggregate nodes by {aggref slot}; fills the list `aggs` (caller's variable) with
# {fn arg distinct} where arg is a bound expression or "star".
proc ::mkql::aggRewrite {ast aggsVar} {
    upvar 1 $aggsVar aggs
    switch -- [lindex $ast 0] {
        agg {
            set key [lrange $ast 1 3]
            set k [lsearch -exact $aggs $key]
            if {$k < 0} { lappend aggs $key ; set k [expr {[llength $aggs] - 1}] }
            return [list aggref $k]
        }
        num - str - col - alias - outcol - aggref { return $ast }
        fn {
            set args {}
            foreach a [lindex $ast 2] { lappend args [aggRewrite $a aggs] }
            return [list fn [lindex $ast 1] $args]
        }
        bin - cmp { return [list [lindex $ast 0] [lindex $ast 1] [aggRewrite [lindex $ast 2] aggs] [aggRewrite [lindex $ast 3] aggs]] }
        and - or { return [list [lindex $ast 0] [aggRewrite [lindex $ast 1] aggs] [aggRewrite [lindex $ast 2] aggs]] }
        not - neg { return [list [lindex $ast 0] [aggRewrite [lindex $ast 1] aggs]] }
        like { return [list like [aggRewrite [lindex $ast 1] aggs] [aggRewrite [lindex $ast 2] aggs] [lindex $ast 3]] }
        in {
            set items {}
            foreach a [lindex $ast 2] { lappend items [aggRewrite $a aggs] }
            return [list in [aggRewrite [lindex $ast 1] aggs] $items [lindex $ast 3]]
        }
        between {
            return [list between [aggRewrite [lindex $ast 1] aggs] [aggRewrite [lindex $ast 2] aggs] \
                [aggRewrite [lindex $ast 3] aggs] [lindex $ast 4]]
        }
        isnull { return [list isnull [aggRewrite [lindex $ast 1] aggs] [lindex $ast 2]] }
    }
    error "aggRewrite: unknown node [lindex $ast 0]"
}

# Build the per-row accumulator update proc for the aggregate slots.
proc ::mkql::compileAggUpdate {aggs} {
    set body ""
    set k 0
    foreach a $aggs {
        lassign $a fn arg distinct
        if {$arg eq "star"} {
            append body "incr A(\$g,$k)\n"
            incr k ; continue
        }
        set f [cc $arg]
        set known [isN $f]                  ;# a stored number column: never empty, always numeric
        append body "set v [fVal $f]\n"
        if {$distinct} {
            append body "if {\$v ne \"\" && !\[info exists S(\$g,$k,\$v)\]} { set S(\$g,$k,\$v) 1 ; lappend L(\$g,$k) \$v }\n"
        } else {
            switch -- $fn {
                COUNT {
                    if {$known} { append body "incr A(\$g,$k)\n" } else { append body "if {\$v ne \"\"} { incr A(\$g,$k) }\n" }
                }
                SUM - AVG {
                    if {$known} {
                        append body "set A(\$g,$k) \[expr {\$A(\$g,$k) + \$v}\] ; incr N(\$g,$k)\n"
                    } else {
                        append body "if {\$v ne \"\"} {\n"
                        append body "    if {!\[::mkql::isnum \$v\]} { ::mkql::fail \"${fn}(): '\$v' is not a number\" }\n"
                        append body "    set A(\$g,$k) \[expr {\$A(\$g,$k) + \[::mkql::tonum \$v\]}\] ; incr N(\$g,$k)\n}\n"
                    }
                }
                MIN - MAX {
                    set lt [expr {$fn eq "MIN" ? "<" : ">"}]
                    if {$known} {
                        append body "if {!\[info exists A(\$g,$k)\] || \$v $lt \$A(\$g,$k)} { set A(\$g,$k) \$v }\n"
                    } else {
                        append body "if {\$v ne \"\" && (!\[info exists A(\$g,$k)\] || \[::mkql::compare \$v \$A(\$g,$k)\] $lt 0)} { set A(\$g,$k) \$v }\n"
                    }
                }
            }
        }
        incr k
    }
    # the proc takes (g r); genProc declares r, so wrap
    variable gen
    set ns [dict get $gen ns]
    namespace eval $ns [list proc upd {g r} "[linkVars $body [dict get $gen ks] {A N S L}]$body"]
    namespace eval $ns {variable A ; variable N ; variable S ; variable L ; array set A {} ; array set N {} ; array set S {} ; array set L {}}
    return ${ns}::upd
}
proc ::mkql::aggInit {ns g aggs} {
    set k 0
    foreach a $aggs {
        lassign $a fn arg distinct
        if {$arg eq "star" || (!$distinct && $fn eq "COUNT")} {
            set ${ns}::A($g,$k) 0
        } elseif {$distinct} {
            set ${ns}::L($g,$k) {}
        } elseif {$fn in {SUM AVG}} {
            set ${ns}::A($g,$k) 0 ; set ${ns}::N($g,$k) 0
        }
        incr k
    }
}
proc ::mkql::aggResults {ns g aggs} {
    set out {} ; set k 0
    foreach a $aggs {
        lassign $a fn arg distinct
        if {$arg eq "star"} {
            lappend out [set ${ns}::A($g,$k)]
        } elseif {$distinct} {
            lappend out [aggVals $fn 0 [set ${ns}::L($g,$k)]]
        } else {
            switch -- $fn {
                COUNT { lappend out [set ${ns}::A($g,$k)] }
                SUM {
                    set n [set ${ns}::N($g,$k)]
                    lappend out [expr {$n == 0 ? 0 : [fmtnum [set ${ns}::A($g,$k)]]}]
                }
                AVG {
                    set n [set ${ns}::N($g,$k)]
                    lappend out [expr {$n == 0 ? "" : [fmtnum [expr {double([set ${ns}::A($g,$k)]) / $n}]]}]
                }
                MIN - MAX {
                    if {[info exists ${ns}::A($g,$k)]} { lappend out [set ${ns}::A($g,$k)] } else { lappend out "" }
                }
            }
        }
        incr k
    }
    return $out
}

# ============================================================================
#  SELECT core
# ============================================================================
namespace eval ::mkql { variable S ; array set S {} ; variable aggBase 0 }

proc ::mkql::consumePlain {rows} {
    variable S
    set pred $S(pred) ; set proj $S(proj) ; set ext $S(ext) ; set stopAt $S(stopAt)
    foreach r $rows {
        if {$pred ne "" && ![$pred $r]} continue
        set out [$proj $r]
        if {$ext} { lappend S(recs) [list $out [concat $r $out] [lindex $r end]] } else { lappend S(recs) [list $out {} [lindex $r end]] }
        if {$stopAt && [incr S(found)] >= $stopAt} { return 1 }
    }
    return 0
}
proc ::mkql::consumeAgg {rows} {
    variable S
    set pred $S(pred) ; set gk $S(gk) ; set upd $S(upd) ; set ns $S(ns) ; set aggs $S(aggs)
    foreach r $rows {
        if {$pred ne "" && ![$pred $r]} continue
        # (not expr: its ?: would turn a text key like 07 into the number 7)
        if {$gk eq ""} { set key "" } else { set key [$gk $r] }
        if {[dict exists $S(gids) $key]} {
            set g [dict get $S(gids) $key]
        } else {
            set g [llength $S(firsts)]
            dict set S(gids) $key $g
            lappend S(firsts) $r
            aggInit $ns $g $aggs
        }
        $upd $g $r
    }
    return 0
}

# Returns the records {out ext rowid} (before ORDER BY / DISTINCT / LIMIT, which the caller applies,
# except that ORDER BY has been applied here when `order` is non-empty).
proc ::mkql::runSelect {p} {
    variable S ; variable amap ; variable aggBase ; variable gen ; variable shortcuts
    foreach k {mk layout props subs baseW sel where groupBy having order isAgg distinct limit offset stopAt cand skip} {
        set $k [dict get $p $k]
    }
    set ns [dict get $gen ns]
    set nsel [llength $sel]
    set selAsts {}
    foreach s $sel { lappend selAsts [lindex $s 0] }
    array unset S ; array set S {}
    set S(recs) {} ; set S(found) 0 ; set S(stopAt) $stopAt ; set S(pred) "" ; set S(ext) [expr {[llength $order] > 0}]
    set recs {}

    if {!$isAgg} {
        # ---- plain SELECT ----
        array unset amap ; array set amap {}
        set i 0
        foreach s $sel { set amap([string tolower [lindex $s 1]]) [expr {$baseW + $i}] ; incr i }
        if {!$skip && $where ne ""} { set S(pred) [compilePred $where pred] }
        set S(proj) [compileList $selAsts proj]
        set topk 0
        if {$shortcuts && $skip && !$distinct && $limit ne "" && [llength $order]} {
            set o0 [lindex $order 0] ; set e [lindex $o0 0]
            # ORDER BY an output column that is just a stored column (alias or position) counts too
            if {[lindex $e 0] eq "alias"} {
                set hit ""
                foreach s $sel { if {[string tolower [lindex $s 1]] eq [lindex $e 1]} { set hit [lindex $s 0] } }
                if {$hit ne ""} { set e $hit }
            } elseif {[lindex $e 0] eq "outcol"} {
                set e [lindex [lindex $sel [lindex $e 1]] 0]
            }
            if {[lindex $e 0] eq "col" && [lindex $e 1] ne "_rowid" && [colType $layout [lindex $e 1]] in {I L F D}} { set topk 1 }
        }
        if {$topk} {
            # read just the sort column; fetch only the rows that can appear in the answer
            set col [lindex $e 1] ; set desc [expr {[lindex $o0 1] eq "desc"}]
            set keys [::store::column $mk $col $cand]
            set mode [expr {[colType $layout $col] in {I L} ? "-integer" : "-real"}]
            set idx [lsort $mode -indices [expr {$desc ? "-decreasing" : "-increasing"}] $keys]
            set n [llength $idx]
            set M [expr {$offset + $limit}]
            if {$M < 1} {
                set idx {}
            } elseif {$M < $n} {
                set edge [lindex $keys [lindex $idx [expr {$M - 1}]]]
                set j $M
                while {$j < $n && [lindex $keys [lindex $idx $j]] == $edge} { incr j }
                set idx [lrange $idx 0 [expr {$j - 1}]]
            }
            if {$cand eq "all"} { set ids $idx } else { set ids {} ; foreach j $idx { lappend ids [lindex $cand $j] } }
            set S(stopAt) 0
            scanChunks $mk $props $subs $ids ::mkql::consumePlain
        } else {
            scanChunks $mk $props $subs $cand ::mkql::consumePlain
        }
        set recs $S(recs)
        set orderAsts {}
        foreach o $order { lappend orderAsts [lindex $o 0] }
    } else {
        # ---- aggregates (streaming) ----
        set aggs {}
        set selR {} ; foreach a $selAsts { lappend selR [aggRewrite $a aggs] }
        set havR "" ; if {$having ne ""} { set havR [aggRewrite $having aggs] }
        set orderAsts {}
        foreach o $order {
            set e [lindex $o 0]
            lappend orderAsts [expr {[lindex $e 0] eq "outcol" ? $e : [aggRewrite $e aggs]}]
        }
        set nAgg [llength $aggs]
        set aggBase $baseW
        # COUNT(*) with nothing to look at
        set countOnly [expr {$shortcuts && $skip && ![llength $groupBy] && $having eq "" && !$distinct && ![llength $order]}]
        if {$countOnly} { foreach a $selAsts { if {$a ne "agg COUNT star 0" && [lrange $a 0 3] ne {agg COUNT star 0}} { set countOnly 0 ; break } } }
        if {$countOnly} {
            set c [expr {$cand eq "all" ? [::store::size $mk] : [llength $cand]}]
            set out [rep $nsel $c]
            return [list [list $out {} -1]]
        }
        array unset amap ; array set amap {}
        set i 0
        foreach s $sel { set amap([string tolower [lindex $s 1]]) [expr {$baseW + $nAgg + $i}] ; incr i }
        if {!$skip && $where ne ""} { set S(pred) [compilePred $where pred] }
        set S(gk) ""
        if {[llength $groupBy]} { set S(gk) [compileList $groupBy gk] }
        set S(upd) [compileAggUpdate $aggs]
        set S(ns) $ns ; set S(aggs) $aggs ; set S(gids) [dict create] ; set S(firsts) {}
        scanChunks $mk $props $subs $cand ::mkql::consumeAgg
        if {![llength $groupBy] && ![llength $S(firsts)]} {
            # aggregates over nothing: plain columns have no value
            lappend S(firsts) [concat [rep [llength $props] ""] [rep [llength $subs] 0] -1]
            aggInit $ns 0 $aggs
        }
        set proj [compileList $selR proj]
        set hp ""
        if {$havR ne ""} { set hp [compilePred $havR hav] }
        set g 0
        foreach f $S(firsts) {
            set fr [concat $f [aggResults $ns $g $aggs]]
            incr g
            if {$hp ne "" && ![$hp $fr]} continue
            set out [$proj $fr]
            lappend recs [list $out [concat $fr $out] ""]
        }
    }

    # ---- ORDER BY: stable multi-key sort, last key first ----
    if {[llength $order]} {
        set keyProcs {}
        set k 0
        foreach e $orderAsts {
            if {[lindex $e 0] eq "outcol"} { lappend keyProcs "" } else { lappend keyProcs [compileOne $e key$k] }
            incr k
        }
        set n [llength $recs]
        set perm {}
        for {set i 0} {$i < $n} {incr i} { lappend perm $i }
        for {set k [expr {[llength $order] - 1}]} {$k >= 0} {incr k -1} {
            set o [lindex $order $k]
            set e [lindex $orderAsts $k]
            set kp [lindex $keyProcs $k]
            set kc {}
            if {$kp eq ""} {
                set oi [lindex $e 1]
                foreach r $recs { lappend kc [lindex [lindex $r 0] $oi] }
            } else {
                foreach r $recs { lappend kc [$kp [lindex $r 1]] }
            }
            set perm [sortPerm $perm $kc [expr {[lindex $o 1] eq "desc"}]]
            if {$::mkql::progressHook ne ""} { uplevel #0 $::mkql::progressHook }
        }
        set recs2 {}
        foreach i $perm { lappend recs2 [lindex $recs $i] }
        set recs $recs2
    }
    return $recs
}
