# expr.tcl -- expression compiler and runtime for mkit-sql.
#
# A bound expression tree is compiled into the text of a small Tcl proc, so
# evaluating it per row costs a handful of proc calls instead of a recursive
# interpreter walk.  Values are plain Tcl strings; SQL NULL is the sentinel
# string  "\uFDD0NULL"  (see ::mkitsql::N).  Metakit itself has no NULL: NULLs
# only arise during evaluation (LEFT JOIN, SELECT NULL, empty aggregates ...)
# and are turned into the column default (0 / "") when written back.
#
# Static types:  int real text blob bool null
#   - comparison and arithmetic are chosen from the static types, so
#     '2' < '10' is a *text* comparison and 7 / 2 is integer division (= 3),
#     exactly as standard SQL says.
#
# Bound expression nodes (produced by the binder in query.tcl):
#   {lit T V}  {ref LEVEL SRC NAME TYPE}  {slot POS TYPE}  {un OP e}  {bin OP a b}
#   {isnull e neg} {istf e val neg} {isdist a b neg} {between e lo hi neg}
#   {like e pat esc neg ci} {in e list neg} {insub e planId neg} {exists planId}
#   {sub planId type} {case operand whens else} {cast e type} {func NAME distinct args}

namespace eval ::mkitsql {
    # NULL is the sentinel string  M + "NULL"  where M is U+FDD0, a Unicode *noncharacter* (reserved
    # for internal use, never assigned).  The engine keeps one invariant: NO VALUE EVER CONTAINS M.
    #   - stored text is cleaned when it is read (M -> U+FFFD, see cleanText)
    #   - SQL text and parameters containing M are rejected
    #   - CHR() refuses to create it, and blobs are bytes (0-255), so they cannot hold it
    #   - every string operation only rearranges characters it was given
    # so no expression can ever build the sentinel from data: NULL cannot be forged.
    variable maxString 67108864      ;# characters: the longest string a function or || may build
    variable M "\uFDD0"
    variable N "\uFDD0NULL"
    variable R [format %c 65533]
    variable IV "\uFDD0ivl:"      ;# prefix of an INTERVAL value (see datetime.tcl)
    variable sanitized 0
    variable cxCount 0
    variable likeCache
    array set likeCache {}
    variable planCorr
    array set planCorr {}
    variable planMemo
    array set planMemo {}
    variable volatileSeen 0        ;# set while compiling: the code being compiled calls RANDOM()
}
namespace eval ::mkitsql::rt {}

# ---- a bug in the list code of Tcl 8.5 and 8.6.3 (fixed later) ------------------------------------------------------------
# When the string form of a list is made, a list whose FIRST element starts with '#' and contains two or more of the
# characters ] and " comes out damaged: extra blanks or stray bytes after the element, sometimes a different element
# count.  Rows (lists of cells) whose first cell is such text would be corrupted whenever they are written to a temporary
# file, used as a dictionary key (DISTINCT, GROUP BY, joins, UNION) or handed to a caller that prints them.  The
# engine finds out at load time whether the Tcl it runs on has the bug; if so every list the engine builds that way
# goes through `rt::sk`, which writes such a list with its first element in the (correct) non-first-element form.
# lrepeat with a count of 0 is an error in Tcl 8.5
proc ::mkitsql::rep {n v} { if {$n <= 0} { return {} } ; return [lrepeat $n $v] }

proc ::mkitsql::tclListBug {} {
    foreach s [list "#\]\]x" "#\"\"x" "#\]\"x" "#\"\]\]x\"y"] {
        set l [list $s]
        set str [string range $l 0 end]
        if {[catch {expr {[llength $str] != 1 || [lindex $str 0] ne $s || [string length $str] > [string length $s] + 3 + 1}} bad] || $bad} { return 1 }
    }
    return 0
}
set ::mkitsql::listBug [::mkitsql::tclListBug]
# (tests can force the workaround on or off:  MKIT_LISTBUG=0|1)
if {[info exists ::env(MKIT_LISTBUG)] && $::env(MKIT_LISTBUG) in {0 1}} { set ::mkitsql::listBug $::env(MKIT_LISTBUG) }
if {$::mkitsql::listBug} {
    # Can this element be written in braces?  (balanced braces, no backslash-newline, no backslash at the end)
    proc ::mkitsql::rt::braceable {e} {
        set n [string length $e] ; set depth 0
        for {set i 0} {$i < $n} {incr i} {
            switch -exact -- [string index $e $i] {
                "\\" { if {$i + 1 >= $n || [string index $e [expr {$i + 1}]] eq "\n"} { return 0 } ; incr i }
                "\{" { incr depth }
                "\}" { if {[incr depth -1] < 0} { return 0 } }
            }
        }
        return [expr {$depth == 0}]
    }
    # The string form of a list whose first element starts with '#', written the way a healthy Tcl writes it (first element in
    # braces when that is possible, else with backslashes), but built here so that the damaged routine is not used.  If this
    # construction ever does not read back as the same list, the always-valid non-first-element form is used instead.
    proc ::mkitsql::rt::sk {l} {
        set e [lindex $l 0]
        if {[string index $e 0] ne "#"} { return $l }
        set head [string range [list x $e] 2 end]
        set rest [string range [list x {*}[lrange $l 1 end]] 1 end]
        if {[string index $head 0] eq "\{"} {
            set cand $head$rest
        } elseif {[::mkitsql::rt::braceable $e]} {
            set cand "\{$e\}$rest"
        } else {
            set cand "\\$head$rest"
        }
        if {[catch {expr {[llength $cand] == [llength $l] && [lindex $cand 0] eq $e}} ok] || !$ok} {
            return [string range [list x {*}$l] 2 end]
        }
        return $cand
    }
    # the text of a list for searching / measuring WITHOUT turning the list itself into a string (which would throw away its
    # list form and re-read the damaged string form)
    proc ::mkitsql::rt::flat {l} { return [join $l] }
} else {
    proc ::mkitsql::rt::sk {l} { return $l }
    proc ::mkitsql::rt::flat {l} { return $l }
}
namespace eval ::mkitsql::cx {}

# ============================================================================
#  Runtime helpers  (called from compiled code)
# ============================================================================
# Define a runtime proc whose listed arguments are NULL-strict: if any is NULL
# the result is NULL without running the body.
proc ::mkitsql::defstrict {name arglist body} {
    set chk {}
    foreach a $arglist { lappend chk "\$[lindex $a 0] eq \"\\uFDD0NULL\"" }
    proc ::mkitsql::rt::$name $arglist "if \{[join $chk { || }]\} \{return \"\\uFDD0NULL\"\}\n$body"
}

proc ::mkitsql::rt::isnull  {v} { expr {$v eq "\uFDD0NULL"} }
proc ::mkitsql::rt::notnull {v} { expr {$v ne "\uFDD0NULL"} }
proc ::mkitsql::rt::not {v} { if {$v eq "\uFDD0NULL"} { return $v } ; expr {!$v} }
proc ::mkitsql::rt::and2 {a b} {
    # a is known not to be 0
    if {$b eq "0"} { return 0 }
    if {$a eq "\uFDD0NULL" || $b eq "\uFDD0NULL"} { return "\uFDD0NULL" }
    return 1
}
proc ::mkitsql::rt::or2 {a b} {
    # a is known not to be 1
    if {$b eq "1"} { return 1 }
    if {$a eq "\uFDD0NULL" || $b eq "\uFDD0NULL"} { return "\uFDD0NULL" }
    return 0
}
# numeric value in boolean context -> 1 / 0 / NULL
proc ::mkitsql::rt::tobool {v} {
    if {$v eq "\uFDD0NULL"} { return $v }
    expr {$v != 0}
}
proc ::mkitsql::rt::istf {v want neg} {
    if {$v eq "\uFDD0NULL"} { return $neg }
    expr {(($v != 0) == $want) ^ $neg}
}
proc ::mkitsql::rt::isdist {a b neg} {
    set an [expr {$a eq "\uFDD0NULL"}] ; set bn [expr {$b eq "\uFDD0NULL"}]
    if {$an || $bn} { return [expr {($an != $bn) ^ $neg}] }
    expr {($a ne $b) ^ $neg}
}

# ---- numbers ---------------------------------------------------------------
# Convert text to a number (used when a text value meets an arithmetic operator).
proc ::mkitsql::rt::num {v} {
    if {$v eq "\uFDD0NULL"} { return $v }
    set s [string trim $v]
    if {![regexp {^[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$} $s]} {
        if {[::mkitsql::isIv $v]} { ::mkitsql::fail "An interval cannot be used as a number" }
        ::mkitsql::fail "Invalid number: '[string range $v 0 40]'"
    }
    regsub {^([-+]?)0+(?=\d)} $s {\1} s
    if {[regexp {^[-+]?\d+$} $s]} { return [expr {$s + 0}] }
    return [expr {double($s)}]
}
# SQL has no negative zero: -0.0 = 0.0, so they must group, sort, join and de-duplicate as one value.  The
# floating-point operators that can produce -0.0 turn it into 0.0 (the check is one string comparison).
::mkitsql::defstrict neg {a} { set r [expr {-$a}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r }
::mkitsql::defstrict add {a b} { set r [expr {$a + $b}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r }
::mkitsql::defstrict sub {a b} { set r [expr {$a - $b}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r }
::mkitsql::defstrict mul {a b} { set r [expr {$a * $b}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r }
::mkitsql::defstrict idiv {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    set q [expr {abs($a) / abs($b)}]
    if {($a < 0) != ($b < 0)} { set q [expr {-$q}] }
    return $q
}
::mkitsql::defstrict rdiv {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    set r [expr {double($a) / $b}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r
}
::mkitsql::defstrict imod {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    set r [expr {abs($a) % abs($b)}]
    if {$a < 0} { set r [expr {-$r}] }
    return $r
}
::mkitsql::defstrict rmod {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    set r [expr {fmod($a, $b)}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r
}
::mkitsql::defstrict cat {a b} {
    if {[string length $a] + [string length $b] > $::mkitsql::maxString} { ::mkitsql::fail "The result would be longer than $::mkitsql::maxString characters (::mkitsql::maxString)" }
    return $a$b
}

# ---- comparison ------------------------------------------------------------
# n = numeric, s = text/blob, m = mixed (text vs number: compare as numbers when
# the text is numeric, otherwise as text).
foreach {nm op} {eq == ne != lt < le <= gt > ge >=} {
    ::mkitsql::defstrict ${nm}_n {a b} "expr {\$a $op \$b}"
    ::mkitsql::defstrict ${nm}_s {a b} "expr {\[string compare \$a \$b\] $op 0}"
    ::mkitsql::defstrict ${nm}_m {a b} "
        if {\[::mkitsql::rt::looksnum \$a\] && \[::mkitsql::rt::looksnum \$b\]} {
            return \[expr {\[::mkitsql::rt::num \$a\] $op \[::mkitsql::rt::num \$b\]}\]
        }
        expr {\[string compare \$a \$b\] $op 0}"
}
proc ::mkitsql::rt::looksnum {v} {
    regexp {^\s*[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?\s*$} $v
}

# ---- LIKE ------------------------------------------------------------------
proc ::mkitsql::likeRegexp {pat esc} {
    variable likeCache
    if {[info exists likeCache([list $pat $esc])]} { return $likeCache([list $pat $esc]) }
    set re "^"
    set n [string length $pat]
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $pat $i]
        if {$esc ne "" && $c eq $esc && $i + 1 < $n} {
            incr i
            append re [regsub -all {[][\\.^$*+?(){}|]} [string index $pat $i] {\\&}]
        } elseif {$c eq "%"} { append re ".*"
        } elseif {$c eq "_"} { append re "."
        } else { append re [regsub -all {[][\\.^$*+?(){}|]} $c {\\&}] }
    }
    append re "\$"
    if {[array size likeCache] > 500} { array unset likeCache }
    set likeCache([list $pat $esc]) "(?s)$re"
    return $likeCache([list $pat $esc])
}
# SIMILAR TO: the SQL regular expression (% any string, _ any character, | * + ? {m,n} ( ) [...] as in a regular expression, every other
# character literal - including . ^ $) as a Tcl regular expression.  The escape character defaults to backslash, as in PostgreSQL.
proc ::mkitsql::similarRegexp {pat esc} {
    variable likeCache
    if {[info exists likeCache([list S $pat $esc])]} { return $likeCache([list S $pat $esc]) }
    set re "" ; set n [string length $pat] ; set prevQuant 0
    if {$n > 2000} { ::mkitsql::fail "A SIMILAR TO pattern longer than 2000 characters is refused (Tcl compiles it in cubic time)" }
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $pat $i] ; set quant 0
        if {$esc ne "" && $c eq $esc} {
            if {$i + 1 >= $n} { ::mkitsql::fail "Invalid SIMILAR TO pattern: it ends with the escape character" }
            incr i ; append re [regsub -all {[][\\.^$*+?(){}|]} [string index $pat $i] {\\&}]
        } elseif {$c eq "\["} {
            # a bracket expression: copied up to its closing ], escapes inside it made literal
            set j [expr {$i + 1}] ; set body "\[" 
            if {[string index $pat $j] eq "^"} { append body "^" ; incr j }
            if {[string index $pat $j] eq "\]"} { append body "\\\]" ; incr j }
            set closed 0
            while {$j < $n} {
                set d [string index $pat $j]
                if {$esc ne "" && $d eq $esc && $j + 1 < $n} {
                    incr j ; append body [regsub -all {[][\\^-]} [string index $pat $j] {\\&}]
                } elseif {$d eq "\["} {
                    set k [string first ":\]" $pat $j]
                    if {[string index $pat [expr {$j + 1}]] eq ":" && $k > 0} {
                        append body [string range $pat $j [expr {$k + 1}]] ; set j [expr {$k + 1}]
                    } else { append body "\\\[" }
                } elseif {$d eq "\]"} {
                    set closed 1 ; break
                } elseif {$d eq "\\"} {
                    append body "\\\\"
                } else { append body $d }
                incr j
            }
            if {!$closed} { ::mkitsql::fail "Invalid SIMILAR TO pattern: a '\[' has no closing '\]'" }
            append re $body "\]" ; set i $j
        } elseif {$c eq "%"} { append re ".*"
        } elseif {$c eq "_"} { append re "."
        } elseif {$c eq "("} { append re "(?:"
        } elseif {$c in {* + ?}} {
            if {$prevQuant} { ::mkitsql::fail "Invalid SIMILAR TO pattern: '$c' cannot follow another repetition" }
            append re $c ; set quant 1
        } elseif {$c eq "\{"} {
            set k [string first "\}" $pat $i]
            if {$k < 0 || ![regexp {^\{\d+(,\d*)?\}$} [string range $pat $i $k]]} { ::mkitsql::fail "Invalid SIMILAR TO pattern: bad repetition '{...}'" }
            if {$prevQuant} { ::mkitsql::fail "Invalid SIMILAR TO pattern: '\{' cannot follow another repetition" }
            append re [string range $pat $i $k] ; set i $k ; set quant 1
        } elseif {$c in {| )}} { append re $c
        } else { append re [regsub -all {[][\\.^$*+?(){}|]} $c {\\&}] }
        set prevQuant $quant
    }
    set re "(?s)^(?:$re)\$"
    if {[catch {regexp -- $re ""} err]} { ::mkitsql::fail "Invalid SIMILAR TO pattern '$pat': $err" }
    if {[array size likeCache] > 500} { array unset likeCache }
    set likeCache([list S $pat $esc]) $re
    return $re
}
proc ::mkitsql::rt::like {v pat esc ci} {
    if {$v eq "\uFDD0NULL" || $pat eq "\uFDD0NULL" || $esc eq "\uFDD0NULL"} { return "\uFDD0NULL" }
    if {[string length $esc] > 1} { ::mkitsql::fail "The ESCAPE of LIKE / SIMILAR TO must be one character" }
    if {$ci >= 2} {
        # SIMILAR TO (ci 3: COLLATE NOCASE): backslash is the escape character unless an ESCAPE clause says otherwise (an empty ESCAPE does not switch it off)
        if {$ci == 3} { return [regexp -nocase -- [::mkitsql::similarRegexp $pat [expr {$esc eq "" ? "\\" : $esc}]] $v] }
        return [regexp -- [::mkitsql::similarRegexp $pat [expr {$esc eq "" ? "\\" : $esc}]] $v]
    }
    set re [::mkitsql::likeRegexp $pat $esc]
    if {$ci} { return [regexp -nocase -- $re $v] }
    return [regexp -- $re $v]
}

# ---- IN with a literal list ------------------------------------------------
proc ::mkitsql::rt::inlist {v list kind hasNull} {
    if {$v eq "\uFDD0NULL"} { return $v }
    switch -- $kind {
        n { set hit [expr {[lsearch -exact -real $list $v] >= 0}] }
        i {
            # whole numbers are canonical decimal text (a 32-bit lsearch -integer would not do on Tcl 8.5)
            set hit [expr {[lsearch -exact -ascii $list $v] >= 0}]
        }
        default { set hit [expr {[lsearch -exact -ascii $list $v] >= 0}] }
    }
    if {$hit} { return 1 }
    if {$hasNull} { return "\uFDD0NULL" }
    return 0
}

# ---- CASTs -----------------------------------------------------------------
# CAST(x AS INT) / CAST(x AS BIGINT): a value outside the type is an error (as in PostgreSQL), not a number the column could not hold
::mkitsql::defstrict cast_int {v {lo -9223372036854775808} {hi 9223372036854775807}} {
    set v [::mkitsql::rt::num $v]
    if {![string is integer -strict $v] && ![string is wideinteger -strict $v]} { set v [expr {round($v)}] }
    if {$v < $lo || $v > $hi} { ::mkitsql::fail "The value $v is out of range for [expr {$hi == 2147483647 ? {INTEGER} : {BIGINT}}]" }
    return $v
}
::mkitsql::defstrict cast_real {v} { set r [expr {double([::mkitsql::rt::num $v])}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r }
::mkitsql::defstrict cast_text {v} { return $v }
::mkitsql::defstrict cast_blob {v} { return $v }
::mkitsql::defstrict cast_bool {v} {
    switch -- [string tolower [string trim $v]] {
        t - true - yes - y - on - 1 { return 1 }
        f - false - no - n - off - 0 { return 0 }
    }
    if {[::mkitsql::rt::looksnum $v]} { return [expr {[::mkitsql::rt::num $v] != 0}] }
    ::mkitsql::fail "Invalid boolean: '[string range $v 0 40]'"
}
::mkitsql::defstrict cast_date {v} {
    if {![regexp {^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?\s*$} $v -> y m d hh mi ss]} {
        ::mkitsql::fail "Invalid date: '[string range $v 0 40]' (expected YYYY-MM-DD)"
    }
    set y [scan $y %d] ; set m [scan $m %d] ; set d [scan $d %d]
    ::mkitsql::dtCheck date $v $y $m $d 0 0 0
    return [format %04d-%02d-%02d $y $m $d]
}
::mkitsql::defstrict cast_timestamp {v} {
    if {![regexp {^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?\s*$} $v -> y m d hh mi ss]} {
        ::mkitsql::fail "Invalid timestamp: '[string range $v 0 40]' (expected YYYY-MM-DD HH:MM:SS)"
    }
    if {$hh eq ""} { set hh 0 ; set mi 0 ; set ss 0 }
    if {$ss eq ""} { set ss 0 }
    ::mkitsql::dtCheck timestamp $v [scan $y %d] [scan $m %d] [scan $d %d] [scan $hh %d] [scan $mi %d] $ss
    if {[string first . $ss] >= 0} {
        return [format "%04d-%02d-%02d %02d:%02d:%s" [scan $y %d] [scan $m %d] [scan $d %d] [scan $hh %d] [scan $mi %d] $ss]
    }
    return [format "%04d-%02d-%02d %02d:%02d:%02d" [scan $y %d] [scan $m %d] [scan $d %d] [scan $hh %d] [scan $mi %d] [scan $ss %d]]
}
::mkitsql::defstrict cast_time {v} {
    if {![regexp {^\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*$} $v -> hh mi ss]} {
        ::mkitsql::fail "Invalid time: '[string range $v 0 40]' (expected HH:MM:SS)"
    }
    if {$ss eq ""} { set ss 0 }
    ::mkitsql::dtCheck time $v 1970 1 1 [scan $hh %d] [scan $mi %d] [scan $ss %d]
    return [format %02d:%02d:%02d [scan $hh %d] [scan $mi %d] [scan $ss %d]]
}

# ---- scalar functions ------------------------------------------------------
::mkitsql::defstrict fn_ABS {a} { expr {abs($a)} }
::mkitsql::defstrict fn_SIGN {a} { expr {$a > 0 ? 1 : ($a < 0 ? -1 : 0)} }
::mkitsql::defstrict fn_CEIL {a} { set r [expr {double(ceil($a))}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r }
::mkitsql::defstrict fn_FLOOR {a} { set r [expr {double(floor($a))}] ; if {$r eq "-0.0"} { return 0.0 } ; return $r }
# ROUND / TRUNC work on the number's shortest decimal form, so ROUND(2.675, 2) is 2.68
# and ties round away from zero (the SQL rule) instead of following binary noise.
# (digit counts beyond what a double can hold change nothing / give zero: clamped, since 10 ** n is a bignum)
::mkitsql::defstrict fn_ROUND {a {n 0}} {
    set n [::mkitsql::rt::toInt $n]
    if {$n > 400} { return [expr {double($a)}] } ; if {$n < -400} { return 0.0 }
    ::mkitsql::decRound $a $n 1
}
::mkitsql::defstrict fn_TRUNC {a {n 0}} {
    set n [::mkitsql::rt::toInt $n]
    if {$n > 400} { return [expr {double($a)}] } ; if {$n < -400} { return 0.0 }
    ::mkitsql::decRound $a $n 0
}
::mkitsql::defstrict fn_SQRT {a} {
    if {$a < 0} { ::mkitsql::fail "Cannot take square root of a negative number" }
    expr {sqrt($a)}
}
::mkitsql::defstrict fn_POWER {a b} {
    if {[catch {expr {double($a) ** $b}} r]} { ::mkitsql::fail "Cannot compute POWER($a, $b)" }
    return $r
}
::mkitsql::defstrict fn_EXP {a} { expr {exp($a)} }
::mkitsql::defstrict fn_LN {a} {
    if {$a <= 0} { ::mkitsql::fail "Cannot take logarithm of zero or a negative number" }
    expr {log($a)}
}
::mkitsql::defstrict fn_LOG10 {a} {
    if {$a <= 0} { ::mkitsql::fail "Cannot take logarithm of zero or a negative number" }
    expr {log10($a)}
}
::mkitsql::defstrict fn_SIN {a} { expr {sin($a)} }
::mkitsql::defstrict fn_COS {a} { expr {cos($a)} }
::mkitsql::defstrict fn_TAN {a} { expr {tan($a)} }
::mkitsql::defstrict fn_ASIN {a} { if {abs($a) > 1} { ::mkitsql::fail "ASIN needs a number from -1 to 1" } ; expr {asin($a)} }
::mkitsql::defstrict fn_ACOS {a} { if {abs($a) > 1} { ::mkitsql::fail "ACOS needs a number from -1 to 1" } ; expr {acos($a)} }
::mkitsql::defstrict fn_ATAN {a} { expr {atan($a)} }
::mkitsql::defstrict fn_ATAN2 {a b} { expr {atan2($a, $b)} }
::mkitsql::defstrict fn_DEGREES {a} { expr {$a * 180.0 / 3.141592653589793} }
::mkitsql::defstrict fn_RADIANS {a} { expr {$a * 3.141592653589793 / 180.0} }
proc ::mkitsql::rt::fn_ROWID_ {cur} { lindex [split $cur !] end }
proc ::mkitsql::rt::fn_PI {} { return 3.141592653589793 }
proc ::mkitsql::rt::fn_RANDOM {} { expr {rand()} }

::mkitsql::defstrict fn_LENGTH {a} { string length $a }
::mkitsql::defstrict fn_OCTET_LENGTH {a} { string length [encoding convertto utf-8 $a] }
::mkitsql::defstrict fn_UPPER {a} { string toupper $a }
::mkitsql::defstrict fn_LOWER {a} { string tolower $a }
::mkitsql::defstrict fn_INITCAP {a} {
    set out "" ; set up 1
    foreach c [split $a ""] {
        if {[string is alnum $c]} {
            append out [expr {$up ? [string toupper $c] : [string tolower $c]}] ; set up 0
        } else { append out $c ; set up 1 }
    }
    return $out
}
::mkitsql::defstrict fn_TRIM_ {mode chars v} {
    switch -- $mode {
        leading  { return [string trimleft $v $chars] }
        trailing { return [string trimright $v $chars] }
    }
    string trim $v $chars
}
::mkitsql::defstrict fn_LTRIM {v {chars " "}} { string trimleft $v $chars }
::mkitsql::defstrict fn_RTRIM {v {chars " "}} { string trimright $v $chars }
::mkitsql::defstrict fn_REPLACE {s from to} {
    if {$from eq ""} { return $s }
    string map [list $from $to] $s
}
# A whole-number argument (a count, a position, a code point): integers as they are, other numbers rounded, anything else
# an error - never a raw Tcl error, and never a value that wraps around (found by an adversarial review: CHR(-4294902320)
# wrapped to U+FDD0 and forged NULL).
proc ::mkitsql::rt::toInt {v} {
    if {[string is wideinteger -strict $v]} { return $v }
    if {[string is double -strict $v] && $v == $v && abs($v) < 9.2e18} { return [expr {entier(round($v))}] }
    ::mkitsql::fail "A whole number was expected, not '[string range $v 0 40]'"
}
# longest string a function may build (a LPAD / REPEAT / || chain can otherwise exhaust memory from one short statement)
proc ::mkitsql::rt::room {n} {
    if {$n > $::mkitsql::maxString} { ::mkitsql::fail "The result would be longer than $::mkitsql::maxString characters (::mkitsql::maxString)" }
}
# SUBSTR(s, start [, len])  -- 1-based; follows the SQL standard for
# out-of-range start / length.
::mkitsql::defstrict fn_SUBSTR {s start {len ""}} {
    if {$len eq "\uFDD0NULL"} { return $len }
    set start [::mkitsql::rt::toInt $start]
    if {$len ne ""} { set len [::mkitsql::rt::toInt $len] }
    set from $start
    if {$len eq ""} {
        set to [string length $s]
    } else {
        if {$len < 0} { ::mkitsql::fail "Negative substring length not allowed" }
        set to [expr {$start + $len - 1}]
    }
    if {$from < 1} { set from 1 }
    if {$to > [string length $s]} { set to [string length $s] }
    if {$to < $from} { return "" }
    string range $s [expr {$from - 1}] [expr {$to - 1}]
}
# a negative count means "all but that many from the other end" (PostgreSQL)
::mkitsql::defstrict fn_LEFT {s n} {
    set n [::mkitsql::rt::toInt $n]
    if {$n < 0} { set n [expr {[string length $s] + $n}] }
    if {$n <= 0} { return "" }
    string range $s 0 [expr {$n - 1}]
}
::mkitsql::defstrict fn_RIGHT {s n} {
    set n [::mkitsql::rt::toInt $n]
    if {$n < 0} { set n [expr {[string length $s] + $n}] }
    if {$n <= 0} { return "" }
    string range $s [expr {[string length $s] - $n}] end
}
::mkitsql::defstrict fn_POSITION {needle hay} {
    if {$needle eq ""} { return 1 }
    expr {[string first $needle $hay] + 1}
}
::mkitsql::defstrict fn_REPEAT {s n} {
    set n [::mkitsql::rt::toInt $n]
    if {$n <= 0 || $s eq ""} { return "" }
    ::mkitsql::rt::room [expr {$n * [string length $s]}]
    string repeat $s $n
}
::mkitsql::defstrict fn_REVERSE {s} {
    set out ""
    foreach c [split $s ""] { set out $c$out }
    return $out
}
::mkitsql::defstrict fn_LPAD {s n {fill " "}} {
    set n [::mkitsql::rt::toInt $n]
    ::mkitsql::rt::room $n
    set len [string length $s]
    if {$n <= $len} { return [string range $s 0 [expr {$n - 1}]] }
    if {$fill eq ""} { return $s }
    set pad [string range [string repeat $fill [expr {($n - $len) / [string length $fill] + 1}]] 0 [expr {$n - $len - 1}]]
    return $pad$s
}
::mkitsql::defstrict fn_RPAD {s n {fill " "}} {
    set n [::mkitsql::rt::toInt $n]
    ::mkitsql::rt::room $n
    set len [string length $s]
    if {$n <= $len} { return [string range $s 0 [expr {$n - 1}]] }
    if {$fill eq ""} { return $s }
    set pad [string range [string repeat $fill [expr {($n - $len) / [string length $fill] + 1}]] 0 [expr {$n - $len - 1}]]
    return $s$pad
}
::mkitsql::defstrict fn_ASCII {s} { if {$s eq ""} { return 0 } ; scan [string index $s 0] %c }
::mkitsql::defstrict fn_CHR {n} {
    set n [::mkitsql::rt::toInt $n]
    if {$n < 0 || $n > 0x10FFFF || ($n >= 0xD800 && $n <= 0xDFFF)} { ::mkitsql::fail "CHR() needs a code point from 0 to 1114111 (not a surrogate)" }
    if {$n == 64976} { ::mkitsql::fail "CHR(64976) is reserved: U+FDD0 marks NULL inside the engine" }
    format %c $n
}
proc ::mkitsql::rt::fn_CONCAT {args} {
    set out ""
    foreach a $args { if {$a ne "\uFDD0NULL"} { append out $a } }
    return $out
}
proc ::mkitsql::rt::fn_CONCAT_WS {sep args} {
    if {$sep eq "\uFDD0NULL"} { return $sep }
    set parts {}
    foreach a $args { if {$a ne "\uFDD0NULL"} { lappend parts $a } }
    return [join $parts $sep]
}
proc ::mkitsql::rt::fn_NULLIF {a b eqproc} {
    if {$a eq "\uFDD0NULL"} { return $a }
    if {[$eqproc $a $b] eq "1"} { return "\uFDD0NULL" }
    return $a
}
# GREATEST / LEAST ignore NULLs (as PostgreSQL does); kind n = numeric, s = text.
proc ::mkitsql::rt::fn_GREATEST {kind args} {
    set best "\uFDD0NULL"
    foreach a $args {
        if {$a eq "\uFDD0NULL"} continue
        if {$best eq "\uFDD0NULL"} { set best $a ; continue }
        if {$kind eq "n" ? $a > $best : [string compare $a $best] > 0} { set best $a }
    }
    return $best
}
proc ::mkitsql::rt::fn_LEAST {kind args} {
    set best "\uFDD0NULL"
    foreach a $args {
        if {$a eq "\uFDD0NULL"} continue
        if {$best eq "\uFDD0NULL"} { set best $a ; continue }
        if {$kind eq "n" ? $a < $best : [string compare $a $best] < 0} { set best $a }
    }
    return $best
}

# date / time
proc ::mkitsql::rt::fn_CURRENT_DATE {} { clock format [clock seconds] -format %Y-%m-%d }
proc ::mkitsql::rt::fn_CURRENT_TIME {} { clock format [clock seconds] -format %H:%M:%S }
proc ::mkitsql::rt::fn_CURRENT_TIMESTAMP {} { clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S" }
::mkitsql::defstrict fn_EXTRACT {field v} {
    if {[::mkitsql::isIv $v]} { return [::mkitsql::ivExtract $field $v] }
    set p [::mkitsql::dtParse $v]
    dict with p {}
    if {$kind eq "time" && $field in {YEAR MONTH DAY DOW DOY}} {
        ::mkitsql::fail "Cannot extract $field from a TIME"
    }
    set sec [expr {$ss == entier($ss) ? entier($ss) : $ss}]
    switch -- $field {
        YEAR   { return $y }
        MONTH  { return $m }
        DAY    { return $d }
        HOUR   { return $hh }
        MINUTE { return $mi }
        SECOND { return $sec }
        DOW    { return [expr {([::mkitsql::daysFromCivil $y $m $d] + 4) % 7}] }        ;# Sunday = 0
        DOY    { return [expr {[::mkitsql::daysFromCivil $y $m $d] - [::mkitsql::daysFromCivil $y 1 1] + 1}] }
        EPOCH  { return [::mkitsql::dtEpoch $p] }
    }
    ::mkitsql::fail "Unknown EXTRACT field '$field'"
}

# Round (up=1) or truncate (up=0) to n decimals; n may be negative.  Returns a double.
proc ::mkitsql::decRound {a n up} {
    set v [expr {double($a)}]
    if {$v != $v || $v == Inf || $v == -Inf} { return $v }
    if {$v == 0} { return 0.0 }
    if {![regexp {^(-?)(\d+)(?:\.(\d+))?(?:[eE]([-+]?\d+))?$} $v -> sign ip fp ex]} { return $v }
    if {$ex eq ""} { set ex 0 }
    set m [string trimleft $ip$fp 0]
    if {$m eq ""} { return 0.0 }
    set e [expr {$ex - [string length $fp]}]       ;# value = m * 10^e
    if {$e >= -$n} { return $v }
    set p [expr {10 ** (-$n - $e)}]
    set q [expr {$m / $p}]
    if {$up && 2 * ($m % $p) >= $p} { incr q }
    if {$n >= 0} { set r [expr {double($q) / (10.0 ** $n)}] } else { set r [expr {double($q) * (10.0 ** (-$n))}] }
    if {$sign eq "-" && $r != 0} { set r [expr {-$r}] }
    return $r
}

# ============================================================================
#  Types
# ============================================================================
proc ::mkitsql::isNumType {t} { expr {$t in {int real bool}} }

proc ::mkitsql::unify {a b} {
    if {$a eq $b} { return $a }
    if {$a eq "null"} { return $b }
    if {$b eq "null"} { return $a }
    if {$a in {int bool} && $b in {int bool}} { return int }
    if {[isNumType $a] && [isNumType $b]} { return real }
    if {$a eq "blob" && $b eq "blob"} { return blob }
    if {$a eq "datetime" && $b eq "text" || $a eq "text" && $b eq "datetime"} { return text }
    return text
}

# Metakit column letter -> static type
proc ::mkitsql::typeOfLetter {l} {
    switch -- $l {
        I - L { return int }
        F - D { return real }
        B { return blob }
        default { return text }
    }
}
# static type -> display letter for grids ("" = unknown)
proc ::mkitsql::letterOfType {t} {
    switch -- $t { int - bool { return N } real { return N } blob { return B } }
    return ""
}

# SQL type name (from CAST / CREATE TABLE) -> {metakitLetter staticType castKind}
proc ::mkitsql::sqlType {name} {
    switch -- $name {
        int - integer - smallint - tinyint - mediumint { return {I int int} }
        bigint - long { return {L int int} }
        real - float4 { return {F real real} }
        float - double - float8 - decimal - numeric - dec - number { return {D real real} }
        boolean - bool { return {I bool bool} }
        varchar - char - text - string - clob - nvarchar - nchar - character - bpchar { return {S text text} }
        blob - binary - varbinary - bytes - bytea - bit { return {B blob blob} }
        date { return {S datetime date} }
        time { return {S datetime time} }
        timestamp - datetime { return {S datetime timestamp} }
        interval { return {S interval interval} }
    }
    fail "Unknown type '$name'. Supported: INT, BIGINT, REAL, DOUBLE, DECIMAL/NUMERIC, BOOLEAN, VARCHAR/TEXT, BLOB, DATE, TIME, TIMESTAMP"
}

# ============================================================================
#  Code generation
# ============================================================================
# Every cg* returns {word type}: `word` is a Tcl command-argument word (a
# literal or a [command substitution]) that yields the value when evaluated
# inside a proc whose arguments are  r0 (current tuple) and outer (list of
# enclosing tuples, nearest first).

proc ::mkitsql::cgFail {msg} { fail $msg }

# coerce a {word type} pair to a boolean word
proc ::mkitsql::asBool {wt ctxName} {
    lassign $wt w t
    switch -- $t {
        bool - null { return $w }
        int - real  { return "\[::mkitsql::rt::tobool $w\]" }
    }
    fail "Argument of $ctxName must be a boolean or a number, not text"
}
# coerce to a numeric word (casting text)
proc ::mkitsql::asNum {wt} {
    lassign $wt w t
    if {$t in {int real bool null}} { return $wt }
    return [list "\[::mkitsql::rt::num $w\]" real]
}
proc ::mkitsql::asText {wt} {
    lassign $wt w t
    return [list $w text]
}

proc ::mkitsql::cg {node ctx} {
    variable N
    switch -- [lindex $node 0] {
        lit {
            lassign $node _ ty v
            if {$ty eq "null"} { return [list [list $N] null] }
            return [list [list $v] $ty]
        }
        ref {
            lassign $node _ level src name ty
            set pos [ctxPos $ctx $level $src $name]
            if {$level == 0} { return [list "\[lindex \$r0 $pos\]" $ty] }
            return [list "\[lindex \[lindex \$outer [expr {$level - 1}]\] $pos\]" $ty]
        }
        slot {
            lassign $node _ pos ty
            return [list "\[lindex \$r0 $pos\]" $ty]
        }
        un {
            lassign $node _ op e
            set a [cg $e $ctx]
            if {$op eq "not"} {
                return [list "\[::mkitsql::rt::not [asBool $a NOT]\]" bool]
            }
            if {[lindex $a 1] eq "interval"} { return [list "\[::mkitsql::rt::iv_neg [lindex $a 0]\]" interval] }
            lassign [asNum $a] w t
            return [list "\[::mkitsql::rt::neg $w\]" $t]
        }
        bin { return [cgBin $node $ctx] }
        isnull {
            lassign $node _ e neg
            set w [lindex [cg $e $ctx] 0]
            return [list "\[::mkitsql::rt::[expr {$neg ? {notnull} : {isnull}}] $w\]" bool]
        }
        istf {
            lassign $node _ e val neg
            set a [cg $e $ctx]
            if {[lindex $a 1] eq "text"} { fail "IS TRUE / IS FALSE needs a boolean or a number" }
            return [list "\[::mkitsql::rt::istf [lindex $a 0] $val $neg\]" bool]
        }
        isdist {
            lassign $node _ a b neg
            set wa [lindex [cg $a $ctx] 0] ; set wb [lindex [cg $b $ctx] 0]
            return [list "\[::mkitsql::rt::isdist $wa $wb $neg\]" bool]
        }
        between {
            lassign $node _ e lo hi neg
            set ge [list bin >= $e $lo] ; set le [list bin <= $e $hi]
            set both [list bin and $ge $le]
            if {$neg} { set both [list un not $both] }
            return [cg $both $ctx]
        }
        like {
            lassign $node _ e pat esc neg ci
            set a [cg $e $ctx] ; set p [cg $pat $ctx]
            set escw [expr {$esc eq "" ? [list {}] : [lindex [cg $esc $ctx] 0]}]
            set code "\[::mkitsql::rt::like [lindex $a 0] [lindex $p 0] $escw $ci\]"
            if {$neg} { set code "\[::mkitsql::rt::not $code\]" }
            return [list $code bool]
        }
        in { return [cgIn $node $ctx] }
        insub {
            lassign $node _ e bq neg refs
            set a [cg $e $ctx]
            set id [subPlan $bq $refs $ctx]
            set code "\[::mkitsql::rt::insub $id [lindex $a 0] \$r0 \$outer [subKey $refs $ctx]\]"
            if {$neg} { set code "\[::mkitsql::rt::not $code\]" }
            return [list $code bool]
        }
        exists {
            lassign $node _ bq refs
            set id [subPlan $bq $refs $ctx]
            return [list "\[::mkitsql::rt::exists $id \$r0 \$outer [subKey $refs $ctx]\]" bool]
        }
        sub {
            lassign $node _ bq refs ty
            set id [subPlan $bq $refs $ctx]
            return [list "\[::mkitsql::rt::scalar $id \$r0 \$outer [subKey $refs $ctx]\]" $ty]
        }
        quant {
            lassign $node _ op kind e bq refs ty
            set a [cg $e $ctx]
            set id [subPlan $bq $refs $ctx]
            set nm [dict get {= eq <> ne < lt <= le > gt >= ge} $op]
            set ck [cmpKind [lindex $a 1] $ty]
            return [list "\[::mkitsql::rt::quant $id $nm $kind $ck [lindex $a 0] \$r0 \$outer [subKey $refs $ctx]\]" bool]
        }
        case { return [cgCase $node $ctx] }
        cast { return [cgCast $node $ctx] }
        func { return [cgFunc $node $ctx] }
        win { fail "Window functions are only allowed in the select list and in ORDER BY" }
    }
    error "cg: unknown node [lindex $node 0]"
}

proc ::mkitsql::ctxPos {ctx level src name} {
    if {[dict exists $ctx dry]} { return 0 }
    set maps [dict get $ctx maps]
    set m [lindex $maps $level]
    set k $src,[string tolower $name]
    if {![dict exists $m $k]} { error "internal: unresolved column $k (level $level)" }
    return [dict get $m $k]
}

# Compile a bound subquery appearing inside an expression.  Returns its plan id.
proc ::mkitsql::subPlan {bq refs ctx} {
    variable planCorr ; variable planMemo ; variable volatileSeen
    if {[dict exists $ctx dry]} { return 0 }
    set saved $volatileSeen ; set volatileSeen 0
    set id [compileQuery $bq [dict get $ctx maps]]
    set planCorr($id) [expr {[llength $refs] > 0}]
    set planMemo($id) [expr {$planCorr($id) && !$volatileSeen}]
    set volatileSeen [expr {$saved || $volatileSeen}]
    return $id
}
# The values of the enclosing query's columns that a correlated subquery reads, as Tcl code that builds a list of them.  The
# subquery's answer depends on nothing else, so one run per distinct list is enough (rt::memo): a correlated subquery costs
# (distinct keys) x (its own cost) instead of (outer rows) x (its own cost).  "" when it cannot be decided (not memoised).
proc ::mkitsql::subKey {refs ctx} {
    if {[dict exists $ctx dry] || ![llength $refs]} { return "" }
    set parts {} ; set seen {}
    foreach r $refs {
        lassign $r lvl src name
        set lv [expr {$lvl - 1}]
        if {[dict exists $seen $lv,$src,$name]} continue
        dict set seen $lv,$src,$name 1
        if {[catch {ctxPos $ctx $lv $src $name} pos]} { return "" }
        lappend parts [expr {$lv == 0 ? "\[lindex \$r0 $pos\]" : "\[lindex \[lindex \$outer [expr {$lv - 1}]\] $pos\]"}]
    }
    return "\[list [join $parts { }]\]"
}

proc ::mkitsql::cmpKind {ta tb} {
    if {$ta eq "interval" || $tb eq "interval"} {
        if {($ta eq "interval" || $ta eq "null") && ($tb eq "interval" || $tb eq "null")} { return i }
        fail "An interval can only be compared with another interval"
    }
    set na [isNumType $ta] ; set nb [isNumType $tb]
    if {$na && $nb} { return n }
    if {($ta eq "null") || ($tb eq "null")} { return n }
    if {!$na && !$nb} { return s }
    return m
}

proc ::mkitsql::cgBin {node ctx} {
    lassign $node _ op a b
    switch -- $op {
        and - or {
            set wa [asBool [cg $a $ctx] [string toupper $op]]
            set wb [asBool [cg $b $ctx] [string toupper $op]]
            variable cxCount
            set t t[incr cxCount]
            if {$op eq "and"} {
                return [list "\[if {\[set $t $wa\] eq \"0\"} {set _ 0} else {::mkitsql::rt::and2 \$$t $wb}\]" bool]
            }
            return [list "\[if {\[set $t $wa\] eq \"1\"} {set _ 1} else {::mkitsql::rt::or2 \$$t $wb}\]" bool]
        }
        || {
            set ca [cg $a $ctx] ; set cb [cg $b $ctx]
            set wa [textWord $ca] ; set wb [textWord $cb]
            return [list "\[::mkitsql::rt::cat $wa $wb\]" text]
        }
        = - <> - < - <= - > - >= {
            set ca [cg $a $ctx] ; set cb [cg $b $ctx]
            set kind [cmpKind [lindex $ca 1] [lindex $cb 1]]
            set nm [dict get {= eq <> ne < lt <= le > gt >= ge} $op]
            return [list "\[::mkitsql::rt::${nm}_$kind [lindex $ca 0] [lindex $cb 0]\]" bool]
        }
        + - - - * - / - % {
            set ra [cg $a $ctx] ; set rb [cg $b $ctx]
            set sp [cgDateArith $op $ra $rb]
            if {$sp ne ""} { return $sp }
            set ca [asNum $ra] ; set cb [asNum $rb]
            lassign $ca wa ta ; lassign $cb wb tb
            set isint [expr {$ta in {int bool} && $tb in {int bool}}]
            set res [expr {$isint ? "int" : "real"}]
            if {$ta eq "null" && $tb eq "null"} { set res int }
            switch -- $op {
                +  { set fn add }
                -  { set fn sub }
                *  { set fn mul }
                /  { set fn [expr {$isint ? "idiv" : "rdiv"}] }
                %  { set fn [expr {$isint ? "imod" : "rmod"}] }
            }
            return [list "\[::mkitsql::rt::$fn $wa $wb\]" $res]
        }
    }
    error "cgBin: $op"
}

# text form of an operand (an interval value is tagged internally; this shows it as text)
proc ::mkitsql::textWord {c} {
    if {[lindex $c 1] eq "interval"} { return "\[::mkitsql::rt::iv_fmt [lindex $c 0]\]" }
    return [lindex $c 0]
}

# date and interval arithmetic; returns {} when neither operand is date/interval typed
proc ::mkitsql::cgDateArith {op ra rb} {
    lassign $ra wa ta ; lassign $rb wb tb
    set ia [expr {$ta eq "interval"}] ; set ib [expr {$tb eq "interval"}]
    set da [expr {$ta in {datetime text null}}] ; set db [expr {$tb in {datetime text null}}]
    set na [isNumType $ta] ; set nb [isNumType $tb]
    if {!$ia && !$ib} {
        # a date with NULL is NULL, not a number
        if {$op in {+ -} && (($ta eq "datetime" && $tb eq "null") || ($ta eq "null" && $tb eq "datetime"))} {
            return [list [list $::mkitsql::N] null]
        }
        if {$op eq "-" && $ta eq "datetime" && $tb eq "datetime"} {
            return [list "\[::mkitsql::rt::dt_sub $wa $wb\]" interval]
        }
        return {}
    }
    switch -- $op {
        + {
            if {$ia && $ib} { return [list "\[::mkitsql::rt::iv_add $wa $wb\]" interval] }
            if {$ia && $db} { return [list "\[::mkitsql::rt::dt_add_iv $wb $wa\]" datetime] }
            if {$da && $ib} { return [list "\[::mkitsql::rt::dt_add_iv $wa $wb\]" datetime] }
        }
        - {
            if {$ia && $ib} { return [list "\[::mkitsql::rt::iv_sub $wa $wb\]" interval] }
            if {$da && $ib} { return [list "\[::mkitsql::rt::dt_sub_iv $wa $wb\]" datetime] }
        }
        * {
            if {$ia && ($nb || $tb eq "null")} { return [list "\[::mkitsql::rt::iv_mul $wa $wb\]" interval] }
            if {$ib && ($na || $ta eq "null")} { return [list "\[::mkitsql::rt::iv_mul $wb $wa\]" interval] }
        }
        / {
            if {$ia && ($nb || $tb eq "null")} { return [list "\[::mkitsql::rt::iv_div $wa $wb\]" interval] }
        }
    }
    fail "The operator $op cannot be used between $ta and $tb"
}

proc ::mkitsql::cgIn {node ctx} {
    variable N
    lassign $node _ e items neg
    set ca [cg $e $ctx]
    lassign $ca wa ta
    set allLit 1
    foreach it $items { if {[lindex $it 0] ne "lit"} { set allLit 0 } }
    if {$allLit} {
        set vals {} ; set hasNull 0 ; set kind s
        set anyText 0 ; set anyNum 0 ; set anyReal 0
        foreach it $items {
            lassign $it _ ty v
            if {$ty eq "null"} { set hasNull 1 ; continue }
            lappend vals $v
            if {[isNumType $ty]} { set anyNum 1 } else { set anyText 1 }
            if {$ty eq "real"} { set anyReal 1 }
        }
        if {[isNumType $ta] && !$anyText} { set kind n }
        # whole numbers compare as whole numbers: as doubles, 9223372036854775806 and ...807 are the same
        if {$kind eq "n" && $ta in {int bool} && !$anyReal} { set kind i }
        if {$kind in {n i} || ([isNumType $ta] == 0 && !$anyNum)} {
            set code "\[::mkitsql::rt::inlist $wa [list $vals] $kind $hasNull\]"
            if {$neg} { set code "\[::mkitsql::rt::not $code\]" }
            return [list $code bool]
        }
    }
    # general case: OR of equalities
    set expr {}
    foreach it $items {
        set eqn [list bin = $e $it]
        if {$expr eq ""} { set expr $eqn } else { set expr [list bin or $expr $eqn] }
    }
    if {$neg} { set expr [list un not $expr] }
    return [cg $expr $ctx]
}

proc ::mkitsql::cgCase {node ctx} {
    lassign $node _ operand whens else
    set resType null
    set conds {} ; set results {}
    foreach w $whens {
        lassign $w c r
        if {$operand ne ""} { set c [list bin = $operand $c] }
        lappend conds [asBool [cg $c $ctx] WHEN]
        set cr [cg $r $ctx]
        lappend results [lindex $cr 0]
        set resType [unify $resType [lindex $cr 1]]
    }
    set ce [cg $else $ctx]
    set resType [unify $resType [lindex $ce 1]]
    set code [lindex $ce 0]
    set code "set _ $code"
    for {set i [expr {[llength $conds] - 1}]} {$i >= 0} {incr i -1} {
        set code "if {\[string equal [lindex $conds $i] 1\]} {set _ [lindex $results $i]} else {$code}"
    }
    return [list "\[$code\]" $resType]
}

proc ::mkitsql::cgCast {node ctx} {
    lassign $node _ e ty
    lassign [sqlType $ty] letter st kind
    set ca [cg $e $ctx]
    set w [lindex $ca 0]
    if {[lindex $ca 1] eq "interval"} {
        if {$kind eq "text"} { return [list "\[::mkitsql::rt::iv_fmt $w\]" text] }
        if {$kind eq "interval"} { return $ca }
        fail "An interval can only be cast to text"
    }
    if {$kind eq "int" && $letter eq "I" && $st eq "int"} { return [list "\[::mkitsql::rt::cast_int $w -2147483648 2147483647\]" $st] }
    return [list "\[::mkitsql::rt::cast_$kind $w\]" $st]
}

# name -> {min max rettype} ; rettype: a type name, argN (type of arg N), num0
# (arg 0 if numeric else real), unify
proc ::mkitsql::funcTable {} {
    variable FT
    if {[info exists FT]} { return $FT }
    set FT {
        ABS {1 1 num0}      SIGN {1 1 int}     CEIL {1 1 real}    CEILING {1 1 real}
        FLOOR {1 1 real}    ROUND {1 2 real}   TRUNC {1 2 real}   TRUNCATE {1 2 real}
        SQRT {1 1 real}     POWER {2 2 real}   POW {2 2 real}     EXP {1 1 real}
        LN {1 1 real}       LOG10 {1 1 real}   SIN {1 1 real}     COS {1 1 real}
        TAN {1 1 real}      ASIN {1 1 real}    ACOS {1 1 real}    ATAN {1 1 real}
        ATAN2 {2 2 real}    DEGREES {1 1 real} RADIANS {1 1 real} PI {0 0 real}
        RANDOM {0 0 real}   MOD {2 2 unify}
        LENGTH {1 1 int}    CHAR_LENGTH {1 1 int} CHARACTER_LENGTH {1 1 int} OCTET_LENGTH {1 1 int}
        UPPER {1 1 text}    LOWER {1 1 text}   INITCAP {1 1 text}  TRIM_ {3 3 text}
        TRIM {1 2 text}     LTRIM {1 2 text}   RTRIM {1 2 text}   REPLACE {3 3 text}
        SUBSTR {2 3 text}   SUBSTRING {2 3 text} LEFT {2 2 text}  RIGHT {2 2 text}
        POSITION {2 2 int}  INSTR {2 2 int}    REPEAT {2 2 text}  REVERSE {1 1 text}
        LPAD {2 3 text}     RPAD {2 3 text}    ASCII {1 1 int}    CHR {1 1 text}
        CONCAT {1 -1 text}  CONCAT_WS {2 -1 text}
        COALESCE {1 -1 unify} IFNULL {2 2 unify} NVL {2 2 unify} NULLIF {2 2 arg0}
        GREATEST {1 -1 unify} LEAST {1 -1 unify}
        CURRENT_DATE {0 0 datetime} CURRENT_TIME {0 0 datetime} CURRENT_TIMESTAMP {0 0 datetime}
        LOCALTIME {0 0 datetime} LOCALTIMESTAMP {0 0 datetime} NOW {0 0 datetime}
        EXTRACT {2 2 num0}  ROWID_ {1 1 int}
    }
    return $FT
}

# Function names for editor highlighting / completion (internal helpers excluded).
set ::mkitsql::functions {}
foreach {k v} [::mkitsql::funcTable] {
    if {![string match *_ $k]} { lappend ::mkitsql::functions $k }
}
set ::mkitsql::functions [lsort $::mkitsql::functions]

proc ::mkitsql::cgFunc {node ctx} {
    variable aggs
    variable N
    lassign $node _ name distinct args
    if {[lsearch -exact $aggs $name] >= 0} {
        fail "Aggregate function ${name}() is not allowed here"
    }
    set ft [funcTable]
    if {![dict exists $ft $name]} { fail "Unknown function ${name}()" }
    lassign [dict get $ft $name] mn mx rt
    set n [llength $args]
    if {$n < $mn || ($mx >= 0 && $n > $mx)} {
        fail "Function ${name}() takes [expr {$mn == $mx ? $mn : ($mx < 0 ? "at least $mn" : "$mn to $mx")}] argument[expr {$mx == 1 ? {} : {s}}], not $n"
    }
    if {$name eq "RANDOM"} { variable volatileSeen ; set volatileSeen 1 }
    set cargs {}
    foreach a $args { lappend cargs [cg $a $ctx] }
    set words {} ; set types {}
    foreach c $cargs { lappend words [lindex $c 0] ; lappend types [lindex $c 1] }

    # ---- result type
    switch -- $rt {
        num0 {
            set t0 [lindex $types 0]
            set rtype [expr {$t0 in {int bool} ? "int" : "real"}]
            if {$name in {ROUND TRUNC TRUNCATE FLOOR CEIL CEILING ABS} && $t0 eq "null"} { set rtype int }
        }
        unify { set rtype null ; foreach t $types { set rtype [unify $rtype $t] } }
        arg0 { set rtype [lindex $types 0] }
        default { set rtype $rt }
    }

    # ---- special forms
    switch -- $name {
        COALESCE - IFNULL - NVL {
            set code "set _ $N"
            for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
                variable cxCount
                set t t[incr cxCount]
                set code "if {\[::mkitsql::rt::notnull \[set $t [lindex $words $i]\]\]} {set _ \$$t} else {$code}"
            }
            return [list "\[$code\]" $rtype]
        }
        NULLIF {
            set kind [cmpKind [lindex $types 0] [lindex $types 1]]
            return [list "\[::mkitsql::rt::fn_NULLIF [lindex $words 0] [lindex $words 1] ::mkitsql::rt::eq_$kind\]" $rtype]
        }
        GREATEST - LEAST {
            set kind [expr {[isNumType $rtype] ? "n" : "s"}]
            return [list "\[::mkitsql::rt::fn_$name $kind [join $words { }]\]" $rtype]
        }
        MOD {
            lassign [asNum [lindex $cargs 0]] wa ta ; lassign [asNum [lindex $cargs 1]] wb tb
            set isint [expr {$ta in {int bool} && $tb in {int bool}}]
            return [list "\[::mkitsql::rt::[expr {$isint ? {imod} : {rmod}}] $wa $wb\]" [expr {$isint ? "int" : "real"}]]
        }
        NOW { set name CURRENT_TIMESTAMP }
        LOCALTIME { set name CURRENT_TIME }
        LOCALTIMESTAMP { set name CURRENT_TIMESTAMP }
        CEILING { set name CEIL }
        TRUNCATE { set name TRUNC }
        POW { set name POWER }
        SUBSTRING { set name SUBSTR }
        CHAR_LENGTH - CHARACTER_LENGTH { set name LENGTH }
        INSTR { set name POSITION ; set words [list [lindex $words 1] [lindex $words 0]] }
        TRIM { set name [expr {$n == 2 ? "TRIM_" : "TRIM_"}]
               set words [list both [expr {$n == 2 ? [lindex $words 1] : [list { }]}] [lindex $words 0]] }
    }
    # numeric functions: coerce text arguments
    if {$name in {ABS SIGN CEIL FLOOR ROUND TRUNC SQRT POWER EXP LN LOG10 SIN COS TAN ASIN ACOS ATAN ATAN2 DEGREES RADIANS CHR LEFT RIGHT REPEAT LPAD RPAD}} {
        set i 0 ; set nw {}
        foreach c $cargs w $words {
            # LEFT/RIGHT/REPEAT/LPAD/RPAD: only the numeric arguments are coerced
            set coerce [expr {$name in {LEFT RIGHT REPEAT LPAD RPAD} ? ($i == 1) : 1}]
            if {$name in {LPAD RPAD} && $i == 2} { set coerce 0 }
            if {$coerce && [lindex $c 1] eq "text"} { set w "\[::mkitsql::rt::num $w\]" }
            lappend nw $w ; incr i
        }
        set words $nw
    }
    return [list "\[::mkitsql::rt::fn_$name [join $words { }]\]" $rtype]
}

# ============================================================================
#  Turning a word into a proc
# ============================================================================
# Compile `node` (a bound expression) into a proc taking {r0 outer}.
# Returns {procName type}.
proc ::mkitsql::compileExpr {node ctx} {
    variable cxCount
    lassign [cg $node $ctx] w t
    set name ::mkitsql::cx::p[incr cxCount]
    set body "return $w"
    verifyCode $body
    proc $name {r0 outer} $body
    return [list $name $t]
}
# Compile a condition (WHERE / HAVING / ON): must be boolean or numeric.
proc ::mkitsql::compileCond {node ctx} {
    variable cxCount
    set wt [cg $node $ctx]
    if {[lindex $wt 1] in {text blob datetime interval}} {
        fail "A condition (WHERE, HAVING, ON) must be true/false or a number, not [lindex $wt 1]"
    }
    set w [asBool $wt condition]
    set name ::mkitsql::cx::p[incr cxCount]
    set body "return $w"
    verifyCode $body
    proc $name {r0 outer} $body
    return [list $name bool]
}
# Compile a list of expressions into one proc returning a list of their values.
proc ::mkitsql::compileList {nodes ctx} {
    variable cxCount
    set words {} ; set types {}
    foreach n $nodes {
        lassign [cg $n $ctx] w t
        lappend words $w ; lappend types $t
    }
    set name ::mkitsql::cx::p[incr cxCount]
    set body "list [join $words { }]"
    if {$::mkitsql::listBug} { set body "::mkitsql::rt::sk \[$body\]" }
    verifyCode $body
    proc $name {r0 outer} $body
    return [list $name $types]
}

# ---- keeping the NULL marker out of every value --------------------------------------
# Text that comes from a database file (cell values, table and column names) is the only data the
# engine did not receive through the SQL text or a parameter; it goes through here.  A file can
# contain anything, so the marker character is replaced by U+FFFD (and counted: a statement that
# read such a value refuses to WRITE, so the replacement can never be saved back by accident).
proc ::mkitsql::cleanText {s} {
    variable M ; variable R ; variable sanitized
    if {[string first $M $s] < 0} { return $s }
    incr sanitized
    return [string map [list $M $::mkitsql::R] $s]
}
# a list of rows (lists of cells); the fast path is one scan of the whole chunk
proc ::mkitsql::cleanRows {rows} {
    variable M ; variable R ; variable sanitized
    incr sanitized
    set out {}
    foreach r $rows {
        set r2 {}
        foreach v $r { lappend r2 [string map [list $M $::mkitsql::R] $v] }
        lappend out $r2
    }
    return $out
}
# Called right before a statement writes: it must not have read a cleaned value.
proc ::mkitsql::assertClean {} {
    variable sanitized
    if {$sanitized} {
        fail "Refusing to write: this statement read a text value that contains U+FDD0 (a reserved character the engine uses for NULL), shown as U+FFFD. Rewrite those values first (UPDATE ... SET col = 'x' WHERE ...)."
    }
}
