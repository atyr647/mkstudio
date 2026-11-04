# parser.tcl -- lexer and parser for mkit-sql (standard SQL for Metakit).
#
# parseScript text  ->  list of {ast firstPos endPos statementText}
#
# Errors raised by the parser carry  -errorcode {MKQL SYNTAX pos len}  so the
# MK Studio editor can underline the offending token.  (The tag is "MKQL" for
# drop-in compatibility with the dialect this engine replaces.)
#
# Written in Tcl 8.5 syntax (no lmap / try / string cat) so it runs on classic
# tclkits as well as 8.6.
#
# AST overview (all plain Tcl lists/dicts):
#   statement   {KIND payload}   KIND = select insert update delete create drop alter
#                                       begin commit rollback use showtables showdbs describe
#   query       dict: type query, with, body, order, limit, offset
#   body        dict: type select|setop|values|query
#   expression  {lit T V} {param K} {col Q N} {un OP e} {bin OP a b} {isnull e neg}
#               {between e lo hi neg} {like e pat esc neg ci} {in e list neg}
#               {insub e query neg} {exists query} {sub query} {case operand whens else}
#               {cast e type} {func NAME distinct args} {star Q} {isdist a b neg}

namespace eval ::mkitsql {
    # Words that cannot be used as a bare (unquoted) name or alias.
    variable reserved {
        ALL AND AS ASC BETWEEN BY CASE CAST CREATE CROSS DELETE DESC DISTINCT DROP ELSE END
        ESCAPE EXCEPT EXISTS FALSE FETCH FROM FULL GROUP HAVING ILIKE IN INNER INSERT INTERSECT
        INTO IS JOIN LEFT LIKE LIMIT NATURAL NOT NULL OFFSET ON OR ORDER OUTER RIGHT SELECT SET
        TABLE THEN TRUE UNION UPDATE USING VALUES WHEN WHERE WINDOW WITH
    }
    # Words the editor highlights (superset of reserved).
    variable keywords {
        ALL AND AS ASC BETWEEN BY CASE CAST CREATE CROSS DELETE DESC DISTINCT DROP ELSE END
        ESCAPE EXCEPT EXISTS FALSE FETCH FROM FULL GROUP HAVING ILIKE IN INNER INSERT INTERSECT
        INTO IS JOIN LEFT LIKE LIMIT NATURAL NOT NULL OFFSET ON OR ORDER OUTER RIGHT SELECT SET
        TABLE THEN TRUE UNION UPDATE USING VALUES WHEN WHERE WITH
        ALTER ADD COLUMN RENAME TO IF BEGIN COMMIT ROLLBACK TRANSACTION WORK START TRUNCATE
        NULLS FIRST LAST NEXT ROW ROWS ONLY DEFAULT USE SHOW TABLES DATABASES DESCRIBE
        EXTRACT TRIM SUBSTRING POSITION FOR LEADING TRAILING BOTH TYPE DATA
        OVER PARTITION ROWS RANGE GROUPS UNBOUNDED PRECEDING FOLLOWING CURRENT FILTER WINDOW RECURSIVE LATERAL
        ANY SOME MERGE USING MATCHED INTERVAL
    }
    variable aggs {COUNT SUM AVG MIN MAX STRING_AGG GROUP_CONCAT}
    variable winFuncs {ROW_NUMBER RANK DENSE_RANK PERCENT_RANK CUME_DIST NTILE LAG LEAD FIRST_VALUE LAST_VALUE NTH_VALUE}
    variable maxRows 100000          ;# cap for SELECTs with no LIMIT (UI protection)
    variable progressHook {}         ;# called between chunks so a UI can stay responsive
    variable cancel 0
    variable ignoreConstraints 0     ;# 1 = parse and silently drop PRIMARY KEY / NOT NULL / DEFAULT ...

    variable SRC ""
    variable toks {}
    variable ti 0
    variable nparam 0
    variable namedParams {}      ;# :name parameters seen in the statement being parsed

    # comment | block comment | 'string' | "ident" | number | word | operator | stray char
    variable parseCache
    array set parseCache {}
    variable tokenRe {(--[^\n]*)|(/\*(?:[^*]|\*(?!/))*\*/)|('(?:[^']|'')*')|("(?:[^"]|"")*")|((?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)|([A-Za-z_][A-Za-z0-9_$]*)|(<>|!=|<=|>=|==|\|\||[-+*/%=<>(),;.\[\]!@?:])|(\S)}
    # the same tokens without capture groups (three times faster); ::mkitsql::tokenRe above keeps its eight groups, which MK Studio reads for highlighting
    variable tokenFastRe {--[^\n]*|/\*(?:[^*]|\*(?!/))*\*/|'(?:[^']|'')*'|"(?:[^"]|"")*"|(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|[A-Za-z_][A-Za-z0-9_$]*|<>|!=|<=|>=|==|\|\||[-+*/%=<>(),;.\[\]!@?:]|\S}
}

# ============================================================================
#  Lexer
# ============================================================================
# Returns a list of tokens {kind value pos len}; comments are dropped.
# kind: string qident number ident op bad
proc ::mkitsql::tokenize {text} {
    variable tokenFastRe
    set out {}
    # one match per token (no capture groups: they made the regular expression three times slower); the kind follows from the first character
    foreach m [regexp -all -inline -indices -- $tokenFastRe $text] {
        lassign $m s e
        set raw [string range $text $s $e]
        set c [string index $raw 0]
        if {$c eq "'" && [string length $raw] > 1} {
            set kind string ; set val [string map {'' '} [string range $raw 1 end-1]]
        } elseif {$c eq "\"" && [string length $raw] > 1} {
            set kind qident ; set val [string map {\"\" \"} [string range $raw 1 end-1]]
        } else {
            set val $raw
            if {[string match {[A-Za-z_]} $c]} { set kind ident
            } elseif {[string match {[0-9]} $c] || ($c eq "." && [string length $raw] > 1)} { set kind number
            } elseif {[string length $raw] > 1 && (($c eq "-" && [string index $raw 1] eq "-") || ($c eq "/" && [string index $raw 1] eq "*"))} { continue      ;# a comment
            } elseif {[string length $raw] == 1 ? [string first $raw "-+*/%=<>(),;.\[\]!@?:"] >= 0 : $raw in {<> != <= >= == ||}} { set kind op
            } else { set kind bad }
        }
        lappend out [list $kind $val $s [expr {$e - $s + 1}]]
    }
    return $out
}

# Split a token list into statements at ';' (empty statements are dropped).
proc ::mkitsql::splitStatements {tokens} {
    set out {} ; set cur {}
    foreach t $tokens {
        if {[lindex $t 0] eq "op" && [lindex $t 1] eq ";"} {
            if {[llength $cur]} { lappend out $cur }
            set cur {}
        } else {
            lappend cur $t
        }
    }
    if {[llength $cur]} { lappend out $cur }
    return $out
}

# ============================================================================
#  Parser plumbing
# ============================================================================
proc ::mkitsql::err {msg {tok {}}} {
    variable toks
    if {$tok eq ""} {
        set last [lindex $toks end]
        set pos [expr {$last eq "" ? 0 : [lindex $last 2] + [lindex $last 3]}]
        set len 1
    } else {
        set pos [lindex $tok 2] ; set len [lindex $tok 3]
    }
    return -code error -errorcode [list MKQL SYNTAX $pos $len] $msg
}
# A runtime (non-syntax) error.
proc ::mkitsql::fail {msg} { return -code error -errorcode [list MKQL ERROR] $msg }

proc ::mkitsql::peek {{k 0}} { variable toks ; variable ti ; lindex $toks [expr {$ti + $k}] }
proc ::mkitsql::advance {} {
    variable toks ; variable ti
    set t [lindex $toks $ti] ; incr ti ; return $t
}
proc ::mkitsql::isKw {t kw} {
    expr {$t ne "" && [lindex $t 0] eq "ident" && [string equal -nocase [lindex $t 1] $kw]}
}
proc ::mkitsql::isOp {t op} { expr {$t ne "" && [lindex $t 0] eq "op" && [lindex $t 1] eq $op} }
proc ::mkitsql::acceptKw {kw} { variable ti ; if {[isKw [peek] $kw]} { incr ti ; return 1 } ; return 0 }
proc ::mkitsql::acceptOp {op} { variable ti ; if {[isOp [peek] $op]} { incr ti ; return 1 } ; return 0 }
proc ::mkitsql::expectKw {kw} { if {![acceptKw $kw]} { err "Expected $kw" [peek] } }
proc ::mkitsql::expectOp {op} { if {![acceptOp $op]} { err "Expected '$op'" [peek] } }
# Accept a sequence of keywords (all or nothing).
proc ::mkitsql::acceptKws {args} {
    variable ti
    set k 0
    foreach kw $args {
        if {![isKw [peek $k] $kw]} { return 0 }
        incr k
    }
    incr ti $k
    return 1
}
proc ::mkitsql::describe {t} {
    if {$t eq ""} { return "end of statement" }
    return "'[lindex $t 1]'"
}
proc ::mkitsql::isReserved {t} {
    variable reserved
    expr {[lindex $t 0] eq "ident" && [lsearch -exact $reserved [string toupper [lindex $t 1]]] >= 0}
}
# A name: bare word (not reserved) or "quoted".
proc ::mkitsql::parseName {{what name}} {
    set t [peek]
    if {$t eq ""} { err "Expected a $what" }
    switch -- [lindex $t 0] {
        qident { advance ; return [lindex $t 1] }
        ident {
            if {[isReserved $t]} { err "Expected a $what, found keyword '[lindex $t 1]'" $t }
            advance ; return [lindex $t 1]
        }
    }
    err "Expected a $what, found [describe $t]" $t
}
# Tcl reads 08 or 007 as (invalid) octal; SQL reads them as 8 and 7.  Every number that enters
# the engine as text goes through here before any arithmetic.
proc ::mkitsql::normNum {s} {
    regsub {^([-+]?)0+(?=\d)} $s {\1} s
    return $s
}

# A real literal must be finite: 1e999 is an error, not Inf.
proc ::mkitsql::realLiteral {v} {
    set d [expr {double($v)}]
    if {$d == Inf || $d == -Inf || $d != $d} { err "The number '[string range $v 0 40]' is too large (outside the range of a double precision number)" [peek -1] }
    return $d
}

proc ::mkitsql::parseInt {what} {
    set t [peek]
    if {$t eq "" || [lindex $t 0] ne "number" || ![regexp {^\d+$} [lindex $t 1]]} {
        err "Expected a whole number for $what" $t
    }
    advance ; return [normNum [lindex $t 1]]
}
proc ::mkitsql::srcText {a b} {
    variable SRC
    return [string trim [string range $SRC $a [expr {$b - 1}]]]
}

# ============================================================================
#  Expressions   (precedence low -> high:  OR, AND, NOT, predicates,
#                 ||, + -, * / %, unary, primary)
# ============================================================================
# (a literal on its own - the commonest thing in a VALUES list - skips the twelve levels of operator precedence: nothing can follow it but , ) or ;)
namespace eval ::mkitsql { variable fastParse 1 }
proc ::mkitsql::parseExpr {} {
    variable toks ; variable ti ; variable fastParse
    if {$fastParse} {
        set k [lindex $toks $ti 0]
        if {$k eq "number" || $k eq "string"} {
            set nx [lindex $toks [expr {$ti + 1}]]
            if {$nx eq "" || ([lindex $nx 0] eq "op" && [lindex $nx 1] in {, ) ;})} { return [parsePrimary] }
        }
    }
    parseOr
}

proc ::mkitsql::parseOr {} {
    set l [parseAnd]
    while {[acceptKw OR]} { set l [list bin or $l [parseAnd]] }
    return $l
}
proc ::mkitsql::parseAnd {} {
    set l [parseNot]
    while {[acceptKw AND]} { set l [list bin and $l [parseNot]] }
    return $l
}
proc ::mkitsql::parseNot {} {
    if {[acceptKw NOT]} { return [list un not [parseNot]] }
    return [parsePredicate]
}

proc ::mkitsql::parsePredicate {} {
    set l [parseConcat]
    while 1 {
        set t [peek]
        if {$t eq ""} break
        # comparison operators
        set op ""
        if {[lindex $t 0] eq "op"} {
            switch -- [lindex $t 1] {
                =  - ==  { set op = }
                <> - !=  { set op <> }
                <  { set op < }  <=  { set op <= }
                >  { set op > }  >=  { set op >= }
            }
        }
        if {$op ne ""} {
            advance
            if {([isKw [peek] ANY] || [isKw [peek] SOME] || [isKw [peek] ALL]) && [isOp [peek 1] (]} {
                set kind [expr {[isKw [peek] ALL] ? "all" : "any"}]
                advance ; advance
                set q [parseQuery]
                expectOp )
                set l [list quant $op $kind $l $q]
                continue
            }
            set l [mkCompare $op $l [parseConcat]]
            continue
        }
        # IS [NOT] NULL | TRUE | FALSE | DISTINCT FROM x
        if {[isKw $t IS]} {
            advance
            set neg [acceptKw NOT]
            if {[acceptKw NULL]} {
                set l [list isnull $l $neg]
            } elseif {[acceptKw TRUE]} {
                set l [list istf $l 1 $neg]
            } elseif {[acceptKw FALSE]} {
                set l [list istf $l 0 $neg]
            } elseif {[acceptKw DISTINCT]} {
                expectKw FROM
                set l [list isdist $l [parseConcat] $neg]
            } else {
                err "Expected NULL, TRUE, FALSE or DISTINCT FROM after IS" [peek]
            }
            continue
        }
        # [NOT] BETWEEN / IN / LIKE / ILIKE
        set neg 0
        if {[isKw $t NOT]} {
            set n [peek 1]
            if {[isKw $n BETWEEN] || [isKw $n IN] || [isKw $n LIKE] || [isKw $n ILIKE] || ([isKw $n SIMILAR] && [isKw [peek 2] TO])} {
                advance ; set neg 1 ; set t [peek]
            } else break
        }
        if {[isKw $t BETWEEN]} {
            advance
            acceptKw SYMMETRIC
            set lo [parseConcat]
            expectKw AND
            set hi [parseConcat]
            if {[isCollate $l] || [isCollate $lo] || [isCollate $hi]} {
                set both [list bin and [mkCompare >= $l $lo] [mkCompare <= $l $hi]]
                set l [expr {$neg ? [list un not $both] : $both}]
            } else {
                set l [list between $l $lo $hi $neg]
            }
            continue
        }
        if {[isKw $t IN]} {
            advance
            expectOp (
            if {[isKw [peek] SELECT] || [isKw [peek] WITH] || [isKw [peek] VALUES]} {
                set q [parseQuery]
                expectOp )
                if {[lindex $l 0] eq "row"} { set l [rowInSubquery $l $q $neg] } else { set l [list insub $l $q $neg] }
            } elseif {[lindex $l 0] eq "row"} {
                set items [list [parseExpr]]
                while {[acceptOp ,]} { lappend items [parseExpr] }
                expectOp )
                set or ""
                foreach it $items {
                    set eq [mkCompare = $l $it]
                    if {$or eq ""} { set or $eq } else { set or [list bin or $or $eq] }
                }
                if {$neg} { set or [list un not $or] }
                set l $or
            } else {
                set items {}
                if {![isOp [peek] )]} {
                    lappend items [parseExpr]
                    while {[acceptOp ,]} { lappend items [parseExpr] }
                }
                expectOp )
                if {![llength $items]} { err "IN needs at least one value" [peek -1] }
                set anyCollate [isCollate $l]
                foreach it $items { if {[isCollate $it]} { set anyCollate 1 } }
                if {$anyCollate} {
                    set or ""
                    foreach it $items { set eq [mkCompare = $l $it] ; set or [expr {$or eq "" ? $eq : [list bin or $or $eq]}] }
                    set l [expr {$neg ? [list un not $or] : $or}]
                } else {
                    set l [list in $l $items $neg]
                }
            }
            continue
        }
        if {[isKw $t LIKE] || [isKw $t ILIKE] || ([isKw $t SIMILAR] && [isKw [peek 1] TO])} {
            advance
            if {[isKw $t SIMILAR]} { advance ; set ci 2 } else { set ci [string equal -nocase [lindex $t 1] ILIKE] }
            set pat [parseConcat]
            set esc ""
            if {[acceptKw ESCAPE]} { set esc [parseConcat] }
            if {[isCollate $l] || [isCollate $pat]} {
                lassign [unCollate $l] l1 k1 ; lassign [unCollate $pat] p1 k2
                if {$k1 eq "nocase" || $k2 eq "nocase"} { set ci [expr {$ci == 2 ? 3 : 1}] }
                set l $l1 ; set pat $p1
            }
            set l [list like $l $pat $esc $neg $ci]
            continue
        }
        break
    }
    return $l
}

# ---- row values: desugared into ordinary AND / OR chains -----------------------
proc ::mkitsql::rowCols {r} { if {[lindex $r 0] eq "row"} { return [lindex $r 1] } ; return [list $r] }

proc ::mkitsql::mkCompare {op l r} {
    if {[isCollate $l] || [isCollate $r]} { lassign [collateOperands $l $r] l r }
    if {[lindex $l 0] ne "row" && [lindex $r 0] ne "row"} { return [list bin $op $l $r] }
    if {[lindex $l 0] ne "row" || [lindex $r 0] ne "row"} {
        err "A row value (a, b) can only be compared with another row value of the same size" [peek -1]
    }
    set a [lindex $l 1] ; set b [lindex $r 1]
    if {[llength $a] != [llength $b]} { err "Row values have different sizes ([llength $a] and [llength $b])" [peek -1] }
    set eqs {}
    foreach x $a y $b { lappend eqs [list bin = $x $y] }
    set all [andChain $eqs]
    switch -- $op {
        =  { return $all }
        <> { return [list un not $all] }
    }
    # ordering: lexicographic
    set strict [string index $op 0]            ;# < or >
    set or ""
    for {set i 0} {$i < [llength $a]} {incr i} {
        set term [list bin $strict [lindex $a $i] [lindex $b $i]]
        if {$i > 0} { set term [list bin and [andChain [lrange $eqs 0 [expr {$i - 1}]]] $term] }
        if {$or eq ""} { set or $term } else { set or [list bin or $or $term] }
    }
    if {[string length $op] == 2} { set or [list bin or $or $all] }       ;# <= and >=
    return $or
}
proc ::mkitsql::andChain {l} {
    set r ""
    foreach e $l { if {$r eq ""} { set r $e } else { set r [list bin and $r $e] } }
    return $r
}

# (a, b) [NOT] IN (SELECT x, y ...)  ==  [NOT] EXISTS (SELECT 1 FROM (...) q(c1, c2) WHERE c1 = a AND c2 = b)
# The derived table is flagged `outerok` so the subquery may stay correlated with the
# enclosing query.  (Pushing the conditions into the subquery instead would let outer
# column names be captured by the inner table's columns.)
proc ::mkitsql::rowInSubquery {row q neg} {
    set cols {} ; set eqs {} ; set i 0
    foreach x [lindex $row 1] {
        set c __rq_c[incr i]
        lappend cols $c
        lappend eqs [list bin = [list col __rq $c] $x]
    }
    set sel [dict create type select distinct 0 items [list [list {lit int 1} {} 1]] \
        from [list derived $q __rq $cols outerok] where [andChain $eqs] group {} having {} windows [dict create]]
    set inner [dict create type query with {} body $sel order {} limit {} offset {}]
    set e [list exists $inner]
    if {$neg} { set e [list un not $e] }
    return $e
}

proc ::mkitsql::parseConcat {} {
    set l [parseAdd]
    while {[acceptOp ||]} { set l [list bin || $l [parseAdd]] }
    return $l
}
proc ::mkitsql::parseAdd {} {
    set l [parseMul]
    while 1 {
        if {[acceptOp +]} { set l [list bin + $l [parseMul]]
        } elseif {[acceptOp -]} { set l [list bin - $l [parseMul]]
        } else break
    }
    return $l
}
proc ::mkitsql::parseMul {} {
    set l [parseUnary]
    while 1 {
        if {[acceptOp *]} { set l [list bin * $l [parseUnary]]
        } elseif {[acceptOp /]} { set l [list bin / $l [parseUnary]]
        } elseif {[acceptOp %]} { set l [list bin % $l [parseUnary]]
        } else break
    }
    return $l
}
proc ::mkitsql::parseUnary {} {
    if {[acceptOp -]} {
        set e [parseUnary]
        if {[lindex $e 0] eq "lit" && [lindex $e 1] in {int real}} {
            set v [expr {-[lindex $e 2]}]
            if {$v eq "-0.0"} { set v 0.0 }              ;# SQL has no negative zero
            return [list lit [lindex $e 1] $v]
        }
        return [list un neg $e]
    }
    if {[acceptOp +]} { return [parseUnary] }
    set e [parsePrimary]
    while {[acceptKw COLLATE]} {
        set tok [peek]
        set e [list collate $e [collationName [parseName "collation name"] $tok]]
    }
    return $e
}

# ---- COLLATE ----------------------------------------------------------------------------------------------------------
# Supported collations: BINARY (code point order, the default; also C and POSIX) and NOCASE (case-insensitive; also
# CASE_INSENSITIVE).  A collated operand is handled where it is parsed: comparisons, IN, BETWEEN and LIKE compare LOWER() of both
# sides, ORDER BY sorts by LOWER(), GROUP BY groups by LOWER() and shows MIN() of the original text, and in a select list it changes
# nothing.  Anywhere else the binder refuses it.
proc ::mkitsql::collationName {name tok} {
    switch -- [string toupper $name] {
        BINARY - C - POSIX { return binary }
        NOCASE - CASE_INSENSITIVE { return nocase }
    }
    err "Unknown collation '$name' (supported: BINARY, NOCASE)" $tok
}
# ORDER BY x COLLATE NOCASE sorts by LOWER(x)
proc ::mkitsql::orderCollate {e} {
    if {![isCollate $e]} { return $e }
    lassign [unCollate $e] e1 k
    # a position (ORDER BY 1 COLLATE ...) cannot be wrapped: leave the marker, the binder refuses it
    if {[lindex $e1 0] eq "lit"} { return $e }
    return [expr {$k eq "nocase" ? [lowerOf $e1] : $e1}]
}
proc ::mkitsql::isCollate {e} { expr {[lindex $e 0] eq "collate"} }
# strip a top-level COLLATE; {inner kind} with kind "" when there was none
proc ::mkitsql::unCollate {e} { if {[isCollate $e]} { return [list [lindex $e 1] [lindex $e 2]] } ; return [list $e ""] }
proc ::mkitsql::lowerOf {e} { return [list func LOWER 0 [list $e]] }
# the operands of a comparison, made comparable under their collation
proc ::mkitsql::collateOperands {l r} {
    lassign [unCollate $l] l1 k1 ; lassign [unCollate $r] r1 k2
    if {$k1 ne "" && $k2 ne "" && $k1 ne $k2} { err "The two sides of the comparison have different collations" "" }
    if {$k1 eq "nocase" || $k2 eq "nocase"} { return [list [lowerOf $l1] [lowerOf $r1]] }
    return [list $l1 $r1]
}
# replace every occurrence of a pattern expression outside aggregates, window calls and subqueries
proc ::mkitsql::astRepl {n pairs} {
    variable aggs
    set tag [lindex $n 0]
    if {$tag eq "lit"} { return $n }
    if {$tag in {win sub exists insub quant star}} { return $n }
    if {$tag eq "func" && [string toupper [lindex $n 1]] in $aggs} { return $n }
    foreach pr $pairs { if {[sameExpr [lindex $pr 0] $n]} { return [lindex $pr 1] } }
    if {$tag eq "col" || ([llength $n] <= 1 && [llength [lindex $n 0]] <= 1)} { return $n }
    set out {}
    foreach el $n { lappend out [astRepl $el $pairs] }
    return $out
}

proc ::mkitsql::startsQuery {} {
    expr {[isKw [peek] SELECT] || [isKw [peek] WITH] || [isKw [peek] VALUES]}
}

proc ::mkitsql::parsePrimary {} {
    variable nparam
    set t [peek]
    if {$t eq ""} { err "Expression expected" }
    set kind [lindex $t 0] ; set v [lindex $t 1]
    switch -- $kind {
        number {
            advance
            set v [normNum $v]
            if {[regexp {^\d+$} $v]} {
                if {[string is wideinteger -strict $v]} { return [list lit int [expr {$v + 0}]] }
                return [list lit real [realLiteral $v]]
            }
            return [list lit real [realLiteral $v]]
        }
        string { advance ; return [list lit text $v] }
        qident { return [parseColumnOrCall] }
        op {
            switch -- $v {
                ( {
                    advance
                    if {[startsQuery]} {
                        set q [parseQuery]
                        expectOp )
                        return [list sub $q]
                    }
                    set e [parseExpr]
                    if {[isOp [peek] ,]} {
                        set items [list $e]
                        while {[acceptOp ,]} { lappend items [parseExpr] }
                        expectOp )
                        return [list row $items]
                    }
                    expectOp )
                    return $e
                }
                ? { advance ; return [list param [incr nparam]] }
                : {
                    set n [peek 1]
                    if {$n ne "" && [lindex $n 0] eq "ident" && [lindex $n 2] == [lindex $t 2] + 1} {
                        advance ; advance
                        variable namedParams
                        if {[lsearch -exact $namedParams [lindex $n 1]] < 0} { lappend namedParams [lindex $n 1] }
                        return [list param [lindex $n 1]]
                    }
                }
                * { err "'*' is only allowed in the select list or COUNT(*)" $t }
            }
            err "Unexpected '$v'" $t
        }
        ident {
            set u [string toupper $v]
            switch -- $u {
                NULL  { advance ; return {lit null {}} }
                TRUE  { advance ; return {lit bool 1} }
                FALSE { advance ; return {lit bool 0} }
                CASE  { advance ; return [parseCase] }
                CAST  { advance ; return [parseCast] }
                EXISTS {
                    advance ; expectOp (
                    set q [parseQuery]
                    expectOp )
                    return [list exists $q]
                }
                X {
                    # blob literal  X'CAFE'
                    set n [peek 1]
                    if {$n ne "" && [lindex $n 0] eq "string" && [lindex $n 2] == [lindex $t 2] + 1} {
                        advance ; advance
                        set hex [lindex $n 1]
                        if {![regexp {^([0-9A-Fa-f]{2})*$} $hex]} { err "Invalid blob literal" $n }
                        return [list lit blob [binary format H* $hex]]
                    }
                }
                CURRENT_DATE - CURRENT_TIME - CURRENT_TIMESTAMP - LOCALTIME - LOCALTIMESTAMP {
                    advance
                    return [list func $u 0 {}]
                }
                ROW {
                    if {[isOp [peek 1] (]} {
                        advance ; advance
                        set items [list [parseExpr]]
                        while {[acceptOp ,]} { lappend items [parseExpr] }
                        expectOp )
                        return [list row $items]
                    }
                }
                DATE - TIME - TIMESTAMP {
                    set n [peek 1]
                    if {$n ne "" && [lindex $n 0] eq "string"} {
                        advance ; advance
                        return [list cast [list lit text [lindex $n 1]] [string tolower $u]]
                    }
                }
                INTERVAL {
                    set n [peek 1]
                    if {$n ne "" && [lindex $n 0] eq "string"} { advance ; return [parseIntervalLiteral] }
                }
                EXTRACT   { if {[isOp [peek 1] (]} { advance ; return [parseExtract] } }
                TRIM      { if {[isOp [peek 1] (]} { advance ; return [parseTrim] } }
                SUBSTRING { if {[isOp [peek 1] (]} { advance ; return [parseSubstring] } }
                POSITION  { if {[isOp [peek 1] (]} { advance ; return [parsePosition] } }
            }
            if {[isOp [peek 1] (]} { return [parseCall] }
            return [parseColumnOrCall]
        }
        bad {
            if {$v eq "'"} { err "Unterminated string literal" $t }
            err "Unexpected character '$v'" $t
        }
    }
    err "Unexpected [describe $t]" $t
}

# INTERVAL 'text' [unit [TO unit]]     (the INTERVAL keyword is already consumed)
proc ::mkitsql::parseIntervalLiteral {} {
    set tok [advance]
    set from "" ; set to ""
    set units {YEAR MONTH DAY HOUR MINUTE SECOND}
    set t [peek]
    if {$t ne "" && [lindex $t 0] eq "ident" && [string toupper [lindex $t 1]] in $units} {
        set from [string toupper [lindex [advance] 1]]
        if {[acceptKw TO]} {
            set t2 [peek]
            if {$t2 eq "" || [string toupper [lindex $t2 1]] ni $units} { err "Expected YEAR, MONTH, DAY, HOUR, MINUTE or SECOND after TO" $t2 }
            set to [string toupper [lindex [advance] 1]]
        }
    }
    if {[catch {ivParse [lindex $tok 1] $from $to} r opts]} { err $r $tok }
    return [list lit interval [ivMake {*}$r]]
}

# name  |  q.name  |  q.q2.name   (a column reference)
proc ::mkitsql::parseColumnOrCall {} {
    set first [peek]
    if {[lindex $first 0] eq "ident" && [isReserved $first]} {
        err "Unexpected keyword '[lindex $first 1]'" $first
    }
    set parts [list [parseName]]
    while {[isOp [peek] .]} {
        advance
        if {[isOp [peek] *]} { advance ; return [list star [join $parts .]] }
        lappend parts [parseName]
    }
    switch -- [llength $parts] {
        1 { return [list col {} [lindex $parts 0]] }
        2 { return [list col [lindex $parts 0] [lindex $parts 1]] }
        3 { return [list col [join [lrange $parts 0 1] .] [lindex $parts 2]] }
    }
    err "Too many name parts" $first
}

proc ::mkitsql::parseCall {} {
    variable winFuncs ; variable aggs
    set nameTok [advance]
    set name [string toupper [lindex $nameTok 1]]
    expectOp (
    set distinct 0 ; set args {}
    if {[acceptOp *]} {
        if {$name ne "COUNT"} { err "'*' is only allowed in COUNT(*)" [peek -1] }
        set args [list [list star {}]]
    } elseif {![isOp [peek] )]} {
        if {[acceptKw DISTINCT]} { set distinct 1 } else { acceptKw ALL }
        lappend args [parseExpr]
        while {[acceptOp ,]} { lappend args [parseExpr] }
    }
    expectOp )
    # aggregate FILTER (WHERE c)  ==  aggregate over  CASE WHEN c THEN arg END  (aggregates skip NULLs)
    if {[isKw [peek] FILTER]} {
        if {$name ni {COUNT SUM AVG MIN MAX STRING_AGG GROUP_CONCAT}} { err "FILTER is only allowed on aggregate functions" [peek] }
        advance ; expectOp ( ; expectKw WHERE
        set f [parseExpr]
        expectOp )
        if {[lindex $args 0 0] eq "star"} {
            set args [list [list case {} [list [list $f {lit int 1}]] {lit null {}}]]
        } else {
            set args [lreplace $args 0 0 [list case {} [list [list $f [lindex $args 0]]] {lit null {}}]]
        }
    }
    # IGNORE NULLS / RESPECT NULLS (after the closing parenthesis, before OVER)
    set ignoreNulls 0
    if {([isKw [peek] IGNORE] || [isKw [peek] RESPECT]) && [isKw [peek 1] NULLS]} {
        set ignoreNulls [isKw [peek] IGNORE]
        advance ; advance
        if {![isKw [peek] OVER]} { err "IGNORE NULLS / RESPECT NULLS belongs to a window function: it needs an OVER clause" [peek] }
    }
    if {[isKw [peek] OVER]} {
        if {$name ni $winFuncs && $name ni $aggs} { err "${name}() is not a window function" $nameTok }
        advance
        set spec [parseWindowSpec]
        if {$ignoreNulls} {
            if {$name ni {LAG LEAD FIRST_VALUE LAST_VALUE NTH_VALUE}} { err "IGNORE NULLS is only allowed on LAG, LEAD, FIRST_VALUE, LAST_VALUE and NTH_VALUE" $nameTok }
            dict set spec ignorenulls 1
        }
        return [list win $name $distinct $args $spec]
    }
    if {$name in $winFuncs} { err "${name}() is a window function and needs an OVER clause" $nameTok }
    if {$distinct && $name ni {COUNT SUM AVG MIN MAX STRING_AGG GROUP_CONCAT}} {
        err "DISTINCT is only allowed in aggregate functions" $nameTok
    }
    return [list func $name $distinct $args]
}

# OVER name   |   OVER ( [name] [PARTITION BY ..] [ORDER BY ..] [ROWS|RANGE|GROUPS frame] )
proc ::mkitsql::parseWindowSpec {} {
    set spec [dict create base "" partition {} order {} frame {} exclude "" ignorenulls 0]
    if {![isOp [peek] (]} {
        dict set spec base [parseName "window name"]
        return $spec
    }
    advance
    set t [peek]
    if {$t ne "" && [lindex $t 0] in {ident qident} && !([isKw $t PARTITION] || [isKw $t ORDER] || [isKw $t ROWS] || [isKw $t RANGE] || [isKw $t GROUPS]) && !([isOp [peek 1] ,])} {
        dict set spec base [parseName "window name"]
    }
    if {[acceptKw PARTITION]} {
        expectKw BY
        set l [list [parseExpr]]
        while {[acceptOp ,]} { lappend l [parseExpr] }
        dict set spec partition $l
    }
    if {[acceptKw ORDER]} {
        expectKw BY
        set l {}
        while 1 {
            set e [orderCollate [parseExpr]]
            set dir asc
            if {[acceptKw DESC]} { set dir desc } else { acceptKw ASC }
            set nulls ""
            if {[acceptKw NULLS]} {
                if {[acceptKw FIRST]} { set nulls first } elseif {[acceptKw LAST]} { set nulls last } \
                  else { err "Expected FIRST or LAST after NULLS" [peek] }
            }
            lappend l [list $e $dir $nulls]
            if {![acceptOp ,]} break
        }
        dict set spec order $l
    }
    foreach m {ROWS RANGE GROUPS} {
        if {[acceptKw $m]} {
            if {[acceptKw BETWEEN]} {
                set b1 [parseFrameBound]
                expectKw AND
                set b2 [parseFrameBound]
            } else {
                set b1 [parseFrameBound]
                set b2 {current}
            }
            dict set spec frame [list [string tolower $m] $b1 $b2]
            break
        }
    }
    if {[acceptKw EXCLUDE]} {
        if {![llength [dict get $spec frame]]} { err "EXCLUDE needs a frame (ROWS, RANGE or GROUPS ...)" [peek -1] }
        if {[acceptKw CURRENT]} { expectKw ROW ; dict set spec exclude current } \
        elseif {[acceptKw GROUP]} { dict set spec exclude group } \
        elseif {[acceptKw TIES]} { dict set spec exclude ties } \
        elseif {[acceptKw NO]} { expectKw OTHERS ; dict set spec exclude "" } \
        else { err "Expected CURRENT ROW, GROUP, TIES or NO OTHERS after EXCLUDE" [peek] }
    }
    expectOp )
    return $spec
}

proc ::mkitsql::parseFrameBound {} {
    if {[acceptKw UNBOUNDED]} {
        if {[acceptKw PRECEDING]} { return {unbounded_preceding} }
        expectKw FOLLOWING
        return {unbounded_following}
    }
    if {[acceptKw CURRENT]} { expectKw ROW ; return {current} }
    set e [parseConcat]
    if {[acceptKw PRECEDING]} { return [list preceding $e] }
    expectKw FOLLOWING
    return [list following $e]
}

proc ::mkitsql::parseCase {} {
    set operand ""
    if {![isKw [peek] WHEN]} { set operand [parseExpr] }
    set whens {}
    while {[acceptKw WHEN]} {
        set c [parseExpr]
        expectKw THEN
        lappend whens [list $c [parseExpr]]
    }
    if {![llength $whens]} { err "CASE needs at least one WHEN" [peek] }
    set else {lit null {}}
    if {[acceptKw ELSE]} { set else [parseExpr] }
    expectKw END
    return [list case $operand $whens $else]
}

proc ::mkitsql::parseCast {} {
    expectOp (
    set e [parseExpr]
    expectKw AS
    set ty [parseTypeSpec]
    expectOp )
    return [list cast $e $ty]
}

# EXTRACT(field FROM expr)
proc ::mkitsql::parseExtract {} {
    expectOp (
    set f [string toupper [lindex [advance] 1]]
    expectKw FROM
    set e [parseExpr]
    expectOp )
    return [list func EXTRACT 0 [list [list lit text $f] $e]]
}
# TRIM([LEADING|TRAILING|BOTH] [chars] [FROM] expr)   or   TRIM(expr, chars)
proc ::mkitsql::parseTrim {} {
    expectOp (
    set mode both
    foreach m {LEADING TRAILING BOTH} { if {[acceptKw $m]} { set mode [string tolower $m] } }
    set chars {lit text { }}
    if {[acceptKw FROM]} {
        set e [parseExpr]
    } else {
        set first [parseExpr]
        if {[acceptKw FROM]} { set chars $first ; set e [parseExpr] } \
        elseif {[acceptOp ,]} { set chars [parseExpr] ; set e $first } \
        else { set e $first }
    }
    expectOp )
    return [list func TRIM_ 0 [list [list lit text $mode] $chars $e]]
}
# SUBSTRING(expr FROM a [FOR n])  or  SUBSTRING(expr, a [, n])
proc ::mkitsql::parseSubstring {} {
    expectOp (
    set e [parseExpr]
    set args [list $e]
    if {[acceptKw FROM]} {
        lappend args [parseExpr]
        if {[acceptKw FOR]} { lappend args [parseExpr] }
    } else {
        while {[acceptOp ,]} { lappend args [parseExpr] }
    }
    expectOp )
    if {[llength $args] < 2} { err "SUBSTRING needs a start position" [peek] }
    return [list func SUBSTR 0 $args]
}
# POSITION(needle IN haystack)
proc ::mkitsql::parsePosition {} {
    expectOp (
    set a [parseConcat]
    expectKw IN
    set b [parseExpr]
    expectOp )
    return [list func POSITION 0 [list $a $b]]
}

# A SQL type:  INT | VARCHAR(20) | DOUBLE PRECISION | NUMERIC(10,2) | ...
# Returns the normalised lower-case base name (parameters are accepted and ignored).
proc ::mkitsql::parseTypeSpec {} {
    set t [peek]
    if {$t eq "" || [lindex $t 0] ni {ident qident}} { err "Expected a type name" $t }
    advance
    set name [string tolower [lindex $t 1]]
    if {$name eq "double" && [acceptKw PRECISION]} { set name "double" }
    if {$name in {character char national} && [acceptKw VARYING]} { set name varchar }
    if {$name eq "character"} { set name char }
    if {[isOp [peek] (]} {
        advance
        parseInt "type size"
        if {[acceptOp ,]} { parseInt "type scale" }
        expectOp )
    }
    if {$name in {timestamp time} && [acceptKw WITH]} { expectKw TIME ; expectKw ZONE }
    if {$name in {timestamp time} && [acceptKw WITHOUT]} { expectKw TIME ; expectKw ZONE }
    return $name
}

# ============================================================================
#  Queries
# ============================================================================
# query := [WITH cte, ...] body [ORDER BY ..] [LIMIT .. OFFSET ..]
proc ::mkitsql::parseQuery {} {
    set with {}
    if {[acceptKw WITH]} {
        set recursive [acceptKw RECURSIVE]
        while 1 {
            set name [parseName "CTE name"]
            set cols {}
            if {[acceptOp (]} {
                lappend cols [parseName "column name"]
                while {[acceptOp ,]} { lappend cols [parseName "column name"] }
                expectOp )
            }
            expectKw AS
            expectOp (
            set q [parseQuery]
            expectOp )
            lappend with [list $name $cols $q $recursive]
            if {![acceptOp ,]} break
        }
    }
    set body [parseSetExpr]
    set order {} ; set limit {} ; set offset {}
    if {[acceptKw ORDER]} {
        expectKw BY
        while 1 {
            set e [orderCollate [parseExpr]]
            set dir asc
            if {[acceptKw DESC]} { set dir desc } else { acceptKw ASC }
            set nulls ""
            if {[acceptKw NULLS]} {
                if {[acceptKw FIRST]} { set nulls first } elseif {[acceptKw LAST]} { set nulls last } \
                  else { err "Expected FIRST or LAST after NULLS" [peek] }
            }
            lappend order [list $e $dir $nulls]
            if {![acceptOp ,]} break
        }
    }
    # LIMIT n [OFFSET m]   |   [OFFSET m [ROW|ROWS]] [FETCH FIRST|NEXT n ROW|ROWS ONLY]
    while 1 {
        if {[acceptKw LIMIT]} {
            if {[acceptKw ALL]} { set limit {} } else { set limit [parseConcat] }
        } elseif {[acceptKw OFFSET]} {
            set offset [parseConcat]
            if {![acceptKw ROWS]} { acceptKw ROW }
        } elseif {[acceptKw FETCH]} {
            if {![acceptKw FIRST]} { expectKw NEXT }
            set limit [list lit int 1]
            if {![isKw [peek] ROW] && ![isKw [peek] ROWS]} { set limit [parseConcat] }
            if {![acceptKw ROWS]} { expectKw ROW }
            expectKw ONLY
        } else break
    }
    return [dict create type query with $with body $body order $order limit $limit offset $offset]
}

# INTERSECT binds tighter than UNION / EXCEPT.
proc ::mkitsql::parseSetExpr {} {
    set l [parseIntersect]
    while 1 {
        if {[acceptKw UNION]} { set op union } elseif {[acceptKw EXCEPT]} { set op except } else break
        set all 0
        if {[acceptKw ALL]} { set all 1 } else { acceptKw DISTINCT }
        set r [parseIntersect]
        set l [dict create type setop op $op all $all left $l right $r]
    }
    return $l
}
proc ::mkitsql::parseIntersect {} {
    set l [parseSetTerm]
    while {[acceptKw INTERSECT]} {
        set all 0
        if {[acceptKw ALL]} { set all 1 } else { acceptKw DISTINCT }
        set r [parseSetTerm]
        set l [dict create type setop op intersect all $all left $l right $r]
    }
    return $l
}
proc ::mkitsql::parseSetTerm {} {
    if {[isOp [peek] (]} {
        advance
        set q [parseQuery]
        expectOp )
        return $q
    }
    if {[isKw [peek] VALUES]} { return [parseValues] }
    return [parseSelectCore]
}

proc ::mkitsql::parseValues {} {
    expectKw VALUES
    set rows {}
    while 1 {
        expectOp (
        set row [list [parseExpr]]
        while {[acceptOp ,]} { lappend row [parseExpr] }
        expectOp )
        lappend rows $row
        if {![acceptOp ,]} break
    }
    set w [llength [lindex $rows 0]]
    foreach r $rows {
        if {[llength $r] != $w} { err "All rows in VALUES must have the same number of columns" [peek -1] }
    }
    return [dict create type values rows $rows]
}

proc ::mkitsql::parseSelectCore {} {
    if {![isKw [peek] SELECT]} {
        err "Expected SELECT, found [describe [peek]]" [peek]
    }
    advance
    set distinct 0
    if {[acceptKw DISTINCT]} { set distinct 1 } else { acceptKw ALL }
    set items {}
    variable sawCollateItem ; set sawCollateItem 0
    while 1 {
        lappend items [parseSelectItem]
        if {![acceptOp ,]} break
    }
    if {$distinct && $sawCollateItem} { err "COLLATE is not supported in SELECT DISTINCT (it would change which rows are duplicates)" "" }
    set from {} ; set where {} ; set group {} ; set having {}
    if {[acceptKw FROM]} { set from [parseFrom] }
    if {[acceptKw WHERE]} { set where [parseExpr] }
    set gsets {{}} ; set special 0
    if {[acceptKw GROUP]} {
        expectKw BY
        while 1 {
            lassign [parseGroupElement] sp esets
            if {$sp} { set special 1 }
            # the grouping sets of the whole clause: every set so far combined with every set of this element
            set next {}
            foreach a $gsets { foreach b $esets { lappend next [gsUnion $a $b] } }
            set gsets $next
            if {![acceptOp ,]} break
        }
        if {!$special} { set group [lindex $gsets 0] }
    }
    if {[acceptKw HAVING]} { set having [parseExpr] }
    # GROUP BY x COLLATE NOCASE: group by LOWER(x), show MIN(x) wherever the query reads x outside an aggregate
    set pairs {} ; set group2 {}
    foreach g $group {
        if {[isCollate $g]} {
            lassign [unCollate $g] g1 k
            if {$k eq "nocase"} { lappend pairs [list $g1 [list func MIN 0 [list $g1]]] ; set g1 [lowerOf $g1] }
            lappend group2 $g1
        } else { lappend group2 $g }
    }
    if {[llength $pairs]} {
        set group $group2 ; set items2 {}
        foreach it $items {
            lassign $it e alias text
            if {$alias eq "" && [lindex $e 0] eq "col"} { set alias [lindex $e 2] }
            lappend items2 [list [astRepl $e $pairs] $alias $text]
        }
        set items $items2
        if {$having ne ""} { set having [astRepl $having $pairs] }
    } else { set group $group2 }
    set windows [dict create]
    if {[acceptKw WINDOW]} {
        while 1 {
            set wn [parseName "window name"]
            expectKw AS
            expectOp (
            # re-use the OVER parser by stepping back onto the '('
            variable ti
            incr ti -1
            if {[dict exists $windows [string tolower $wn]]} { err "Window '$wn' is defined twice" [peek -1] }
            dict set windows [string tolower $wn] [parseWindowSpec]
            if {![acceptOp ,]} break
        }
    }
    if {$special} { return [rewriteGroupingSets $items $from $where $gsets $having $windows $distinct] }
    return [dict create type select distinct $distinct items $items from $from \
        where $where group $group having $having windows $windows]
}

# ---- GROUP BY ROLLUP / CUBE / GROUPING SETS ----------------------------------------------------------------------------
# A grouping element yields {special sets}: the list of grouping sets (each a list of expressions) it stands for.  The query is then
# rewritten into one ordinary GROUP BY query per set, joined with UNION ALL: an expression that is not grouped in a set reads NULL
# there, and GROUPING(e, ...) becomes the constant bit mask for that set.
proc ::mkitsql::parseGroupElement {} {
    set t [peek]
    if {[isKw $t ROLLUP] && [isOp [peek 1] (]} {
        advance ; advance ; set items [parseGroupItems] ; expectOp )
        set sets {}
        for {set i [llength $items]} {$i >= 0} {incr i -1} { lappend sets [gsConcat [lrange $items 0 [expr {$i - 1}]]] }
        return [list 1 $sets]
    }
    if {[isKw $t CUBE] && [isOp [peek 1] (]} {
        advance ; advance ; set items [parseGroupItems] ; expectOp )
        set n [llength $items] ; set sets {}
        if {$n > 8} { err "CUBE of more than 8 expressions would need over 256 grouping sets" $t }
        for {set mask [expr {(1 << $n) - 1}]} {$mask >= 0} {incr mask -1} {
            set pick {}
            for {set j 0} {$j < $n} {incr j} { if {$mask & (1 << ($n - 1 - $j))} { lappend pick [lindex $items $j] } }
            lappend sets [gsConcat $pick]
        }
        return [list 1 $sets]
    }
    if {[isKw $t GROUPING] && [isKw [peek 1] SETS]} {
        advance ; advance ; expectOp (
        set sets {}
        while 1 {
            lassign [parseGroupElement] sp es
            foreach x $es { lappend sets $x }
            if {![acceptOp ,]} break
        }
        expectOp )
        return [list 1 $sets]
    }
    if {[isOp $t (] && [isOp [peek 1] )]} { advance ; advance ; return [list 1 [list {}]] }
    set e [parseExpr]
    if {[lindex $e 0] eq "row"} { return [list 0 [list [lindex $e 1]]] }       ;# (a, b): both are grouped
    return [list 0 [list [list $e]]]
}
proc ::mkitsql::parseGroupItems {} {
    set items {}
    while 1 {
        set e [parseExpr]
        lappend items [expr {[lindex $e 0] eq "row" ? [lindex $e 1] : [list $e]}]
        if {![acceptOp ,]} break
    }
    return $items
}
proc ::mkitsql::gsConcat {lists} { set out {} ; foreach l $lists { set out [gsUnion $out $l] } ; return $out }
# a + b without repeating an expression (the same expression twice means the same grouping)
proc ::mkitsql::gsUnion {a b} {
    foreach e $b {
        set have 0
        foreach x $a { if {[sameExpr $x $e]} { set have 1 ; break } }
        if {!$have} { lappend a $e }
    }
    return $a
}
# structural equality of two parsed expressions; a column matches the same name with the same or no qualifier
proc ::mkitsql::sameExpr {a b} {
    if {$a eq $b} { return 1 }
    if {[lindex $a 0] eq "col" && [lindex $b 0] eq "col" && [llength $a] == 3 && [llength $b] == 3} {
        if {![string equal -nocase [lindex $a 2] [lindex $b 2]]} { return 0 }
        set qa [lindex $a 1] ; set qb [lindex $b 1]
        return [expr {$qa eq "" || $qb eq "" || [string equal -nocase $qa $qb]}]
    }
    if {[lindex $a 0] eq "lit" || ([llength $a] <= 1 && [llength [lindex $a 0]] <= 1) || [llength $a] != [llength $b]} { return 0 }
    foreach x $a y $b { if {![sameExpr $x $y]} { return 0 } }
    return 1
}
proc ::mkitsql::gsMember {e list} { foreach x $list { if {[sameExpr $x $e]} { return 1 } } ; return 0 }
# replace, inside one expression, what a grouping set does not group; aggregates, window calls and subqueries are left alone
proc ::mkitsql::gsSubst {n set all} {
    variable aggs
    set tag [lindex $n 0]
    if {$tag eq "lit"} { return $n }
    if {$tag eq "insub"} { return [lreplace $n 1 1 [gsSubst [lindex $n 1] $set $all]] }           ;# x IN (SELECT ...): x is ours, the subquery is not
    if {$tag eq "quant"} { return [lreplace $n 3 3 [gsSubst [lindex $n 3] $set $all]] }
    if {$tag in {win sub exists star}} { return $n }
    if {$tag eq "func"} {
        set name [lindex $n 1]
        if {[string toupper $name] in $aggs} { return $n }
        if {[string toupper $name] eq "GROUPING"} {
            set mask 0
            foreach a [lindex $n 3] {
                if {![gsMember $a $all]} { err "GROUPING() takes grouping expressions; [lindex $a 0] is not one of the GROUP BY expressions" "" }
                set mask [expr {($mask << 1) | ([gsMember $a $set] ? 0 : 1)}]
            }
            return [list lit int $mask]
        }
    }
    if {[gsMember $n $set]} { return $n }
    if {[gsMember $n $all]} { return {lit null {}} }
    if {$tag eq "col" || ([llength $n] <= 1 && [llength [lindex $n 0]] <= 1)} { return $n }      ;# an atom (a list of one pair is not)
    set out {}
    foreach el $n { lappend out [gsSubst $el $set $all] }
    return $out
}
proc ::mkitsql::rewriteGroupingSets {items from where sets having windows distinct} {
    # item names, and GROUP BY positions / output names resolved to the expressions they stand for
    set items2 {}
    foreach it $items {
        lassign $it e alias text
        if {[lindex $e 0] eq "star"} { err "SELECT * cannot be used with ROLLUP, CUBE or GROUPING SETS" "" }
        if {$alias eq ""} { set alias [expr {[lindex $e 0] eq "col" ? [lindex $e 2] : $text}] }
        lappend items2 [list $e $alias $text]
    }
    if {[llength $sets] > 256} { err "ROLLUP / CUBE / GROUPING SETS would need [llength $sets] grouping sets (the limit is 256)" "" }
    foreach it $items2 { if {[regexp {(^|[ \{])win [A-Z_]+ [01] } [lindex $it 0]]} { err "Window functions cannot be combined with ROLLUP, CUBE or GROUPING SETS in one query: put the grouping query in a subquery and apply the window to its result" "" } }
    set vol "$from $where $having $items2"
    if {[string match "*func RANDOM*" $vol]} { err "RANDOM() cannot be used in a query with ROLLUP, CUBE or GROUPING SETS (each grouping set would see different random values)" "" }
    set sets2 {}
    foreach S $sets {
        set S2 {}
        foreach g $S {
            if {[lindex $g 0] eq "lit" && [lindex $g 1] eq "int"} {
                set k [lindex $g 2]
                if {$k < 1 || $k > [llength $items2]} { err "GROUP BY position $k is out of range" "" }
                set g [lindex $items2 [expr {$k - 1}] 0]
            } elseif {[lindex $g 0] eq "col" && [lindex $g 1] eq ""} {
                foreach it $items2 {
                    if {[string equal -nocase [lindex $it 1] [lindex $g 2]] && !([lindex $it 0 0] eq "col" && [string equal -nocase [lindex $it 0 2] [lindex $g 2]])} { set g [lindex $it 0] ; break }
                }
            }
            set S2 [gsUnion $S2 [list $g]]
        }
        lappend sets2 $S2
    }
    set all {}
    foreach S $sets2 { set all [gsUnion $all $S] }
    set q ""
    foreach S $sets2 {
        set bi {}
        foreach it $items2 { lassign $it e alias text ; lappend bi [list [gsSubst $e $S $all] $alias $text] }
        set bh [expr {$having eq "" ? "" : [gsSubst $having $S $all]}]
        if {![llength $S]} {
            # the grand total: still ONE row when the table is empty, so it must be an aggregate query
            set force [list bin >= {func COUNT 0 {{star {}}}} {lit int 0}]
            set bh [expr {$bh eq "" ? $force : [list bin and $bh $force]}]
        }
        set b [dict create type select distinct 0 items $bi from $from where $where group $S having $bh windows $windows]
        if {$q eq ""} { set q $b } else { set q [dict create type setop op union all [expr {!$distinct}] left $q right $b] }
    }
    return $q
}

# item := * | name.* | expr [[AS] alias]      ->  {expr alias text}
proc ::mkitsql::parseSelectItem {} {
    if {[isOp [peek] *]} { advance ; return [list {star {}} {} *] }
    set a [lindex [peek] 2]
    set e [parseExpr]
    set b [expr {[lindex [peek -1] 2] + [lindex [peek -1] 3]}]
    set alias ""
    if {[acceptKw AS]} {
        set t [peek]
        if {$t ne "" && [lindex $t 0] eq "string"} { advance ; set alias [lindex $t 1] } \
        else { set alias [parseName "alias"] }
    } else {
        set t [peek]
        if {$t ne "" && ([lindex $t 0] eq "qident" || ([lindex $t 0] eq "ident" && ![isReserved $t]))} {
            set alias [parseName "alias"]
        }
    }
    if {[isCollate $e]} { variable sawCollateItem ; set sawCollateItem 1 ; set e [lindex [unCollate $e] 0] }
    return [list $e $alias [srcText $a $b]]
}

# ---- FROM ------------------------------------------------------------------
# from := item { , item }       (comma = CROSS JOIN)
proc ::mkitsql::parseFrom {} {
    set l [parseJoined]
    while {[acceptOp ,]} {
        set r [parseJoined]
        set l [list join cross $l $r {} {}]
    }
    return $l
}

proc ::mkitsql::parseJoined {} {
    set l [parseTableRef]
    while 1 {
        set natural [acceptKw NATURAL]
        set type ""
        if {[acceptKw INNER]} { set type inner
        } elseif {[acceptKw LEFT]}  { acceptKw OUTER ; set type left
        } elseif {[acceptKw RIGHT]} { acceptKw OUTER ; set type right
        } elseif {[acceptKw FULL]}  { acceptKw OUTER ; set type full
        } elseif {[acceptKw CROSS]} { set type cross }
        if {$type eq ""} {
            if {![isKw [peek] JOIN]} {
                if {$natural} { err "Expected JOIN after NATURAL" [peek] }
                break
            }
            set type inner
        }
        expectKw JOIN
        set r [parseTableRef]
        set on {} ; set using {}
        if {$natural} {
            set using NATURAL
        } elseif {$type ne "cross"} {
            if {[acceptKw ON]} {
                set on [parseExpr]
            } elseif {[acceptKw USING]} {
                expectOp (
                lappend using [parseName "column name"]
                while {[acceptOp ,]} { lappend using [parseName "column name"] }
                expectOp )
            } else {
                err "$type JOIN needs an ON or USING clause" [peek]
            }
        }
        set l [list join $type $l $r $on $using]
    }
    return $l
}

# tableref := name{.name} {[n].sub} [[AS] alias]  |  (query) [AS] alias [(cols)]  |  (joined)
proc ::mkitsql::parseTableRef {} {
    set lateral 0
    if {[isKw [peek] LATERAL] && [isOp [peek 1] (]} { advance ; set lateral 1 }
    if {[isOp [peek] (]} {
        advance
        if {[startsQuery]} {
            set q [parseQuery]
            expectOp )
            acceptKw AS
            set alias [parseName "alias (a subquery in FROM needs one)"]
            set cols {}
            if {[acceptOp (]} {
                lappend cols [parseName "column name"]
                while {[acceptOp ,]} { lappend cols [parseName "column name"] }
                expectOp )
            }
            return [list derived $q $alias $cols [expr {$lateral ? "lateral" : ""}]]
        }
        if {$lateral} { err "LATERAL must be followed by a subquery" [peek] }
        set f [parseFrom]
        expectOp )
        return $f
    }
    set parts [list [parseName "table name"]]
    while {[isOp [peek] .]} { advance ; lappend parts [parseName "name"] }
    if {[llength $parts] > 2} { err "Too many name parts" [peek -1] }
    # mkstudio-style subview path:  employees[3].skills
    set subs {}
    while {[isOp [peek] \[]} {
        advance
        set idx [parseInt "row index"]
        expectOp \]
        expectOp .
        lappend subs [list $idx [parseName "subview name"]]
    }
    set alias ""
    if {[acceptKw AS]} {
        set alias [parseName "alias"]
    } else {
        set t [peek]
        if {$t ne "" && ([lindex $t 0] eq "qident" || ([lindex $t 0] eq "ident" && ![isReserved $t]))} {
            set alias [parseName "alias"]
        }
    }
    return [list table $parts $subs $alias]
}

# ============================================================================
#  Data-changing and administrative statements
# ============================================================================
# target := name{.name} {[n].sub}    ->  {parts subs}
proc ::mkitsql::parseTarget {} {
    set parts [list [parseName "table name"]]
    while {[isOp [peek] .]} { advance ; lappend parts [parseName "name"] }
    set subs {}
    while {[isOp [peek] \[]} {
        advance
        set idx [parseInt "row index"]
        expectOp \]
        expectOp .
        lappend subs [list $idx [parseName "subview name"]]
    }
    return [list $parts $subs]
}

proc ::mkitsql::parseNameList {} {
    expectOp (
    set l [list [parseName "column name"]]
    while {[acceptOp ,]} { lappend l [parseName "column name"] }
    expectOp )
    return $l
}

proc ::mkitsql::parseInsert {} {
    expectKw INSERT ; expectKw INTO
    lassign [parseTarget] parts subs
    set cols {}
    if {[isOp [peek] (] && !([isKw [peek 1] SELECT] || [isKw [peek 1] WITH] || [isKw [peek 1] VALUES])} {
        set cols [parseNameList]
    }
    if {[acceptKw DEFAULT]} {
        expectKw VALUES
        set src [dict create type defaults]
    } else {
        set src [parseQuery]
    }
    return [list insert [dict create parts $parts subs $subs cols $cols source $src]]
}

proc ::mkitsql::parseUpdate {} {
    expectKw UPDATE
    lassign [parseTarget] parts subs
    set alias ""
    if {[acceptKw AS]} { set alias [parseName alias] } else {
        set t [peek]
        if {$t ne "" && ([lindex $t 0] eq "qident" || ([lindex $t 0] eq "ident" && ![isReserved $t]))} {
            set alias [parseName alias]
        }
    }
    expectKw SET
    set sets {}
    while 1 {
        set c [parseName "column name"]
        expectOp =
        lappend sets [list $c [parseExpr]]
        if {![acceptOp ,]} break
    }
    set where {}
    if {[acceptKw WHERE]} { set where [parseExpr] }
    return [list update [dict create parts $parts subs $subs alias $alias sets $sets where $where]]
}

# MERGE INTO target [[AS] alias] USING source ON cond
#   { WHEN MATCHED [AND c] THEN UPDATE SET .. | DELETE
#   | WHEN NOT MATCHED [AND c] THEN INSERT [(cols)] VALUES (..) }
proc ::mkitsql::parseMerge {} {
    expectKw MERGE ; expectKw INTO
    lassign [parseTarget] parts subs
    set alias ""
    if {[acceptKw AS]} { set alias [parseName alias] } else {
        set t [peek]
        if {$t ne "" && ([lindex $t 0] eq "qident" || ([lindex $t 0] eq "ident" && ![isReserved $t]))} { set alias [parseName alias] }
    }
    expectKw USING
    set src [parseTableRef]
    expectKw ON
    set on [parseExpr]
    set clauses {}
    while {[acceptKw WHEN]} {
        set not [acceptKw NOT]
        expectKw MATCHED
        set cond ""
        if {[acceptKw AND]} { set cond [parseExpr] }
        expectKw THEN
        if {!$not} {
            if {[acceptKw DELETE]} {
                set act [list delete]
            } else {
                expectKw UPDATE ; expectKw SET
                set sets {}
                while 1 {
                    set c [parseName "column name"]
                    expectOp =
                    lappend sets [list $c [parseExpr]]
                    if {![acceptOp ,]} break
                }
                set act [list update $sets]
            }
        } else {
            expectKw INSERT
            set cols {}
            if {[isOp [peek] (]} { set cols [parseNameList] }
            expectKw VALUES
            expectOp (
            set vals [list [parseExpr]]
            while {[acceptOp ,]} { lappend vals [parseExpr] }
            expectOp )
            set act [list insert $cols $vals]
        }
        lappend clauses [list [expr {$not ? "notmatched" : "matched"}] $cond $act]
    }
    if {![llength $clauses]} { err "MERGE needs at least one WHEN MATCHED / WHEN NOT MATCHED clause" [peek] }
    return [list merge [dict create parts $parts subs $subs alias $alias source $src on $on clauses $clauses]]
}

proc ::mkitsql::parseDelete {} {
    expectKw DELETE ; expectKw FROM
    lassign [parseTarget] parts subs
    set alias ""
    if {[acceptKw AS]} { set alias [parseName alias] } else {
        set t [peek]
        if {$t ne "" && ([lindex $t 0] eq "qident" || ([lindex $t 0] eq "ident" && ![isReserved $t]))} {
            set alias [parseName alias]
        }
    }
    set where {}
    if {[acceptKw WHERE]} { set where [parseExpr] }
    return [list delete [dict create parts $parts subs $subs alias $alias where $where]]
}

# ---- DDL -------------------------------------------------------------------
# coldef := name type [constraints]   |   name [TABLE] ( coldef, ... )   (a Metakit subview)
# Returns {name typeOrSUBVIEW sublist}.
proc ::mkitsql::parseColDef {} {
    variable ignoreConstraints
    set name [parseName "column name"]
    set t [peek]
    if {[isKw $t TABLE] || [isOp $t (]} {
        acceptKw TABLE
        expectOp (
        set subs [list [parseColDef]]
        while {[acceptOp ,]} { lappend subs [parseColDef] }
        expectOp )
        return [list $name subview $subs]
    }
    set ty [parseTypeSpec]
    # column constraints: Metakit cannot store them
    while 1 {
        set t [peek]
        if {$t eq "" || [isOp $t ,] || [isOp $t )]} break
        set what ""
        if {[acceptKws NOT NULL]} { set what "NOT NULL"
        } elseif {[acceptKws PRIMARY KEY]} { set what "PRIMARY KEY"
        } elseif {[acceptKw UNIQUE]} { set what "UNIQUE"
        } elseif {[acceptKw DEFAULT]} { set what DEFAULT ; parseUnary
        } elseif {[acceptKw REFERENCES]} { set what REFERENCES ; parseName ; if {[isOp [peek] (]} { parseNameList }
        } elseif {[acceptKw CHECK]} { set what CHECK ; expectOp ( ; parseExpr ; expectOp )
        } elseif {[acceptKw NULL]} { set what NULL
        } elseif {[acceptKw AUTOINCREMENT]} { set what AUTOINCREMENT
        } else { err "Unexpected [describe $t] in column definition" $t }
        if {![info exists ignoreConstraints] || !$ignoreConstraints} {
            err "$what is not supported: Metakit stores no constraints, keys or defaults.  (Set ::mkitsql::ignoreConstraints 1 to parse and ignore them.)" $t
        }
    }
    return [list $name $ty {}]
}

proc ::mkitsql::parseCreate {} {
    expectKw CREATE
    set t [peek]
    if {[isKw $t UNIQUE] || [isKw $t INDEX]} {
        err "CREATE INDEX is not supported: Metakit has no secondary indexes" $t
    }
    if {[isKw $t VIEW]} { err "CREATE VIEW is not supported (in Metakit a 'view' is a table; use CREATE TABLE)" $t }
    if {[isKw $t TRIGGER] || [isKw $t SCHEMA] || [isKw $t DATABASE]} { err "CREATE [string toupper [lindex $t 1]] is not supported" $t }
    expectKw TABLE
    set ine [acceptKws IF NOT EXISTS]
    lassign [parseTarget] parts subs
    if {[acceptKw AS]} {
        set q [parseQuery]
        return [list create [dict create parts $parts ifnotexists $ine cols {} query $q]]
    }
    expectOp (
    set defs [list [parseColDefOrConstraint]]
    while {[acceptOp ,]} { lappend defs [parseColDefOrConstraint] }
    expectOp )
    set defs [lsearch -all -inline -not -exact $defs {}]
    if {![llength $defs]} { err "A table needs at least one column" [peek -1] }
    return [list create [dict create parts $parts ifnotexists $ine cols $defs]]
}
# table-level constraints (PRIMARY KEY (a), ...) are rejected like column ones
proc ::mkitsql::parseColDefOrConstraint {} {
    variable ignoreConstraints
    set t [peek]
    foreach kw {PRIMARY UNIQUE FOREIGN CHECK CONSTRAINT} {
        if {[isKw $t $kw]} {
            if {[info exists ignoreConstraints] && $ignoreConstraints} {
                # skip to the next top-level comma / closing paren
                set depth 0
                while {[peek] ne ""} {
                    set x [peek]
                    if {[isOp $x (]} { incr depth }
                    if {[isOp $x )]} { if {$depth == 0} break ; incr depth -1 }
                    if {[isOp $x ,] && $depth == 0} break
                    advance
                }
                return {}
            }
            err "$kw is not supported: Metakit stores no constraints or keys.  (Set ::mkitsql::ignoreConstraints 1 to parse and ignore them.)" $t
        }
    }
    return [parseColDef]
}

proc ::mkitsql::parseDrop {} {
    expectKw DROP
    set t [peek]
    if {[isKw $t INDEX] || [isKw $t VIEW] || [isKw $t TRIGGER] || [isKw $t SCHEMA]} {
        err "DROP [string toupper [lindex $t 1]] is not supported" $t
    }
    expectKw TABLE
    set ie [acceptKws IF EXISTS]
    lassign [parseTarget] parts subs
    return [list drop [dict create parts $parts ifexists $ie]]
}

proc ::mkitsql::parseAlter {} {
    expectKw ALTER ; expectKw TABLE
    lassign [parseTarget] parts subs
    set a {}
    if {[acceptKw ADD]} {
        acceptKw COLUMN
        set a [list add [parseColDef]]
    } elseif {[acceptKw DROP]} {
        acceptKw COLUMN
        set a [list drop [parseName "column name"]]
    } elseif {[acceptKw RENAME]} {
        if {[acceptKw TO]} {
            set a [list renametable [parseName "new table name"]]
        } else {
            acceptKw COLUMN
            set from [parseName "column name"]
            expectKw TO
            set a [list rename $from [parseName "new column name"]]
        }
    } elseif {[acceptKw ALTER]} {
        acceptKw COLUMN
        set c [parseName "column name"]
        if {[acceptKw SET]} { expectKw DATA }
        expectKw TYPE
        set a [list retype $c [parseTypeSpec]]
    } else {
        err "Expected ADD, DROP, RENAME or ALTER COLUMN" [peek]
    }
    return [list alter [dict create parts $parts subs $subs action $a]]
}

proc ::mkitsql::parseTxn {} {
    set t [advance]
    set w [string toupper [lindex $t 1]]
    switch -- $w {
        BEGIN { acceptKw TRANSACTION ; acceptKw WORK ; return [list begin {}] }
        START { expectKw TRANSACTION ; return [list begin {}] }
    }
    # COMMIT / ROLLBACK [WORK|TRANSACTION] [db]
    if {![acceptKw WORK]} { acceptKw TRANSACTION }
    set db ""
    set n [peek]
    if {$n ne "" && [lindex $n 0] in {ident qident}} { set db [parseName "database name"] }
    return [list [string tolower $w] $db]
}

# ============================================================================
#  Statement dispatch
# ============================================================================
proc ::mkitsql::parse {tokens text} {
    variable SRC ; variable toks ; variable ti ; variable nparam ; variable namedParams
    set SRC $text ; set toks $tokens ; set ti 0 ; set nparam 0 ; set namedParams {}
    set t [peek]
    set w [string toupper [lindex $t 1]]
    if {[lindex $t 0] ne "ident" && !([lindex $t 0] eq "op" && [lindex $t 1] eq "(")} {
        err "Unexpected [describe $t]" $t
    }
    switch -- $w {
        SELECT - WITH - VALUES - ( { set ast [list select [parseQuery]] }
        EXPLAIN {
            # EXPLAIN [QUERY PLAN] <query>: how the query would run (nothing is executed)
            advance
            set n [peek]
            if {$n ne "" && [string toupper [lindex $n 1]] eq "QUERY"} { advance ; set n [peek] ; if {$n ne "" && [string toupper [lindex $n 1]] eq "PLAN"} { advance } }
            set n [peek]
            if {$n eq "" || !([string toupper [lindex $n 1]] in {SELECT WITH VALUES (})} { err "EXPLAIN takes a query (SELECT, WITH or VALUES)" $n }
            set ast [list explain [parseQuery]]
        }
        INSERT   { set ast [parseInsert] }
        UPDATE   { set ast [parseUpdate] }
        DELETE   { set ast [parseDelete] }
        MERGE    { set ast [parseMerge] }
        TRUNCATE {
            advance ; acceptKw TABLE
            lassign [parseTarget] parts subs
            set ast [list delete [dict create parts $parts subs $subs alias "" where {}]]
        }
        CREATE   { set ast [parseCreate] }
        DROP     { set ast [parseDrop] }
        ALTER    { set ast [parseAlter] }
        BEGIN - START - COMMIT - ROLLBACK { set ast [parseTxn] }
        USE      { advance ; set ast [list use [parseName "database name"]] }
        SHOW {
            advance
            if {[acceptKw DATABASES]} { set ast [list showdbs {}] } \
            elseif {[acceptKw TABLES]} {
                set db ""
                if {[peek] ne ""} { set db [parseName "database name"] }
                set ast [list showtables $db]
            } else { err "Expected TABLES or DATABASES after SHOW" [peek] }
        }
        DESCRIBE - DESC {
            advance
            lassign [parseTarget] parts subs
            set ast [list describe [dict create parts $parts subs $subs]]
        }
        default {
            err "Unknown statement '[lindex $t 1]'. Try SELECT, INSERT, UPDATE, DELETE, CREATE TABLE, DROP TABLE, ALTER TABLE, BEGIN, COMMIT, ROLLBACK, SHOW TABLES, DESCRIBE or USE" $t
        }
    }
    if {[peek] ne ""} { err "Unexpected [describe [peek]]" [peek] }
    if {$nparam > 0 && [llength $namedParams]} { err "A statement cannot mix ? and :name parameters" [lindex $tokens 0] }
    # the statement records how it takes parameters, so the caller never has to guess
    lappend ast [dict create pos $nparam named $namedParams]
    return $ast
}

proc ::mkitsql::parseScript {text} {
    variable M
    set out {}
    # U+FDD0 marks NULL inside the engine and must never appear in a value; SQL text cannot contain it
    set bad [string first $M $text]
    if {$bad >= 0} {
        return -code error -errorcode [list MKQL SYNTAX $bad 1] "The character U+FDD0 is reserved (the engine uses it to mark NULL) and cannot appear in SQL text"
    }
    # the same text always parses to the same tree (it depends on nothing else): remember recent short scripts
    variable parseCache ; variable ignoreConstraints
    set cacheable [expr {[string length $text] <= 4096}]
    set ckey "[expr {[info exists ignoreConstraints] && $ignoreConstraints}] $text"          ;# the one setting that changes what a text parses to
    if {$cacheable && [info exists parseCache($ckey)]} { return $parseCache($ckey) }
    foreach st [splitStatements [tokenize $text]] {
        set a [lindex $st 0 2]
        set last [lindex $st end]
        set b [expr {[lindex $last 2] + [lindex $last 3]}]
        if {[catch {parse $st $text} ast opts]} {
            if {[string match "too many nested evaluations*" $ast]} {
                return -code error -errorcode [list MKQL SYNTAX $a [expr {$b - $a}]] "The statement is nested too deeply (too many brackets or subqueries inside each other)"
            }
            return -options $opts $ast
        }
        lappend out [list $ast $a $b [string range $text $a [expr {$b-1}]]]
    }
    if {$cacheable} {
        if {[array size parseCache] >= 256} { array unset parseCache }
        set parseCache($ckey) $out
    }
    return $out
}
