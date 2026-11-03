# mkql.tcl -- MKQL, the query language of MK Studio.
#
# Metakit is not relational: a datafile holds named *views* (tables), a view
# has typed columns, and a column can itself be a *subview* (a nested table per
# row).  MKQL is a small SQL dialect shaped around exactly that:
#
#   SELECT [DISTINCT] [TOP n] <items> [FROM <path>] [WHERE ..] [GROUP BY ..]
#          [HAVING ..] [ORDER BY ..] [LIMIT n [OFFSET m]]
#   INSERT INTO <path> [(cols)] VALUES (..)[, (..)]
#   UPDATE <path> SET col = expr [, ..] [WHERE ..]
#   DELETE FROM <path> [WHERE ..]
#   CREATE VIEW [db.]name (col [type], sub (col [type], ..), ..)
#   DROP VIEW [db.]name
#   ALTER VIEW <path> ADD col type | ADD sub (..) | DROP col | RENAME a TO b | MODIFY col type
#   DESCRIBE <path>      SHOW VIEWS [db]      SHOW DATABASES
#   COMMIT [db]          ROLLBACK [db]        USE db
#
#   <path>  :=  [db.]view  { [rowIndex].subview }       e.g.  demo.employees[3].skills
#
# All data access goes through ::store (see store.tcl).

namespace eval ::mkql {
    variable reserved {
        SELECT FROM WHERE ORDER BY GROUP HAVING LIMIT OFFSET AND OR NOT IN LIKE BETWEEN IS
        NULL AS ASC DESC DISTINCT TOP VALUES SET INTO INSERT UPDATE DELETE CREATE DROP ALTER
        VIEW TABLE ADD COLUMN RENAME TO TRUE FALSE MODIFY
    }
    variable keywords {
        SELECT FROM WHERE ORDER BY GROUP HAVING LIMIT OFFSET AND OR NOT IN LIKE BETWEEN IS
        NULL AS ASC DESC DISTINCT TOP VALUES SET INTO INSERT UPDATE DELETE CREATE DROP ALTER
        VIEW TABLE ADD COLUMN RENAME TO TRUE FALSE MODIFY DESCRIBE SHOW VIEWS DATABASES COMMIT
        ROLLBACK USE
    }
    variable typeWords {string text int integer long bigint float real double bytes blob}
    variable functions {
        UPPER LOWER LENGTH LEN TRIM SUBSTR SUBSTRING ROUND ABS FLOOR CEIL COALESCE IFNULL
        CONCAT REPLACE NOW
    }
    variable aggs {COUNT SUM AVG MIN MAX}
    # shared with the UI through the engine seam (see engine.tcl)
    namespace upvar ::engine maxRows maxRows progressHook progressHook cancel cancel
    variable SRC ""
    variable toks {}
    variable ti 0

    # comment | block comment | 'string' | "ident" | number | word | operator | stray char
    variable tokenRe {(--[^\n]*)|(/\*(?:[^*]|\*(?!/))*\*/)|('(?:[^']|'')*')|("(?:[^"]|"")*")|((?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)|([A-Za-z_][A-Za-z0-9_$]*)|(<>|!=|<=|>=|==|\|\||[-+*/%=<>(),;.\[\]!@])|(\S)}
}

set ::engine::keywords $::mkql::keywords
set ::engine::functions [concat $::mkql::aggs $::mkql::functions]
set ::engine::tokenRe $::mkql::tokenRe

# ============================================================================
#  Lexer
# ============================================================================
# Returns a list of tokens {type value pos len}; comments are dropped.
proc ::mkql::tokenize {text} {
    variable tokenRe
    set out {}
    set kinds {comment comment string qident number ident op bad}
    foreach {all g1 g2 g3 g4 g5 g6 g7 g8} [regexp -all -inline -indices $tokenRe $text] {
        lassign $all s e
        set k 0
        foreach g [list $g1 $g2 $g3 $g4 $g5 $g6 $g7 $g8] {
            if {[lindex $g 0] >= 0} break
            incr k
        }
        set kind [lindex $kinds $k]
        if {$kind eq "comment"} continue
        set raw [string range $text $s $e]
        switch -- $kind {
            string { set val [string map {'' '} [string range $raw 1 end-1]] }
            qident { set val [string map {\"\" \"} [string range $raw 1 end-1]] }
            default { set val $raw }
        }
        lappend out [list $kind $val $s [expr {$e - $s + 1}]]
    }
    return $out
}

# Split a token list into statements at ';' (empty statements are dropped).
proc ::mkql::splitStatements {tokens} {
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
proc ::mkql::err {msg {tok {}}} {
    variable toks ; variable SRC
    if {$tok eq ""} {
        set last [lindex $toks end]
        set pos [expr {$last eq "" ? 0 : [lindex $last 2] + [lindex $last 3]}]
        set len 1
    } else {
        set pos [lindex $tok 2] ; set len [lindex $tok 3]
    }
    return -code error -errorcode [list MKQL SYNTAX $pos $len] $msg
}
proc ::mkql::fail {msg} { return -code error -errorcode [list MKQL ERROR] $msg }

proc ::mkql::peek {{k 0}} { variable toks ; variable ti ; lindex $toks [expr {$ti + $k}] }
proc ::mkql::advance {} {
    variable toks ; variable ti
    set t [lindex $toks $ti] ; incr ti ; return $t
}
proc ::mkql::isKw {t kw} {
    expr {$t ne "" && [lindex $t 0] eq "ident" && [string equal -nocase [lindex $t 1] $kw]}
}
proc ::mkql::isOp {t op} { expr {$t ne "" && [lindex $t 0] eq "op" && [lindex $t 1] eq $op} }
proc ::mkql::acceptKw {kw} { variable ti ; if {[isKw [peek] $kw]} { incr ti ; return 1 } ; return 0 }
proc ::mkql::acceptOp {op} { variable ti ; if {[isOp [peek] $op]} { incr ti ; return 1 } ; return 0 }
proc ::mkql::expectKw {kw} {
    if {![acceptKw $kw]} { err "Expected $kw" [peek] }
}
proc ::mkql::expectOp {op} {
    if {![acceptOp $op]} { err "Expected '$op'" [peek] }
}
proc ::mkql::describe {t} {
    if {$t eq ""} { return "end of statement" }
    return "'[lindex $t 1]'"
}
proc ::mkql::isReserved {t} {
    variable reserved
    expr {[lindex $t 0] eq "ident" && [lsearch -exact $reserved [string toupper [lindex $t 1]]] >= 0}
}
# A name: bare word (not reserved) or "quoted".
proc ::mkql::parseName {{what name}} {
    set t [peek]
    if {$t eq ""} { err "Expected a $what" }
    switch -- [lindex $t 0] {
        qident { advance ; return [lindex $t 1] }
        ident  {
            if {[isReserved $t]} { err "Expected a $what but found keyword [describe $t] (use \"quotes\" to use it as a name)" $t }
            advance ; return [lindex $t 1]
        }
    }
    err "Expected a $what but found [describe $t]" $t
}
proc ::mkql::parseInt {what} {
    set t [peek]
    if {$t eq "" || [lindex $t 0] ne "number" || ![string is integer -strict [lindex $t 1]]} {
        err "Expected a whole number for $what" $t
    }
    advance ; return [lindex $t 1]
}
proc ::mkql::srcText {a b} {
    variable toks ; variable SRC
    set ta [lindex $toks $a] ; set tb [lindex $toks $b]
    set s [lindex $ta 2] ; set e [expr {[lindex $tb 2] + [lindex $tb 3] - 1}]
    regsub -all {\s+} [string range $SRC $s $e] { } txt
    return $txt
}

# path := [db.]view { [n].sub }
proc ::mkql::parsePath {} {
    set first [parseName "view name"]
    set db "" ; set view $first
    if {[isOp [peek] .] && [peek 1] ne "" && [lindex [peek 1] 0] in {ident qident}} {
        advance
        set db $first
        set view [parseName "view name"]
    }
    set subs {}
    while {[isOp [peek] "\["]} {
        advance
        set idx [parseInt "a row index"]
        expectOp "\]"
        expectOp .
        lappend subs [list $idx [parseName "subview name"]]
    }
    return [list $db $view $subs]
}

# ============================================================================
#  Expressions
# ============================================================================
proc ::mkql::parseExpr {} { parseOr }

proc ::mkql::parseOr {} {
    set l [parseAnd]
    while {[acceptKw OR]} { set l [list or $l [parseAnd]] }
    return $l
}
proc ::mkql::parseAnd {} {
    set l [parseNot]
    while {[acceptKw AND]} { set l [list and $l [parseNot]] }
    return $l
}
proc ::mkql::parseNot {} {
    if {[acceptKw NOT]} { return [list not [parseNot]] }
    return [parseCmp]
}
proc ::mkql::parseCmp {} {
    set l [parseAdd]
    set t [peek]
    if {$t eq ""} { return $l }
    if {[lindex $t 0] eq "op" && [lindex $t 1] in {= == <> != < <= > >=}} {
        advance
        set op [lindex $t 1]
        if {$op eq "=="} { set op = }
        if {$op eq "!="} { set op <> }
        return [list cmp $op $l [parseAdd]]
    }
    set neg 0
    if {[isKw $t NOT] && ([isKw [peek 1] LIKE] || [isKw [peek 1] IN] || [isKw [peek 1] BETWEEN])} {
        advance ; set neg 1 ; set t [peek]
    }
    if {[acceptKw LIKE]} { return [list like $l [parseAdd] $neg] }
    if {[acceptKw IN]} {
        expectOp (
        set items {}
        lappend items [parseExpr]
        while {[acceptOp ,]} { lappend items [parseExpr] }
        expectOp )
        return [list in $l $items $neg]
    }
    if {[acceptKw BETWEEN]} {
        set a [parseAdd] ; expectKw AND ; set b [parseAdd]
        return [list between $l $a $b $neg]
    }
    if {[acceptKw IS]} {
        set n [acceptKw NOT]
        expectKw NULL
        return [list isnull $l $n]
    }
    return $l
}
proc ::mkql::parseAdd {} {
    set l [parseMul]
    while {1} {
        set t [peek]
        if {$t ne "" && [lindex $t 0] eq "op" && [lindex $t 1] in {+ - ||}} {
            advance ; set l [list bin [lindex $t 1] $l [parseMul]]
        } else break
    }
    return $l
}
proc ::mkql::parseMul {} {
    set l [parseUnary]
    while {1} {
        set t [peek]
        if {$t ne "" && [lindex $t 0] eq "op" && [lindex $t 1] in {* / %}} {
            advance ; set l [list bin [lindex $t 1] $l [parseUnary]]
        } else break
    }
    return $l
}
proc ::mkql::parseUnary {} {
    if {[acceptOp -]} { return [list neg [parseUnary]] }
    if {[acceptOp +]} { return [parseUnary] }
    return [parsePrimary]
}
proc ::mkql::parsePrimary {} {
    variable aggs ; variable functions
    set t [peek]
    if {$t eq ""} { err "Expression expected" }
    switch -- [lindex $t 0] {
        number { advance ; return [list num [lindex $t 1]] }
        string { advance ; return [list str [lindex $t 1]] }
        bad {
            if {[string index [lindex $t 1] 0] eq "'"} { err "Unterminated string literal" $t }
            err "Unexpected character '[lindex $t 1]'" $t
        }
        op {
            if {[lindex $t 1] eq "("} {
                advance ; set e [parseExpr] ; expectOp ) ; return $e
            }
            err "Expression expected but found [describe $t]" $t
        }
        qident { advance ; return [list col [lindex $t 1] $t] }
        ident {
            set up [string toupper [lindex $t 1]]
            if {$up eq "NULL"}  { advance ; return [list str ""] }
            if {$up eq "TRUE"}  { advance ; return [list num 1] }
            if {$up eq "FALSE"} { advance ; return [list num 0] }
            if {[isOp [peek 1] (] && ![isReserved $t]} {
                advance ; advance
                if {$up in $aggs} {
                    if {[acceptOp *]} {
                        if {$up ne "COUNT"} { err "$up(*) is not valid; only COUNT(*)" $t }
                        expectOp )
                        return [list agg COUNT star 0]
                    }
                    set d [acceptKw DISTINCT]
                    set e [parseExpr]
                    expectOp )
                    return [list agg $up $e $d]
                }
                if {$up ni $functions} { err "Unknown function '[lindex $t 1]'" $t }
                set args {}
                if {![isOp [peek] )]} {
                    lappend args [parseExpr]
                    while {[acceptOp ,]} { lappend args [parseExpr] }
                }
                expectOp )
                return [list fn $up $args]
            }
            if {[isReserved $t]} { err "Unexpected keyword [describe $t]" $t }
            advance
            # optional qualifier  view.column
            if {[isOp [peek] .] && [lindex [peek 1] 0] in {ident qident}} {
                advance ; set c [advance]
                return [list col [lindex $c 1] $c]
            }
            return [list col [lindex $t 1] $t]
        }
    }
    err "Unexpected [describe $t]" $t
}

# ============================================================================
#  Statement parsers
# ============================================================================
proc ::mkql::parse {tokens text} {
    variable toks ; variable ti ; variable SRC
    set toks $tokens ; set ti 0 ; set SRC $text
    set t [peek]
    if {$t eq ""} { err "Empty statement" }
    if {[lindex $t 0] ne "ident"} { err "A statement must start with a keyword, not [describe $t]" $t }
    set kw [string toupper [lindex $t 1]]
    advance
    switch -- $kw {
        SELECT   { set ast [list select [parseSelect]] }
        INSERT   { set ast [parseInsert] }
        UPDATE   { set ast [parseUpdate] }
        DELETE   { set ast [parseDelete] }
        CREATE   { set ast [parseCreate] }
        DROP     { set ast [parseDrop] }
        ALTER    { set ast [parseAlter] }
        DESCRIBE - DESC { set ast [list describe [parsePath]] }
        SHOW     { set ast [parseShow] }
        COMMIT   { set ast [list commit [parseOptDb]] }
        ROLLBACK { set ast [list rollback [parseOptDb]] }
        USE      { set ast [list use [parseName "database name"]] }
        default  {
            err "Unknown statement '[lindex $t 1]'. Try SELECT, INSERT, UPDATE, DELETE, CREATE VIEW, DROP VIEW, ALTER VIEW, DESCRIBE, SHOW, COMMIT, ROLLBACK or USE" $t
        }
    }
    if {[peek] ne ""} { err "Unexpected [describe [peek]] \u2014 expected end of statement" [peek] }
    return $ast
}

proc ::mkql::parseOptDb {} {
    set t [peek]
    if {$t eq ""} { return "" }
    return [parseName "database name"]
}

proc ::mkql::parseSelect {} {
    set q [dict create type select distinct 0 top "" items {} star 0 from "" alias "" \
        where "" group {} having "" order {} limit "" offset ""]
    if {[acceptKw DISTINCT]} { dict set q distinct 1 }
    if {[acceptKw TOP]} { dict set q top [parseInt "TOP"] }
    set items {}
    while {1} {
        if {[isOp [peek] *]} {
            advance
            lappend items star
        } else {
            set a [set ::mkql::ti]
            set e [parseExpr]
            set b [expr {$::mkql::ti - 1}]
            set alias ""
            if {[acceptKw AS]} {
                set alias [parseName "column alias"]
            } elseif {[peek] ne "" && [lindex [peek] 0] in {ident qident} && ![isReserved [peek]]} {
                set alias [parseName "column alias"]
            }
            lappend items [list $e $alias [srcText $a $b]]
        }
        if {![acceptOp ,]} break
    }
    dict set q items $items
    if {[acceptKw FROM]} {
        dict set q from [parsePath]
        if {[acceptKw AS]} {
            dict set q alias [parseName "alias"]
        } elseif {[peek] ne "" && [lindex [peek] 0] in {ident qident} && ![isReserved [peek]]} {
            dict set q alias [parseName "alias"]
        }
    } elseif {[lsearch -exact $items star] >= 0} {
        err "SELECT * needs a FROM clause" [peek]
    }
    if {[acceptKw WHERE]} { dict set q where [parseExpr] }
    if {[acceptKw GROUP]} {
        expectKw BY
        set g [list [parseExpr]]
        while {[acceptOp ,]} { lappend g [parseExpr] }
        dict set q group $g
    }
    if {[acceptKw HAVING]} { dict set q having [parseExpr] }
    if {[acceptKw ORDER]} {
        expectKw BY
        set o {}
        while {1} {
            set e [parseExpr]
            set dir asc
            if {[acceptKw DESC]} { set dir desc } else { acceptKw ASC }
            lappend o [list $e $dir]
            if {![acceptOp ,]} break
        }
        dict set q order $o
    }
    if {[acceptKw LIMIT]} {
        dict set q limit [parseInt LIMIT]
        if {[acceptKw OFFSET]} { dict set q offset [parseInt OFFSET] }
    } elseif {[acceptKw OFFSET]} {
        dict set q offset [parseInt OFFSET]
    }
    return $q
}

proc ::mkql::parseInsert {} {
    expectKw INTO
    set path [parsePath]
    set cols {}
    if {[acceptOp (]} {
        lappend cols [parseName "column name"]
        while {[acceptOp ,]} { lappend cols [parseName "column name"] }
        expectOp )
    }
    expectKw VALUES
    set rows {}
    while {1} {
        expectOp (
        set vals [list [parseExpr]]
        while {[acceptOp ,]} { lappend vals [parseExpr] }
        expectOp )
        lappend rows $vals
        if {![acceptOp ,]} break
    }
    return [list insert $path $cols $rows]
}

proc ::mkql::parseUpdate {} {
    set path [parsePath]
    expectKw SET
    set sets {}
    while {1} {
        set c [parseName "column name"]
        expectOp =
        lappend sets [list $c [parseExpr]]
        if {![acceptOp ,]} break
    }
    set where ""
    if {[acceptKw WHERE]} { set where [parseExpr] }
    return [list update $path $sets $where]
}

proc ::mkql::parseDelete {} {
    expectKw FROM
    set path [parsePath]
    set where ""
    if {[acceptKw WHERE]} { set where [parseExpr] }
    return [list delete $path $where]
}

# coldefs := name [type] | name ( coldefs )
proc ::mkql::parseColDefs {} {
    set cols {}
    expectOp (
    while {1} {
        lappend cols [parseColDef]
        if {![acceptOp ,]} break
    }
    expectOp )
    return $cols
}
proc ::mkql::parseColDef {} {
    set name [parseName "column name"]
    if {[isOp [peek] (]} {
        return [list $name V [parseColDefs]]
    }
    set t [peek]
    if {$t ne "" && [lindex $t 0] eq "ident" && ![isOp [peek] ,]} {
        set letter [::store::parseType [lindex $t 1]]
        if {$letter eq ""} { err "Unknown column type '[lindex $t 1]'. Use string, int, long, float, double or bytes" $t }
        advance
        # tolerate a size like varchar(20)
        if {[isOp [peek] (] && [lindex [peek 1] 0] eq "number" && [isOp [peek 2] )]} { advance ; advance ; advance }
        return [list $name $letter {}]
    }
    return [list $name S {}]
}

proc ::mkql::parseCreate {} {
    if {![acceptKw VIEW] && ![acceptKw TABLE]} { err "Expected VIEW after CREATE" [peek] }
    set p [parsePath]
    if {[lindex $p 2] ne ""} { err "A new view name cannot contain a subview path" }
    return [list create $p [parseColDefs]]
}
proc ::mkql::parseDrop {} {
    if {![acceptKw VIEW] && ![acceptKw TABLE]} { err "Expected VIEW after DROP" [peek] }
    return [list drop [parsePath]]
}
proc ::mkql::parseAlter {} {
    if {![acceptKw VIEW] && ![acceptKw TABLE]} { err "Expected VIEW after ALTER" [peek] }
    set p [parsePath]
    if {[acceptKw ADD]} {
        acceptKw COLUMN
        return [list alter $p add [parseColDef]]
    }
    if {[acceptKw DROP]} {
        acceptKw COLUMN
        return [list alter $p drop [parseName "column name"]]
    }
    if {[acceptKw RENAME]} {
        acceptKw COLUMN
        set a [parseName "column name"]
        expectKw TO
        return [list alter $p rename [list $a [parseName "new column name"]]]
    }
    if {[acceptKw MODIFY]} {
        acceptKw COLUMN
        set d [parseColDef]
        if {[lindex $d 1] eq "V"} { err "A subview column cannot be modified" }
        return [list alter $p modify $d]
    }
    err "Expected ADD, DROP, RENAME or MODIFY" [peek]
}
proc ::mkql::parseShow {} {
    if {[acceptKw VIEWS]} { return [list showviews [parseOptDb]] }
    if {[acceptKw DATABASES]} { return [list showdbs] }
    err "Expected VIEWS or DATABASES after SHOW" [peek]
}

# Parse a whole script. Returns a list of {ast firstPos lastPosExclusive text}.
# Throws the first syntax error (with -errorcode {MKQL SYNTAX pos len}).
proc ::mkql::parseScript {text} {
    set out {}
    foreach st [splitStatements [tokenize $text]] {
        set a [lindex $st 0 2]
        set last [lindex $st end]
        set b [expr {[lindex $last 2] + [lindex $last 3]}]
        lappend out [list [parse $st $text] $a $b [string range $text $a [expr {$b-1}]]]
    }
    return $out
}

# ============================================================================
#  Values
# ============================================================================
proc ::mkql::isnum {v} {
    regexp {^\s*[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\s*$} $v
}
proc ::mkql::tonum {v} {
    set v [string trim $v]
    regsub {^([-+]?)0+(\d)} $v {\1\2} v
    return [expr {$v + 0}]
}
proc ::mkql::fmtnum {x} {
    if {[string is integer -strict $x] || [string is wideinteger -strict $x]} { return $x }
    set s [format %.12g $x]
    return $s
}
proc ::mkql::truthy {v} {
    if {$v eq ""} { return 0 }
    if {[isnum $v]} { return [expr {[tonum $v] != 0}] }
    return 1
}
# three-way comparison: numeric when both sides look numeric, else text
proc ::mkql::compare {a b} {
    if {[isnum $a] && [isnum $b]} {
        set x [tonum $a] ; set y [tonum $b]
        return [expr {$x < $y ? -1 : $x > $y ? 1 : 0}]
    }
    set c [string compare -nocase $a $b]
    if {$c == 0} { set c [string compare $a $b] }
    return $c
}
proc ::mkql::likeToRegexp {pat} {
    set re ""
    foreach ch [split $pat ""] {
        switch -- $ch {
            % { append re .* }
            _ { append re . }
            default { append re [string map {\\ \\\\ . \\. * \\* + \\+ ? \\? ( \\( ) \\) [ \\[ ] \\] \{ \\\{ \} \\\} ^ \\^ $ \\$ | \\|} $ch] }
        }
    }
    return ^$re\$
}

# ============================================================================
#  Binding: validate column names against a layout, canonicalise them
# ============================================================================
# State used while binding one statement.
namespace eval ::mkql {
    variable bcols  ;# lowername -> {canonical type}
    variable baliases {}   ;# lowername of select aliases usable in ORDER BY
    variable bused  ;# canonical name -> 1
    variable bview ""
}

proc ::mkql::bindSetup {layout viewName} {
    variable bcols ; variable bused ; variable bview ; variable baliases
    array unset bcols ; array set bcols {} ; array unset bused ; array set bused {}
    set baliases {} ; set bview $viewName
    foreach c $layout {
        set bcols([string tolower [lindex $c 0]]) [list [lindex $c 0] [lindex $c 1]]
    }
    set bcols(_rowid) [list _rowid I]
}

proc ::mkql::bindAst {ast {allowAlias 0}} {
    variable bcols ; variable bused ; variable baliases ; variable bview
    switch -- [lindex $ast 0] {
        num - str { return $ast }
        col {
            set name [lindex $ast 1] ; set lo [string tolower $name]
            if {$allowAlias && [lsearch -exact $baliases $lo] >= 0} { return [list alias $lo] }
            if {![info exists bcols($lo)]} {
                set avail {}
                foreach k [lsort [array names bcols]] { if {$k ne "_rowid"} { lappend avail [lindex $bcols($k) 0] } }
                set tok [lindex $ast 2]
                set msg "Unknown column '$name'"
                if {$bview ne ""} { append msg " in view '$bview'" }
                if {[llength $avail]} { append msg ".  Available: [join $avail {, }]" }
                if {$tok ne ""} { err $msg $tok }
                fail $msg
            }
            set canon [lindex $bcols($lo) 0]
            set bused($canon) 1
            return [list col $canon]
        }
        fn {
            set args {}
            foreach a [lindex $ast 2] { lappend args [bindAst $a $allowAlias] }
            return [list fn [lindex $ast 1] $args]
        }
        agg {
            if {[lindex $ast 2] eq "star"} { return $ast }
            return [list agg [lindex $ast 1] [bindAst [lindex $ast 2] 0] [lindex $ast 3]]
        }
        bin - cmp {
            return [list [lindex $ast 0] [lindex $ast 1] [bindAst [lindex $ast 2] $allowAlias] [bindAst [lindex $ast 3] $allowAlias]]
        }
        and - or {
            return [list [lindex $ast 0] [bindAst [lindex $ast 1] $allowAlias] [bindAst [lindex $ast 2] $allowAlias]]
        }
        not - neg { return [list [lindex $ast 0] [bindAst [lindex $ast 1] $allowAlias]] }
        like {
            return [list like [bindAst [lindex $ast 1] $allowAlias] [bindAst [lindex $ast 2] $allowAlias] [lindex $ast 3]]
        }
        in {
            set items {}
            foreach a [lindex $ast 2] { lappend items [bindAst $a $allowAlias] }
            return [list in [bindAst [lindex $ast 1] $allowAlias] $items [lindex $ast 3]]
        }
        between {
            return [list between [bindAst [lindex $ast 1] $allowAlias] [bindAst [lindex $ast 2] $allowAlias] \
                [bindAst [lindex $ast 3] $allowAlias] [lindex $ast 4]]
        }
        isnull { return [list isnull [bindAst [lindex $ast 1] $allowAlias] [lindex $ast 2]] }
    }
    error "bindAst: unknown node [lindex $ast 0]"
}

proc ::mkql::hasAgg {ast} {
    switch -- [lindex $ast 0] {
        agg { return 1 }
        num - str - col - alias { return 0 }
        fn { foreach a [lindex $ast 2] { if {[hasAgg $a]} { return 1 } } ; return 0 }
        bin - cmp - and - or { return [expr {[hasAgg [lindex $ast 2]] || [hasAgg [lindex $ast 3]]}] }
        not - neg - isnull { return [hasAgg [lindex $ast 1]] }
        like { return [expr {[hasAgg [lindex $ast 1]] || [hasAgg [lindex $ast 2]]}] }
        in {
            if {[hasAgg [lindex $ast 1]]} { return 1 }
            foreach a [lindex $ast 2] { if {[hasAgg $a]} { return 1 } }
            return 0
        }
        between { return [expr {[hasAgg [lindex $ast 1]] || [hasAgg [lindex $ast 2]] || [hasAgg [lindex $ast 3]]}] }
    }
    return 0
}

# ============================================================================
#  Evaluation
# ============================================================================
# ctx: dict column -> value.  grp: list of ctx dicts for aggregate evaluation,
# or the sentinel NOGROUP when aggregates are not allowed.
proc ::mkql::ev {ast ctx {grp NOGROUP}} {
    switch -- [lindex $ast 0] {
        num { return [lindex $ast 1] }
        str { return [lindex $ast 1] }
        col { return [dict get $ctx [lindex $ast 1]] }
        alias { return [dict get $ctx " [lindex $ast 1]"] }
        neg { return [negv [ev [lindex $ast 1] $ctx $grp]] }
        not { return [expr {![truthy [ev [lindex $ast 1] $ctx $grp]]}] }
        and {
            if {![truthy [ev [lindex $ast 1] $ctx $grp]]} { return 0 }
            return [truthy [ev [lindex $ast 2] $ctx $grp]]
        }
        or {
            if {[truthy [ev [lindex $ast 1] $ctx $grp]]} { return 1 }
            return [truthy [ev [lindex $ast 2] $ctx $grp]]
        }
        cmp { return [cmpv [lindex $ast 1] [ev [lindex $ast 2] $ctx $grp] [ev [lindex $ast 3] $ctx $grp]] }
        bin { return [binv [lindex $ast 1] [ev [lindex $ast 2] $ctx $grp] [ev [lindex $ast 3] $ctx $grp]] }
        like { return [likev [ev [lindex $ast 1] $ctx $grp] [ev [lindex $ast 2] $ctx $grp] [lindex $ast 3]] }
        in {
            set v [ev [lindex $ast 1] $ctx $grp]
            set items {}
            foreach it [lindex $ast 2] { lappend items [ev $it $ctx $grp] }
            return [inv $v $items [lindex $ast 3]]
        }
        between {
            return [betweenv [ev [lindex $ast 1] $ctx $grp] [ev [lindex $ast 2] $ctx $grp] [ev [lindex $ast 3] $ctx $grp] [lindex $ast 4]]
        }
        isnull {
            set v [ev [lindex $ast 1] $ctx $grp]
            return [expr {($v eq "") != [lindex $ast 2]}]
        }
        fn { return [evFn [lindex $ast 1] [lindex $ast 2] $ctx $grp] }
        agg {
            if {$grp eq "NOGROUP"} { fail "Aggregate functions are only allowed in SELECT, HAVING and ORDER BY" }
            return [evAgg $ast $grp]
        }
    }
    error "ev: unknown node [lindex $ast 0]"
}

# ---- value-level operators, shared by the interpreter (ev) and the compiled path (mkplan.tcl) ----
proc ::mkql::negv {v} {
    if {![isnum $v]} { fail "Cannot negate non-numeric value '$v'" }
    return [fmtnum [expr {-[tonum $v]}]]
}
proc ::mkql::cmpv {op a b} {
    set c [compare $a $b]
    switch -- $op {
        = { return [expr {$c == 0}] }
        <> { return [expr {$c != 0}] }
        < { return [expr {$c < 0}] }
        <= { return [expr {$c <= 0}] }
        > { return [expr {$c > 0}] }
        >= { return [expr {$c >= 0}] }
    }
}
proc ::mkql::binv {op a b} {
    if {$op eq "||"} { return $a$b }
    if {![isnum $a] || ![isnum $b]} {
        fail "Operator '$op' needs numbers, but got '[string range $a 0 30]' and '[string range $b 0 30]'"
    }
    set x [tonum $a] ; set y [tonum $b]
    switch -- $op {
        + { return [fmtnum [expr {$x + $y}]] }
        - { return [fmtnum [expr {$x - $y}]] }
        * { return [fmtnum [expr {$x * $y}]] }
        / {
            if {$y == 0} { fail "Divide by zero" }
            if {[string is integer -strict $x] && [string is integer -strict $y] && $x % $y == 0} {
                return [expr {$x / $y}]
            }
            return [fmtnum [expr {double($x) / $y}]]
        }
        % {
            if {$y == 0} { fail "Divide by zero" }
            return [fmtnum [expr {$x % $y}]]
        }
    }
}
proc ::mkql::likev {v p neg} {
    set m [regexp -nocase -- [likeToRegexp $p] $v]
    return [expr {$m != $neg}]
}
proc ::mkql::inv {v items neg} {
    set found 0
    foreach it $items { if {[compare $v $it] == 0} { set found 1 ; break } }
    return [expr {$found != $neg}]
}
proc ::mkql::betweenv {v lo hi neg} {
    set ok [expr {[compare $v $lo] >= 0 && [compare $v $hi] <= 0}]
    return [expr {$ok != $neg}]
}

proc ::mkql::_need {name n lo hi} {
    if {$n < $lo || $n > $hi} {
        fail "$name() takes [expr {$lo == $hi ? $lo : "$lo to $hi"}] argument(s), got $n"
    }
}
proc ::mkql::evFn {name args ctx grp} {
    set vals {}
    foreach a $args { lappend vals [ev $a $ctx $grp] }
    return [fnv $name $vals]
}
proc ::mkql::fnv {name vals} {
    set n [llength $vals]
    switch -- $name {
        UPPER  { _need $name $n 1 1 ; return [string toupper [lindex $vals 0]] }
        LOWER  { _need $name $n 1 1 ; return [string tolower [lindex $vals 0]] }
        LENGTH - LEN { _need $name $n 1 1 ; return [string length [lindex $vals 0]] }
        TRIM   { _need $name $n 1 1 ; return [string trim [lindex $vals 0]] }
        SUBSTR - SUBSTRING {
            _need $name $n 2 3
            set s [lindex $vals 0] ; set start [lindex $vals 1]
            if {![string is integer -strict $start]} { fail "$name(): start must be a whole number" }
            set from [expr {max($start, 1) - 1}]
            if {$n == 3} {
                set len [lindex $vals 2]
                if {![string is integer -strict $len]} { fail "$name(): length must be a whole number" }
                return [string range $s $from [expr {$from + $len - 1}]]
            }
            return [string range $s $from end]
        }
        ROUND {
            _need $name $n 1 2
            set v [lindex $vals 0]
            if {![isnum $v]} { fail "ROUND(): '$v' is not a number" }
            set d [expr {$n == 2 ? [lindex $vals 1] : 0}]
            if {$d == 0} { return [expr {int(round([tonum $v]))}] }
            return [fmtnum [expr {round([tonum $v] * pow(10, $d)) / pow(10, $d)}]]
        }
        ABS   { _need $name $n 1 1 ; return [fmtnum [expr {abs([numArg $name [lindex $vals 0]])}]] }
        FLOOR { _need $name $n 1 1 ; return [expr {int(floor([numArg $name [lindex $vals 0]]))}] }
        CEIL  { _need $name $n 1 1 ; return [expr {int(ceil([numArg $name [lindex $vals 0]]))}] }
        COALESCE - IFNULL {
            foreach v $vals { if {$v ne ""} { return $v } }
            return ""
        }
        CONCAT  { return [join $vals ""] }
        REPLACE { _need $name $n 3 3 ; return [string map [list [lindex $vals 1] [lindex $vals 2]] [lindex $vals 0]] }
        NOW     { return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] }
    }
    fail "Unknown function $name"
}
proc ::mkql::numArg {name v} {
    if {![isnum $v]} { fail "$name(): '$v' is not a number" }
    return [tonum $v]
}

proc ::mkql::evAgg {ast grp} {
    lassign $ast _ fn arg distinct
    if {$arg eq "star"} { return [llength $grp] }
    set vals {}
    foreach c $grp {
        set v [ev $arg $c]
        if {$v ne ""} { lappend vals $v }
    }
    return [aggVals $fn $distinct $vals]
}
# the aggregate of a list of non-empty values
proc ::mkql::aggVals {fn distinct vals} {
    if {$distinct} {
        set seen {} ; set u {}
        foreach v $vals { if {![dict exists $seen $v]} { dict set seen $v 1 ; lappend u $v } }
        set vals $u
    }
    switch -- $fn {
        COUNT { return [llength $vals] }
        SUM - AVG {
            if {![llength $vals]} { return [expr {$fn eq "SUM" ? 0 : ""}] }
            set s 0
            foreach v $vals {
                if {![isnum $v]} { fail "$fn(): '$v' is not a number" }
                set s [expr {$s + [tonum $v]}]
            }
            if {$fn eq "AVG"} { set s [expr {double($s) / [llength $vals]}] }
            return [fmtnum $s]
        }
        MIN - MAX {
            if {![llength $vals]} { return "" }
            set best [lindex $vals 0]
            foreach v [lrange $vals 1 end] {
                set c [compare $v $best]
                if {($fn eq "MIN" && $c < 0) || ($fn eq "MAX" && $c > 0)} { set best $v }
            }
            return $best
        }
    }
}

# ============================================================================
#  Path resolution
# ============================================================================
# Returns {mkpath tag layout viewLabel}
proc ::mkql::resolvePath {path defaultDb} {
    lassign $path db view subs
    set tags [::store::tags]
    if {$db ne ""} {
        if {[lsearch -exact $tags $db] < 0} {
            fail "Unknown database '$db'. Open databases: [expr {[llength $tags] ? [join $tags {, }] : {(none)}}]"
        }
        set tag $db
    } else {
        if {![llength $tags]} { fail "No database is open. Use File > Open Database\u2026 first." }
        set tag ""
        if {$defaultDb ne "" && [lsearch -exact $tags $defaultDb] >= 0 && [::store::hasView $defaultDb $view]} {
            set tag $defaultDb
        } else {
            set hits {}
            foreach t $tags { if {[::store::hasView $t $view]} { lappend hits $t } }
            if {[llength $hits] == 1} {
                set tag [lindex $hits 0]
            } elseif {[llength $hits] > 1} {
                fail "View '$view' exists in several databases ([join $hits {, }]). Qualify it, e.g. [lindex $hits 0].$view"
            }
        }
        if {$tag eq ""} {
            set avail {}
            foreach t $tags { foreach v [::store::views $t] { lappend avail $v } }
            fail "Unknown view '$view'.  Views: [expr {[llength $avail] ? [join $avail {, }] : {(none)}}]"
        }
    }
    if {![::store::hasView $tag $view]} {
        fail "Database '$tag' has no view '$view'.  Views: [join [::store::views $tag] {, }]"
    }
    set mk $tag.$view
    set layout [::store::layout $mk]
    set label $view
    foreach s $subs {
        lassign $s idx sub
        set n [::store::size $mk]
        if {$idx >= $n} { fail "Row $idx does not exist in '$label' (it has $n rows)" }
        set found ""
        foreach c $layout { if {[string equal -nocase [lindex $c 0] $sub] && [lindex $c 1] eq "V"} { set found $c } }
        if {$found eq ""} { fail "'$label' has no subview named '$sub'" }
        append mk !$idx.[lindex $found 0]
        set layout [lindex $found 2]
        append label \[$idx\].[lindex $found 0]
    }
    return [list $mk $tag $layout $label]
}

proc ::mkql::checkWritable {tag} {
    if {[::store::readonly $tag]} { fail "Database '$tag' is open read-only." }
}

proc ::mkql::usedLists {layout} {
    variable bused
    set props {} ; set subs {}
    foreach c $layout {
        lassign $c n t
        if {![info exists bused($n)]} continue
        if {$t eq "V"} { lappend subs $n } else { lappend props $n }
    }
    return [list $props $subs]
}

# ============================================================================
#  Executor
# ============================================================================
# Returns a result dict:
#   kind     rowset | message
#   rowset:  cols types rows rowids source drill truncated editable
#   message: text affected
#   use:     (optional) database name to switch to
proc ::mkql::execStatement {ast defaultDb} {
    # lazy results read the live data: keep them as they are before anything is changed
    variable cancel
    set cancel 0                                           ;# a Cancel pressed during an earlier statement is history
    if {[lindex $ast 0] in {insert update delete create drop alter rollback}} { lzFreezeAll }
    switch -- [lindex $ast 0] {
        select { return [execSelect [lindex $ast 1] $defaultDb] }
        insert { return [execInsert $ast $defaultDb] }
        update { return [execUpdate $ast $defaultDb] }
        delete { return [execDelete $ast $defaultDb] }
        create { return [execCreate $ast $defaultDb] }
        drop   { return [execDrop $ast $defaultDb] }
        alter  { return [execAlter $ast $defaultDb] }
        describe  { return [execDescribe $ast $defaultDb] }
        showviews { return [execShowViews $ast] }
        showdbs   { return [execShowDbs] }
        commit    { return [execTxn commit [lindex $ast 1] $defaultDb] }
        rollback  { return [execTxn rollback [lindex $ast 1] $defaultDb] }
        use {
            set db [lindex $ast 1]
            if {[lsearch -exact [::store::tags] $db] < 0} { fail "Unknown database '$db'" }
            return [dict create kind message text "Now using database '$db'." use $db]
        }
    }
    error "execStatement: unknown statement [lindex $ast 0]"
}

proc ::mkql::msg {text {affected -1}} {
    dict create kind message text $text affected $affected
}

proc ::mkql::execSelect {q defaultDb} {
    variable maxRows
    set from [dict get $q from]
    set items [dict get $q items]
    if {$from eq ""} {
        # SELECT <expr>, ...   (calculator mode)
        bindSetup {} ""
        set cols {} ; set row {}
        foreach it $items {
            lassign $it e alias text
            set b [bindAst $e]
            lappend cols [expr {$alias ne "" ? $alias : $text}]
            if {[hasAgg $b]} { lappend row [ev $b {} [list {}]] } else { lappend row [ev $b {}] }
        }
        return [dict create kind rowset cols $cols types [lrepeat [llength $cols] ""] rows [list $row] \
            rowids {} source "" drill {} truncated 0 editable 0]
    }
    lassign [resolvePath $from $defaultDb] mk tag layout label
    bindSetup $layout $label

    # expand * into explicit items; each entry is {boundExpr name type subName}
    set sel {}
    foreach it $items {
        if {$it eq "star"} {
            foreach c $layout {
                lassign $c n t
                lappend sel [list [bindAst [list col $n {}]] $n $t [expr {$t eq "V" ? $n : ""}]]
            }
        } else {
            lassign $it e alias text
            set b [bindAst $e]
            set type "" ; set sub ""
            if {[lindex $b 0] eq "col"} {
                set cn [lindex $b 1]
                foreach c $layout { if {[lindex $c 0] eq $cn} { set type [lindex $c 1] } }
                if {$cn eq "_rowid"} { set type I }
                if {$type eq "V"} { set sub $cn }
                set name [expr {$alias ne "" ? $alias : $cn}]
            } else {
                set name [expr {$alias ne "" ? $alias : $text}]
            }
            lappend sel [list $b $name $type $sub]
        }
    }
    # aliases available to ORDER BY
    variable baliases
    set baliases {}
    foreach s $sel { lappend baliases [string tolower [lindex $s 1]] }

    set where ""
    if {[dict get $q where] ne ""} {
        set where [bindAst [dict get $q where]]
        if {[hasAgg $where]} { fail "Aggregate functions are not allowed in WHERE; use HAVING" }
    }
    set groupBy {}
    foreach g [dict get $q group] { lappend groupBy [bindAst $g] }
    set having ""
    if {[dict get $q having] ne ""} { set having [bindAst [dict get $q having]] }
    set order {}
    foreach o [dict get $q order] {
        set e [lindex $o 0]
        if {[lindex $e 0] eq "num" && [string is integer -strict [lindex $e 1]]} {
            set k [lindex $e 1]
            if {$k < 1 || $k > [llength $sel]} { fail "ORDER BY position $k is out of range (1..[llength $sel])" }
            lappend order [list [list outcol [expr {$k-1}]] [lindex $o 1]]
        } else {
            lappend order [list [bindAst $e 1] [lindex $o 1]]
        }
    }

    set isAgg [expr {[llength $groupBy] > 0 || $having ne ""}]
    foreach s $sel { if {[hasAgg [lindex $s 0]]} { set isAgg 1 } }
    foreach o $order { if {[hasAgg [lindex $o 0]]} { set isAgg 1 } }

    lassign [usedLists $layout] props subs
    set limit [dict get $q limit] ; set offset [dict get $q offset]
    if {$offset eq ""} { set offset 0 }
    set top [dict get $q top]
    if {$limit eq "" && $top ne ""} { set limit $top }
    set distinct [dict get $q distinct]
    set needAll [expr {$isAgg || [llength $order] || $distinct}]
    set stopAt 0
    set truncated 0
    if {!$needAll} {
        set stopAt [expr {$limit ne "" ? $offset + $limit : $maxRows + 1}]
    }

    # fast path (mkplan.tcl): pushdown, compiled expressions, streaming aggregates
    set baseW [setupCols $layout $props $subs]
    lassign [planWhere $mk $layout $where] cand skip

    # big plain results stay as a list of row ids and are projected on demand (lazy provider)
    # (a LIMIT below the lazy threshold gives a small result: early stop / top-k are better for that)
    variable lazyMin
    if {!$isAgg && !$distinct && ($limit eq "" || $limit >= $lazyMin) && [lazyEligible $sel $order $layout]} {
        set lazyStop [expr {[llength $order] || $limit eq "" ? 0 : $offset + $limit}]
        set ids [lazyIds $mk $layout $sel $where $order $cand $skip $lazyStop]
        if {$offset > 0} { set ids [lrange $ids $offset end] }
        if {$limit ne ""} { set ids [lrange $ids 0 [expr {$limit - 1}]] }
        if {[llength $ids] >= $lazyMin} {
            set colNames {} ; set colTypes {} ; set drill {} ; set ci 0
            foreach s $sel {
                lappend colNames [lindex $s 1] ; lappend colTypes [lindex $s 2]
                if {[lindex $s 3] ne ""} { dict set drill $ci [lindex $s 3] }
                incr ci
            }
            # derived columns: right-align when the first and last thousand rows are all numbers
            set src [lazyResult $mk $layout $props $subs $baseW $sel $ids $colNames $colTypes $drill]
            set sample [concat [{*}$src rows 0 1000] [{*}$src rows [expr {max(0, [llength $ids] - 1000)}] 1000]]
            set ci 0
            foreach t $colTypes {
                if {$t eq ""} {
                    set allnum 1 ; set any 0
                    foreach r $sample { set v [lindex $r $ci] ; if {$v eq ""} continue ; set any 1 ; if {![isnum $v]} { set allnum 0 ; break } }
                    if {$any && $allnum} { lset colTypes $ci N }
                }
                incr ci
            }
            return [dict create kind rowset cols $colNames types $colTypes rows {} rowids {} source $mk drill $drill \
                truncated 0 editable 1 provider $src]
        }
        # small result: the ids are final (ordered, sliced) - project them the ordinary way
        set cand $ids ; set skip 1 ; set order {} ; set offset 0 ; set limit "" ; set stopAt 0 ; set needAll 1
        set baseW [setupCols $layout $props $subs]
    }
    genBegin
    set err [catch {
        set recs [runSelect [dict create mk $mk layout $layout props $props subs $subs baseW $baseW sel $sel \
            where $where groupBy $groupBy having $having order $order isAgg $isAgg distinct $distinct \
            limit $limit offset $offset stopAt $stopAt cand $cand skip $skip]]
    } msg opts]
    genEnd
    if {$err} { return -options $opts $msg }

    if {$distinct} {
        set seen [dict create] ; set recs2 {}
        foreach r $recs {
            set k [lindex $r 0]
            if {![dict exists $seen $k]} { dict set seen $k 1 ; lappend recs2 $r }
        }
        set recs $recs2
    }

    set total [llength $recs]
    if {$offset > 0} { set recs [lrange $recs $offset end] }
    if {$limit ne ""} { set recs [lrange $recs 0 [expr {$limit - 1}]] }
    if {$limit eq "" && !$needAll && [llength $recs] > $maxRows} {
        set recs [lrange $recs 0 [expr {$maxRows - 1}]]
        set truncated 1
    }

    set rows {} ; set rowids {} ; set drill {}
    set colNames {} ; set colTypes {}
    set ci 0
    foreach s $sel {
        lappend colNames [lindex $s 1]
        set t [lindex $s 2]
        lappend colTypes $t
        if {[lindex $s 3] ne ""} { dict set drill $ci [lindex $s 3] }
        incr ci
    }
    set plain [expr {!$isAgg && !$distinct}]
    foreach r $recs {
        set out [lindex $r 0]
        if {[dict size $drill]} {
            dict for {i sub} $drill {
                set n [lindex $out $i]
                lset out $i "\u25B8 $n row[expr {$n == 1 ? {} : {s}}]"
            }
        }
        lappend rows $out
        if {$plain} { lappend rowids [lindex $r 2] }
    }
    # tag derived numeric columns so the grid can right-align them
    set ci 0
    foreach t $colTypes {
        if {$t eq ""} {
            set allnum 1 ; set any 0
            foreach r $rows { set v [lindex $r $ci] ; if {$v eq ""} continue ; set any 1 ; if {![isnum $v]} { set allnum 0 ; break } }
            if {$any && $allnum} { lset colTypes $ci N }
        }
        incr ci
    }
    return [dict create kind rowset cols $colNames types $colTypes rows $rows rowids $rowids \
        source [expr {$plain ? $mk : ""}] drill $drill truncated $truncated editable $plain]
}

# Reorder `perm` (a list of record indices) by keys `kc` (indexed by record
# index).  Stable, so earlier sort passes act as tie-breakers.
proc ::mkql::sortPerm {perm kc desc} {
    set allnum 1 ; set alltext 1
    foreach v $kc {
        if {[isnum $v]} { set alltext 0 } else { set allnum 0 }
        if {!$allnum && !$alltext} break
    }
    set dir [expr {$desc ? "-decreasing" : "-increasing"}]
    set keys {}
    if {$allnum} {
        foreach i $perm { lappend keys [tonum [lindex $kc $i]] }
        set idx [lsort -real -indices $dir $keys]
    } elseif {$alltext} {
        foreach i $perm { lappend keys [lindex $kc $i] }
        set idx [lsort -ascii -nocase -indices $dir $keys]
    } else {
        # mixed numbers and text in one column: SQL-ish rules via the comparator
        set pairs {}
        foreach i $perm { lappend pairs [list $i [lindex $kc $i]] }
        set sorted [lsort -command ::mkql::cmpPair $pairs]
        if {$desc} { set sorted [lreverse $sorted] }
        set out {}
        foreach p $sorted { lappend out [lindex $p 0] }
        return $out
    }
    set out {}
    foreach j $idx { lappend out [lindex $perm $j] }
    return $out
}
proc ::mkql::cmpPair {a b} { compare [lindex $a 1] [lindex $b 1] }

proc ::mkql::cmpKeyed {a b} {
    variable sortDirs
    set ka [lindex $a 1] ; set kb [lindex $b 1]
    set i 0
    foreach d $sortDirs {
        set c [compare [lindex $ka $i] [lindex $kb $i]]
        if {$c != 0} { return [expr {$d eq "desc" ? -$c : $c}] }
        incr i
    }
    return 0
}

# Called inside long write loops: keeps the UI alive and honours Cancel.
proc ::mkql::tick {n what} {
    variable progressHook ; variable cancel
    if {$n % 500 != 0} return
    if {$progressHook ne ""} { uplevel #0 $progressHook }
    if {$cancel} {
        fail "Cancelled after $n $what. Changes made so far are still pending - Roll Back to undo them."
    }
}

# ---- value coercion for writes ---------------------------------------------
proc ::mkql::coerce {col type v} {
    switch -- $type {
        I - L {
            if {[isnum $v]} {
                set x [tonum $v]
                if {[string is wideinteger -strict $x]} { return $x }
                if {$x == int($x)} { return [expr {int($x)}] }
            }
            fail "Column '$col' is [::store::typeName $type] \u2014 '[string range $v 0 40]' is not a whole number"
        }
        F - D {
            if {[isnum $v]} { return [tonum $v] }
            fail "Column '$col' is [::store::typeName $type] \u2014 '[string range $v 0 40]' is not a number"
        }
    }
    return $v
}
proc ::mkql::layoutLookup {layout name} {
    foreach c $layout {
        if {[string equal -nocase [lindex $c 0] $name]} { return $c }
    }
    return ""
}

proc ::mkql::execInsert {st defaultDb} {
    variable cancel
    lassign $st _ path cols rows
    lassign [resolvePath $path $defaultDb] mk tag layout label
    checkWritable $tag
    bindSetup {} ""
    if {![llength $cols]} {
        foreach c $layout { if {[lindex $c 1] ne "V"} { lappend cols [lindex $c 0] } }
    }
    set cinfo {}
    foreach c $cols {
        set d [layoutLookup $layout $c]
        if {$d eq ""} { fail "Unknown column '$c' in view '$label'" }
        if {[lindex $d 1] eq "V"} { fail "'$c' is a subview; insert into it with  INSERT INTO $label\[row\].$c ..." }
        lappend cinfo $d
    }
    set names {}
    foreach d $cinfo { lappend names [lindex $d 0] }
    set n 0
    set prepared {}
    foreach r $rows {
        if {[llength $r] != [llength $cols]} {
            fail "Row [expr {$n+1}] has [llength $r] value(s) but [llength $cols] column(s) were listed"
        }
        set vals {} ; set i 0
        foreach e $r {
            set d [lindex $cinfo $i]
            lappend vals [coerce [lindex $d 0] [lindex $d 1] [ev [bindAst $e] {}]]
            incr i
        }
        lappend prepared $vals
        incr n
    }
    # every value is converted above, so nothing is changed if one is bad; the appends below are not
    # cancellable (a statement either happens completely or not at all) but keep the window alive
    set k 0
    foreach vals $prepared { ::store::appendRow $mk $names $vals ; pump [incr k] }
    return [msg "($n row[expr {$n == 1 ? {} : {s}}] inserted into $label)" $n]
}

# keeps the window alive in a write loop; deliberately does NOT honour Cancel - a statement is all or nothing
proc ::mkql::pump {n} {
    variable progressHook
    if {$n % 500 == 0 && $progressHook ne ""} { uplevel #0 $progressHook }
}
proc ::mkql::tickWrite {n} { pump $n }
# the same for long READS inside the store (column fetches): here Cancel is honoured
proc ::mkql::pumpCancel {} {
    variable progressHook ; variable cancel
    # (only while a query is running - the hook is set for that - so a stale Cancel can't stop a column sort)
    if {$progressHook ne ""} {
        uplevel #0 $progressHook
        if {$cancel} { fail "Query cancelled" }
    }
}
set ::store::pump ::mkql::pumpCancel

proc ::mkql::execUpdate {st defaultDb} {
    variable cancel
    lassign $st _ path sets where
    lassign [resolvePath $path $defaultDb] mk tag layout label
    checkWritable $tag
    bindSetup $layout $label
    set bsets {}
    foreach s $sets {
        lassign $s c e
        set d [layoutLookup $layout $c]
        if {$d eq ""} { fail "Unknown column '$c' in view '$label'" }
        if {[lindex $d 1] eq "V"} { fail "'$c' is a subview and cannot be assigned" }
        lappend bsets [list [lindex $d 0] [lindex $d 1] [bindAst $e]]
    }
    set bwhere ""
    if {$where ne ""} { set bwhere [bindAst $where] }
    lassign [usedLists $layout] props subs
    setupCols $layout $props $subs
    set rows [matchRows $mk $layout $props $subs $bwhere 0]
    set n 0 ; set cancel 0
    set sp ""
    genBegin
    set err [catch {
        if {[llength $bsets]} {
            set asts {} ; foreach s $bsets { lappend asts [lindex $s 2] }
            set sp [compileList $asts setvals]
        }
        set changes [dict create]
        foreach r $rows {
            tick $n "evaluated rows"
            set i [lindex $r end]
            # evaluate everything first, then write, so SET a=b, b=a behaves
            set kv {}
            foreach s $bsets v [$sp $r] {
                lassign $s col type e
                set v [coerce $col $type $v]
                # skip writes that change nothing: in Metakit a string write shifts the rest of the column
                if {[::store::cell $mk $i $col] ne $v} { lappend kv $col $v }
            }
            if {[llength $kv]} { dict set changes $i $kv }
            incr n
        }
        # one call: in place for a few rows, a rebuild of the view's tail for thousands (store.tcl)
        ::store::updateRows $mk $changes ::mkql::tickWrite
    } msg opts]
    genEnd
    if {$err} { return -options $opts $msg }
    return [msg "($n row[expr {$n == 1 ? {} : {s}}] updated in $label)" $n]
}

proc ::mkql::execDelete {st defaultDb} {
    lassign $st _ path where
    lassign [resolvePath $path $defaultDb] mk tag layout label
    checkWritable $tag
    bindSetup $layout $label
    set bwhere ""
    if {$where ne ""} { set bwhere [bindAst $where] }
    set idx [matchIds $mk $layout $bwhere]
    if {[llength $idx]} { ::store::deleteRows $mk $idx }
    set n [llength $idx]
    return [msg "($n row[expr {$n == 1 ? {} : {s}}] deleted from $label)" $n]
}

proc ::mkql::dupCheck {cols} {
    set seen {}
    foreach c $cols {
        set n [string tolower [lindex $c 0]]
        if {[dict exists $seen $n]} { fail "Column '[lindex $c 0]' is defined twice" }
        dict set seen $n 1
        if {[lindex $c 1] eq "V"} { dupCheck [lindex $c 2] }
    }
}

proc ::mkql::targetDb {path defaultDb} {
    set tags [::store::tags]
    set db [lindex $path 0]
    if {$db eq ""} { set db $defaultDb }
    if {$db eq "" && [llength $tags] == 1} { set db [lindex $tags 0] }
    if {$db eq "" || [lsearch -exact $tags $db] < 0} {
        if {![llength $tags]} { fail "No database is open." }
        fail "Choose a database first: qualify the name (db.view) or select one in the toolbar."
    }
    return $db
}

proc ::mkql::execCreate {st defaultDb} {
    lassign $st _ path cols
    set tag [targetDb $path $defaultDb]
    checkWritable $tag
    set name [lindex $path 1]
    dupCheck $cols
    ::store::createView $tag $name $cols
    return [msg "View '$name' created in '$tag'."]
}

proc ::mkql::execDrop {st defaultDb} {
    lassign $st _ path
    if {[lindex $path 2] ne ""} { fail "Only top-level views can be dropped" }
    lassign [resolvePath $path $defaultDb] mk tag layout label
    checkWritable $tag
    set rows [::store::size $mk]
    ::store::dropView $tag [lindex $path 1]
    return [msg "View '[lindex $path 1]' dropped from '$tag' ($rows rows deleted)."]
}

proc ::mkql::execAlter {st defaultDb} {
    lassign $st _ path action arg
    lassign [resolvePath $path $defaultDb] mk tag layout label
    checkWritable $tag
    switch -- $action {
        add {
            if {[layoutLookup $layout [lindex $arg 0]] ne ""} { fail "Column '[lindex $arg 0]' already exists in '$label'" }
            dupCheck [list $arg]
            lappend layout $arg
            ::store::restructure $mk $layout
            return [msg "Column '[lindex $arg 0]' added to '$label'."]
        }
        drop {
            set d [layoutLookup $layout $arg]
            if {$d eq ""} { fail "No column '$arg' in '$label'" }
            if {[llength $layout] == 1} { fail "A view needs at least one column" }
            set new {}
            foreach c $layout { if {$c ne $d} { lappend new $c } }
            ::store::restructure $mk $new
            return [msg "Column '[lindex $d 0]' dropped from '$label'."]
        }
        rename {
            lassign $arg a b
            set d [layoutLookup $layout $a]
            if {$d eq ""} { fail "No column '$a' in '$label'" }
            if {[lindex $d 1] eq "V"} { fail "Renaming a subview is not supported; create a new one and copy its rows" }
            ::store::rebuildColumn $mk [lindex $d 0] $b [lindex $d 1]
            return [msg "Column '[lindex $d 0]' renamed to '$b'."]
        }
        modify {
            lassign $arg a t
            set d [layoutLookup $layout $a]
            if {$d eq ""} { fail "No column '$a' in '$label'" }
            if {[lindex $d 1] eq "V"} { fail "'$a' is a subview and has no type to change" }
            ::store::rebuildColumn $mk [lindex $d 0] [lindex $d 0] $t
            return [msg "Column '[lindex $d 0]' is now [::store::typeName $t]."]
        }
    }
}

proc ::mkql::flatten {layout prefix depth} {
    set out {}
    foreach c $layout {
        lassign $c n t sub
        lappend out [list $prefix$n $t $depth]
        if {$t eq "V"} { set out [concat $out [flatten $sub "$prefix$n." [expr {$depth+1}]]] }
    }
    return $out
}
proc ::mkql::execDescribe {st defaultDb} {
    lassign [resolvePath [lindex $st 1] $defaultDb] mk tag layout label
    set rows {} ; set i 0
    foreach f [flatten $layout "" 0] {
        lassign $f n t depth
        lappend rows [list [incr i] $n [::store::typeName $t] [expr {$t eq "V" ? "subview" : "column"}] $t]
    }
    return [dict create kind rowset cols {# Name Type Kind Code} types {I "" "" "" ""} rows $rows \
        rowids {} source "" drill {} truncated 0 editable 0]
}
proc ::mkql::execShowViews {st} {
    set db [lindex $st 1]
    set tags [::store::tags]
    if {$db ne "" && [lsearch -exact $tags $db] < 0} { fail "Unknown database '$db'" }
    if {$db ne ""} { set tags [list $db] }
    set rows {}
    foreach t $tags {
        foreach v [::store::views $t] {
            set l [::store::layout $t.$v]
            lappend rows [list $t $v [::store::size $t.$v] [llength $l]]
        }
    }
    return [dict create kind rowset cols {Database View Rows Columns} types {"" "" I I} rows $rows \
        rowids {} source "" drill {} truncated 0 editable 0]
}
proc ::mkql::execShowDbs {} {
    set rows {}
    foreach t [::store::tags] {
        lappend rows [list $t [::store::path $t] [::store::fileSize $t] \
            [expr {[::store::readonly $t] ? "read-only" : "read-write"}] [::store::dirty $t]]
    }
    return [dict create kind rowset cols {Database Path Bytes Mode Pending} types {"" "" L "" I} rows $rows \
        rowids {} source "" drill {} truncated 0 editable 0]
}
proc ::mkql::execTxn {what db defaultDb} {
    if {$db eq ""} { set db $defaultDb }
    if {$db eq "" && [llength [::store::tags]] == 1} { set db [lindex [::store::tags] 0] }
    if {$db eq "" || ![::store::exists $db]} { fail "Specify a database:  [string toupper $what] <database>" }
    if {$what eq "commit"} {
        if {[::store::readonly $db]} { fail "Database '$db' is open read-only." }
        ::store::commit $db
        return [msg "Changes to '$db' committed to disk."]
    }
    set n [::store::dirty $db]
    ::store::rollback $db
    return [msg "Rolled back $n pending change(s) in '$db'."]
}

# Convenience for tests and scripting: run one statement text, return the result.
proc ::mkql::run {text {defaultDb ""}} {
    set parsed [parseScript $text]
    set last ""
    foreach p $parsed { set last [execStatement [lindex $p 0] $defaultDb] }
    return $last
}

# the fast execution path (pushdown, compiled expressions, streaming aggregates)
source [file join [file dirname [info script]] mkplan.tcl]
