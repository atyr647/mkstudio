# stmt.tcl -- statement execution for mkit-sql: SELECT result shaping, INSERT,
# UPDATE, DELETE, CREATE / DROP / ALTER TABLE, transactions and the small
# administrative statements MK Studio relies on (USE, SHOW, DESCRIBE).
#
# execStatement ast ?defaultDb? ?params?  returns one of
#   {kind rowset cols .. types .. rows .. rowids .. source .. drill .. truncated 0|1 editable 0|1}
#   {kind message text .. affected N ?use db?}
#
# Writes are all-or-nothing per statement: every value is validated and
# converted *before* anything is written to Metakit.

namespace eval ::mkitsql {
    variable nullText "NULL"     ;# how NULL is shown in result grids
    variable streamCb ""         ;# set while ::mkitsql::stream runs
    variable autocommit 0        ;# 1 = commit after every successful write statement
    variable busy 0              ;# 1 while a statement runs (statements cannot be nested)
    variable session ""          ;# who is running the statement ("" = a single user, no transaction ownership)
    variable poisoned            ;# database tag -> 1 after a statement failed halfway with earlier changes pending (only ROLLBACK is accepted)
    array set poisoned {}
    variable txnOwner            ;# database tag -> the session whose uncommitted changes it holds
    array set txnOwner {}
    variable intMin -2147483648
    variable intMax 2147483647
}

# ============================================================================
#  Entry point
# ============================================================================
proc ::mkitsql::resetStatement {} {
    variable plans ; variable subCache ; variable planCorr ; variable needed ; variable derivedBq ; variable bindCount ; variable planMemo ; variable memo ; variable memoCount ; variable memoUsed ; variable volatileSeen
    set bindCount 0
    variable scopes ; variable ctes ; variable refLog ; variable fromSoFar ; variable lookupIdx ; variable scanCache ; variable scanRuns
    foreach p [info procs ::mkitsql::cx::*] { rename $p {} }
    array unset lookupIdx ; array set lookupIdx {} ; array unset scanCache ; array set scanCache {} ; array unset scanRuns ; array set scanRuns {}
    array unset derivedBq ; array set derivedBq {} ; array unset plans ; array unset subCache ; array unset planCorr ; array unset needed ; array unset planMemo ; array unset memo
    array set plans {} ; array set subCache {} ; array set planCorr {} ; array set needed {} ; array set planMemo {} ; array set memo {} ; set memoCount 0 ; set memoUsed 0 ; set volatileSeen 0
    set scopes {} ; set ctes {} ; set refLog {} ; set fromSoFar {}
}

# Tcl's own arithmetic errors, in the words of the engine ("" = not one of them)
proc ::mkitsql::dataError {msg code} {
    switch -glob -- $code {
        {ARITH DIVZERO*}   { return "Division by zero" }
        {ARITH IOVERFLOW*} - {ARITH OVERFLOW*} { return "A number went out of range during the calculation (overflow)" }
        {ARITH DOMAIN*}    { return "A function was given a number outside its valid range" }
        {TCL VALUE NUMBER*} { return "A value used in a calculation is not a number" }
    }
    return ""
}

proc ::mkitsql::execStatement {ast {db ""} {plist {}} {nulls {}}} {
    variable busy
    # A statement keeps its compiled plans and operator state in this namespace, so a second statement
    # started from inside the first (a stream callback, a progress hook) would corrupt it: refuse.
    if {$busy} { fail "A statement cannot be run while another one is running (for example from a stream callback or progress hook); run it after the first has finished" }
    set busy 1
    set rc [catch {execStatement1 $ast $db $plist $nulls} res opts]
    set busy 0
    # errors raised by the storage layer (MKIT ...) are reported as ordinary engine errors, keeping the detail
    if {$rc && [lindex [dict get $opts -errorcode] 0] eq "MKIT"} {
        dict set opts -errorcode [concat {MKQL ERROR} [dict get $opts -errorcode]]
    } elseif {$rc && [lindex [dict get $opts -errorcode] 0] ne "MKQL" && [set clean [dataError $res [dict get $opts -errorcode]]] ne ""} {
        # arithmetic on the data went out of range (overflow, domain, a value that is not a number): an ordinary data error
        dict set opts -errorcode [list MKQL ERROR DATA]
        set res $clean
    } elseif {$rc && [lindex [dict get $opts -errorcode] 0] ne "MKQL"} {
        # a Tcl error from inside the engine (arithmetic overflow, a value no function expected ...): still an ordinary
        # error to the caller - never a stack trace - but tagged RUNTIME so the fuzzer and the tests can see it
        dict set opts -errorcode [concat {MKQL ERROR RUNTIME} [dict get $opts -errorcode]]
    }
    spillCleanup
    if {$rc} {
        if {[string match "too many nested evaluations*" $res]} {
            fail "The statement is too deeply nested to run (too many subqueries or expressions inside each other)"
        }
        return -options $opts $res
    }
    return $res
}

proc ::mkitsql::execStatement1 {ast db plist nulls} {
    variable defaultDb ; variable cancel ; variable capRows ; variable M ; variable N ; variable sanitized
    set savedParams $plist
    resetStatement
    set sanitized 0
    set defaultDb $db
    set cancel 0 ; set capRows 0
    # `?` parameters take a list, `:name` parameters a dict; the statement says which it uses
    set info [expr {[llength $ast] > 2 ? [lindex $ast 2] : [dict create pos 0 named {}]}]
    set pd [dict create]
    if {[llength [dict get $info named]]} {
        if {[llength $savedParams] % 2} { fail "Named parameters must be given as a dict of name value pairs" }
        set pd $savedParams
    } else {
        set i 0
        foreach v $savedParams { dict set pd [incr i] $v }
    }
    # Parameters are plain values.  NULL is passed out of band (the `nulls` argument: positions for
    # `?`, names for `:name`), never as a magic string, so no text a user types can become NULL.
    dict for {k v} $pd {
        if {[string first $M $v] >= 0} { fail "Parameter [expr {[string is integer -strict $k] ? "#$k" : ":$k"}] contains U+FDD0, a character the engine reserves for NULL (pass NULL with the 'nulls' argument)" }
    }
    foreach k $nulls {
        if {![dict exists $pd $k]} { fail "NULL was requested for parameter '$k', which the statement does not have" }
        dict set pd $k $N
    }
    set ::mkitsql::params $pd
    switch -- [lindex $ast 0] {
        select   { return [execSelect [lindex $ast 1]] }
        explain  { return [execExplain [lindex $ast 1]] }
        insert   { return [writeStmt execInsert [lindex $ast 1]] }
        insertrows { return [writeStmt execInsertRows [lindex $ast 1]] }
        update   { return [writeStmt execUpdate [lindex $ast 1]] }
        delete   { return [writeStmt execDelete [lindex $ast 1]] }
        merge    { return [writeStmt execMerge [lindex $ast 1]] }
        create   { return [writeStmt execCreate [lindex $ast 1]] }
        drop     { return [writeStmt execDrop [lindex $ast 1]] }
        alter    { return [writeStmt execAlter [lindex $ast 1]] }
        begin    { return [msg "Transaction started.  Changes stay in memory until COMMIT." 0] }
        commit   { return [execTxn commit [lindex $ast 1]] }
        rollback { return [execTxn rollback [lindex $ast 1]] }
        use {
            set d [findTag [lindex $ast 1]]
            if {$d eq ""} { fail "Unknown database '[lindex $ast 1]'. Open databases: [join [::mkitsql::db::tags] {, }]" }
            return [dict create kind message text "Now using database '$d'." use $d affected -1]
        }
        showdbs   { return [execShowDbs] }
        showtables { return [execShowTables [lindex $ast 1]] }
        describe  { return [execDescribe [lindex $ast 1]] }
    }
    error "execStatement: unknown statement [lindex $ast 0]"
}

# A statement that changes data.  If it fails AFTER it already changed something (a Metakit error or a full disk while the rows
# were being applied) the file would be left half changed: when the statement was the first change of the transaction it is
# rolled back, so the error leaves the database as it was; when earlier uncommitted work is in the same transaction the one
# statement cannot be undone on its own, so the transaction is marked failed and only ROLLBACK is accepted (no COMMIT of a
# half-applied statement).
proc ::mkitsql::writeStmt {proc arg} {
    variable poisoned
    set before [dict create]
    foreach t [::mkitsql::db::tags] { dict set before $t [::mkitsql::db::dirty $t] }
    set rc [catch {$proc $arg} res opts]
    if {$rc} {
        dict for {t d0} $before {
            if {[catch {::mkitsql::db::dirty $t} d1] || $d1 <= $d0} continue
            if {$d0 == 0} {
                if {![catch {::mkitsql::db::rollback $t}]} {
                    append res "\n(The statement had already changed data in '$t' when it failed; those changes were rolled back.)"
                } else {
                    set poisoned($t) 1
                    append res "\n(The statement failed halfway through changing '$t' and could not be undone: run ROLLBACK.)"
                }
            } else {
                set poisoned($t) 1
                append res "\n(The statement failed halfway through changing '$t', and earlier uncommitted changes are pending, so it cannot be undone on its own: the transaction is marked failed - run ROLLBACK.)"
            }
        }
        releaseIdleClaims
        return -options $opts $res
    }
    return [afterWrite $res]
}
# a session that claimed a database but changed nothing (the statement failed or changed no rows) does not own a transaction
proc ::mkitsql::releaseIdleClaims {} {
    variable txnOwner
    foreach t [array names txnOwner] { if {[catch {::mkitsql::db::dirty $t} d] || $d == 0} { unset -nocomplain txnOwner($t) } }
}

proc ::mkitsql::msg {text {affected -1}} {
    dict create kind message text $text affected $affected
}

# Writing needs a read/write handle and - when sessions are used - no uncommitted changes of another session.
# Sessions are for a server that shares one database between clients: set ::mkitsql::session to the client's
# id around each statement.  The first session to write owns the open transaction until it COMMITs or ROLLs BACK;
# others get a clear error instead of silently joining it (reads are not blocked: they see uncommitted data).
proc ::mkitsql::assertWritable {tag} {
    variable session ; variable txnOwner
    if {[::mkitsql::db::readonly $tag]} {
        set by [::mkitsql::db::lockedBy $tag]
        if {$by ne ""} {
            fail "Database '$tag' is open read-only: process [lindex $by 0] on [lindex $by 1] has it open for editing (its write lock)."
        }
        fail "Database '$tag' is open read-only."
    }
    variable poisoned
    if {[::mkitsql::db::dirty $tag] == 0} { unset -nocomplain poisoned($tag) }
    if {[info exists poisoned($tag)]} {
        fail "A previous statement on '$tag' failed halfway through its changes, so nothing more can be written until you ROLLBACK."
    }
    if {$session ne "" && [info exists txnOwner($tag)] && $txnOwner($tag) ne $session && [::mkitsql::db::dirty $tag] > 0} {
        fail "Database '$tag' has uncommitted changes from another session ($txnOwner($tag)); wait until it commits or rolls back."
    }
    if {$session ne ""} {
        # a stale record (the transaction ended behind our back, e.g. through ::store::commit) is dropped; then this session claims the
        # transaction BEFORE it changes anything, so a statement that fails midway cannot leave changes nobody owns
        if {[::mkitsql::db::dirty $tag] == 0} { unset -nocomplain txnOwner($tag) }
        if {![info exists txnOwner($tag)]} { set txnOwner($tag) $session }
    }
}
proc ::mkitsql::afterWrite {res} {
    variable autocommit ; variable session ; variable txnOwner
    if {$autocommit && [dict exists $res tag]} {
        ::mkitsql::db::commit [dict get $res tag]
        dict set res text "[dict get $res text]  (committed)"
    }
    if {$session ne "" && [dict exists $res tag]} {
        set t [dict get $res tag]
        if {[::mkitsql::db::dirty $t] > 0 && ![info exists txnOwner($t)]} { set txnOwner($t) $session }
        if {[::mkitsql::db::dirty $t] == 0} { unset -nocomplain txnOwner($t) }
    }
    return $res
}

proc ::mkitsql::plural {n word} { return "$n $word[expr {$n == 1 ? {} : {s}}]" }

# ============================================================================
#  SELECT
# ============================================================================
proc ::mkitsql::execSelect {q} {
    variable maxRows ; variable nullText ; variable plans ; variable N ; variable S
    set bq [bindQuery $q]
    set id [compileQuery $bq {}]
    set p $plans($id)
    set kind [dict get $p kind]
    set plain [expr {$kind eq "select" && [dict get $p plain]}]
    set hasRid [expr {$kind eq "select" && [dict get $p curPos] >= 0}]
    set names [dict get $p names]
    # column types for the grid, and which columns need special display
    set types {} ; set drill [dict create] ; set ivCols {}
    set ci 0
    foreach t [dict get $p types] l [dict get $p letters] d [dict get $p drill] {
        if {$l ne ""} { lappend types $l } else { lappend types [letterOfType $t] }
        if {$plain && $d ne "0"} { dict set drill $ci $d }
        if {$t eq "interval"} { lappend ivCols $ci }
        incr ci
    }
    set c [newId]
    set S($c,rows) {} ; set S($c,ids) {} ; set S($c,n) 0 ; set S($c,trunc) 0
    variable streamCb
    if {$streamCb ne ""} {
        # ::mkitsql::stream: hand every chunk to the caller; nothing is kept
        lassign $streamCb cb nullValue
        set S($c,count) 0
        streamPlan $id {} [list ::mkitsql::streamSink $c $cb $nullValue $ivCols] 0
        set count $S($c,count) ; array unset S $c,*
        return [dict create kind rowset cols $names types $types rows {} rowids {} source "" drill {} \
            truncated 0 editable 0 count $count]
    }
    set cfg [list $hasRid $drill $ivCols $nullText $maxRows]
    streamPlan $id {} [list ::mkitsql::resultSink $c $cfg] 1
    set rows $S($c,rows) ; set ids $S($c,ids) ; set truncated $S($c,trunc)
    array unset S $c,*
    return [dict create kind rowset cols $names types $types rows $rows rowids $ids \
        source [expr {$plain ? [dict get $p source] : ""}] drill $drill truncated $truncated editable $plain]
}
proc ::mkitsql::streamSink {c cb nullValue ivCols chunk} {
    variable S ; variable N
    if {[llength $ivCols]} {
        set rows {}
        foreach r $chunk {
            foreach i $ivCols { set v [lindex $r $i] ; if {$v ne $N} { lset r $i [ivFormat $v] } }
            lappend rows $r
        }
        set chunk $rows
    }
    set out {}
    foreach r $chunk {
        if {[lsearch -exact $r $N] >= 0} {
            set r2 {}
            foreach v $r { if {$v eq $N} { lappend r2 $nullValue } else { lappend r2 $v } }
            set r $r2
        }
        lappend out [::mkitsql::rt::sk $r]
    }
    incr S($c,count) [llength $out]
    if {[{*}$cb $out] eq "1"} { return 1 }
    return 0
}
# collects display-ready rows, at most maxRows of them
proc ::mkitsql::resultSink {c cfg chunk} {
    variable S ; variable N
    lassign $cfg hasRid drill ivCols nullText maxRows
    set hasDrill [dict size $drill]
    foreach el $chunk {
        if {$S($c,n) >= $maxRows} { set S($c,trunc) 1 ; return 1 }
        if {$hasRid} { set r [lindex $el 0] ; lappend S($c,ids) [lindex $el 1] } else { set r $el }
        if {[llength $ivCols]} {
            foreach i $ivCols { set v [lindex $r $i] ; if {$v ne $N} { lset r $i [ivFormat $v] } }
        }
        if {[lsearch -exact $r $N] >= 0} {
            set r2 {}
            foreach v $r { if {$v eq $N} { lappend r2 $nullText } else { lappend r2 $v } }
            set r $r2
        }
        if {$hasDrill} {
            dict for {i sub} $drill {
                set n [lindex $r $i]
                lset r $i "\u25B8 $n row[expr {$n == 1 ? {} : {s}}]"
            }
        }
        lappend S($c,rows) [::mkitsql::rt::sk $r]
        incr S($c,n)
    }
    return 0
}

# ============================================================================
#  Targets and value conversion
# ============================================================================
# Resolve the target of INSERT / UPDATE / DELETE / ALTER.  Returns
# {tag view path layout label}.
proc ::mkitsql::resolveTarget {parts subs} {
    lassign [resolveTable $parts] tag view
    assertWritable $tag
    set path $tag.$view
    set layout [::mkitsql::db::layout $path]
    set label $view
    if {[llength $subs]} { lassign [walkSubs $path $layout $label $subs] path layout label }
    return [list $tag $view $path $layout $label]
}

proc ::mkitsql::findLayoutCol {layout name} {
    foreach c $layout { if {[string equal -nocase [lindex $c 0] $name]} { return $c } }
    return ""
}

proc ::mkitsql::letterWords {l} {
    switch -- $l {
        S { return "text" } I { return "whole numbers (INTEGER)" } L { return "whole numbers (BIGINT)" }
        F - D { return "numbers" } B { return "binary data" }
    }
    return $l
}

# Convert a computed value for storage in a column of type `letter`.
proc ::mkitsql::coerceValue {col letter v} {
    variable N ; variable intMin ; variable intMax
    if {$v eq $N} { return [expr {$letter in {I L F D} ? 0 : ""}] }
    switch -- $letter {
        I - L {
            set x [string trim $v]
            if {[regexp {^[-+]?\d+$} $x]} {
                regsub {^([-+]?)0+(?=\d)} $x {\1} x
                set x [expr {$x + 0}]
            } elseif {[regexp {^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$} $x]} {
                set d [expr {double($x)}]
                if {$d == Inf || $d == -Inf || $d >= 9.3e18 || $d <= -9.3e18} { fail "Value '[string range $v 0 40]' is out of range for the whole-number column '$col'" }
                if {$d != double(entier($d))} { fail "Column '$col' holds [letterWords $letter], but '[string range $v 0 40]' is not a whole number" }
                set x [expr {entier($d)}]
            } else {
                fail "Column '$col' holds [letterWords $letter], but '[string range $v 0 40]' is not a whole number"
            }
            if {$letter eq "I" && ($x < $intMin || $x > $intMax)} {
                fail "Value $x is out of range for 32-bit INTEGER column '$col' (use BIGINT for larger numbers)"
            }
            if {$letter eq "L" && !($x >= -9223372036854775808 && $x <= 9223372036854775807)} {
                fail "Value $x is out of range for BIGINT column '$col'"
            }
            return $x
        }
        F - D {
            set x [string trim $v]
            if {![regexp {^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$} $x]} {
                fail "Column '$col' holds numbers, but '[string range $v 0 40]' is not one"
            }
            regsub {^([-+]?)0+(?=\d)} $x {\1} x
            set d [expr {double($x)}]
            if {$d == Inf || $d == -Inf} { fail "Value '[string range $v 0 40]' is out of range for the numeric column '$col'" }
            # a REAL column is single precision: beyond about 3.4e38 it would be stored as infinity
            if {$letter eq "F" && ($d > 3.4028234663852886e38 || $d < -3.4028234663852886e38)} {
                fail "Value '[string range $v 0 40]' is out of range for the single-precision (REAL) column '$col'; use DOUBLE PRECISION"
            }
            if {[string index $x 0] eq "-" && $x == 0} { set x 0.0 }       ;# no negative zero
            return $x
        }
    }
    # an interval stored into a text column keeps its readable form
    if {[isIv $v]} { return [ivFormat $v] }
    return $v
}

# ============================================================================
#  INSERT
# ============================================================================
proc ::mkitsql::execInsert {st} {
    variable plans ; variable N
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set cols [dict get $st cols]
    if {![llength $cols]} {
        set cols {}
        foreach c $layout { if {[lindex $c 1] ne "V"} { lappend cols [lindex $c 0] } }
    }
    set targets {}                 ;# {name letter}
    set seen {}
    foreach c $cols {
        set lc [findLayoutCol $layout $c]
        if {$lc eq ""} { fail "Unknown column '$c' in '$label'.  Available: [join [lmap2 $layout {x {lindex $x 0}}] {, }]" }
        if {[lindex $lc 1] eq "V"} { fail "'$c' is a subview; insert into it with  INSERT INTO $label\[row\].$c ..." }
        if {[lsearch -exact $seen [string tolower $c]] >= 0} { fail "Column '$c' is listed twice" }
        lappend seen [string tolower $c]
        lappend targets [list [lindex $lc 0] [lindex $lc 1]]
    }
    set src [dict get $st source]
    # validate and convert everything first, into a spool (memory stays bounded; it spills to disk)
    set conv [list ::mkitsql::convInsert $targets]
    set sp [spoolNew]
    if {[dict get $src type] eq "defaults"} {
        set rows [list [::mkitsql::rep [llength $targets] $N]]
        if {[llength $cols] == 0} { set rows [list {}] }
        convSink $sp $conv $rows
    } else {
        set bq [bindQuery $src]
        set id [compileQuery $bq {}]
        set w [llength [dict get $bq outNames]]
        if {$w != [llength $targets]} {
            fail "INSERT has [llength $targets] target column[expr {[llength $targets] == 1 ? {} : {s}}] but the source provides $w value[expr {$w == 1 ? {} : {s}}]"
        }
        streamPlan $id {} [list ::mkitsql::convSink $sp $conv]
    }
    set props {} ; foreach t $targets { lappend props [lindex $t 0] }
    assertClean
    spoolEach $sp [list ::mkitsql::applyInsert $path $props]
    set n [spoolCount $sp]
    spoolFree $sp
    return [dict create kind message text "[plural $n row] inserted into '$label'." affected $n tag $tag]
}

# INSERT of rows that are already Tcl values (::mkitsql::insertRows): no SQL text to parse or bind, the same checks and conversions as INSERT.
proc ::mkitsql::execInsertRows {st} {
    variable N ; variable M
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set cols [dict get $st cols]
    if {![llength $cols]} { foreach c $layout { if {[lindex $c 1] ne "V"} { lappend cols [lindex $c 0] } } }
    set targets {} ; set seen {}
    foreach c $cols {
        set lc [findLayoutCol $layout $c]
        if {$lc eq ""} { fail "Unknown column '$c' in '$label'.  Available: [join [lmap2 $layout {x {lindex $x 0}}] {, }]" }
        if {[lindex $lc 1] eq "V"} { fail "'$c' is a subview; insert into it with  INSERT INTO $label\[row\].$c ..." }
        if {[lsearch -exact $seen [string tolower $c]] >= 0} { fail "Column '$c' is listed twice" }
        lappend seen [string tolower $c]
        lappend targets [list [lindex $lc 0] [lindex $lc 1]]
    }
    set w [llength $targets]
    set nullToken [dict get $st nullToken] ; set useNull [dict get $st useNull]
    set conv [list ::mkitsql::convInsert $targets]
    set sp [spoolNew]
    set chunk {} ; set n 0
    foreach r [dict get $st rows] {
        incr n
        if {[llength $r] != $w} { fail "Row $n has [llength $r] value[expr {[llength $r] == 1 ? {} : {s}}] but there are $w column[expr {$w == 1 ? {} : {s}}]" }
        if {[string first $M [join $r ,]] >= 0} { fail "Row $n contains U+FDD0, a character the engine reserves for NULL" }
        if {$useNull} {
            set r2 {}
            foreach v $r { lappend r2 [expr {$v eq $nullToken ? $N : $v}] }
            set r $r2
        }
        lappend chunk $r
        if {[llength $chunk] >= 2000} { convSink $sp $conv $chunk ; set chunk {} }
    }
    if {[llength $chunk]} { convSink $sp $conv $chunk }
    set props {} ; foreach t $targets { lappend props [lindex $t 0] }
    assertClean
    spoolEach $sp [list ::mkitsql::applyInsert $path $props]
    set cnt [spoolCount $sp]
    spoolFree $sp
    return [dict create kind message text "[plural $cnt row] inserted into '$label'." affected $cnt tag $tag]
}

# ---- statements that change data: convert first (into a spool), apply afterwards ------------------
proc ::mkitsql::convSink {sp conv chunk} {
    set out {}
    foreach r $chunk { lappend out [{*}$conv $r] }
    spoolAdd $sp $out
    return 0
}
proc ::mkitsql::convInsert {targets r} {
    set vals {}
    foreach t $targets v $r { lappend vals [coerceValue [lindex $t 0] [lindex $t 1] $v] }
    return [::mkitsql::rt::sk $vals]
}
proc ::mkitsql::convUpdate {targets r} {
    set vals {} ; set i 0
    foreach t $targets {
        lappend vals [coerceValue [lindex $t 0] [lindex $t 1] [lindex $r $i]]
        incr i
    }
    return [list [lindex $r end] [::mkitsql::rt::sk $vals]]
}
proc ::mkitsql::applyUpdate {path targets chunk} {
    foreach pr $chunk {
        lassign $pr rid vals
        foreach t $targets v $vals { ::mkitsql::db::setCell $path $rid [lindex $t 0] $v }
    }
    return 0
}
proc ::mkitsql::applyInsert {path props chunk} {
    foreach vals $chunk { ::mkitsql::db::appendRow $path $props $vals }
    return 0
}

# ---- bulk writes -----------------------------------------------------------------------------------
# Metakit shifts every later row for each row removed, and every later string for each string whose
# length changes, so scattered deletes and string updates over many rows are QUADRATIC (200,000 rows:
# tens of seconds).  Past `bulkMin` such changes the view is rebuilt instead - copied row by row into a
# scratch view with the changes applied, emptied, and copied back - which is linear.
namespace eval ::mkitsql { variable bulkMin 20000 }

# delete the rows with the given indices
proc ::mkitsql::deleteRowsSmart {path layout idx} {
    variable bulkMin
    set idx [lsort -integer -unique $idx]
    if {![llength $idx]} return
    # how many contiguous runs?  (counted first, so a huge scattered delete never builds the run list)
    set nruns 0 ; set prev -2
    foreach i $idx {
        if {$i != $prev + 1} { incr nruns }
        set prev $i
    }
    if {$nruns >= $bulkMin} {
        rewriteView $path $layout $idx "" {}
        return
    }
    set runs {} ; set start [lindex $idx 0] ; set cnt 0 ; set prev [expr {$start - 2}]
    foreach i $idx {
        if {$i == $prev + 1} { incr cnt } else {
            if {$cnt} { lappend runs [list $start $cnt] }
            set start $i ; set cnt 1
        }
        set prev $i
    }
    lappend runs [list $start $cnt]
    for {set k [expr {[llength $runs] - 1}]} {$k >= 0} {incr k -1} {
        lassign [lindex $runs $k] first n
        ::mkitsql::db::deleteRange $path $first $n
    }
}

# Rebuild view `path`: rows in `deletes` (ascending) are dropped; for the rows in the spool `updates`
# ({rowid values} per record, targets = {{column letter}...}) those columns are replaced.
proc ::mkitsql::rewriteView {path layout deletes updates targets} {
    set tag [lindex [split $path .] 0]
    set tmpName __mkitsql_tmp_[newId]
    set tmp $tag.$tmpName
    ::mkitsql::db::createView $tag $tmpName $layout
    # Phase 1 builds the new contents in the scratch view; the table itself is untouched.  If it fails the
    # scratch view is dropped and the error is passed on - nothing has changed.
    if {[catch {rewriteBuild $path $layout $tmp $deletes $updates $targets} msg opts]} {
        catch {::mkitsql::db::dropView $tag $tmpName}
        return -options $opts $msg
    }
    # Phase 2 swaps it in.  A failure here leaves the new contents in the scratch view, so it is kept
    # (ROLLBACK restores the table) and named in the message.
    if {[catch {
        ::mkitsql::db::clearView $path
        copyRows $tmp $path $layout
        ::mkitsql::db::dropView $tag $tmpName
    } msg opts]} {
        return -options $opts "$msg  (the table was being rebuilt: ROLLBACK restores it; the new contents are in the scratch table '$tmpName')"
    }
}
proc ::mkitsql::rewriteBuild {path layout tmp deletes updates targets} {
    set props {} ; set subs {}
    foreach c $layout { if {[lindex $c 1] eq "V"} { lappend subs $c } else { lappend props [lindex $c 0] } }
    set tpos {}
    foreach t $targets { lappend tpos [lsearch -exact $props [lindex $t 0]] }
    set n [::mkitsql::db::size $path]
    set sr "" ; set rd "" ; set g {}
    if {$updates ne ""} {
        set sr [sorterNew {{key 0 asc "" int}}]
        spoolEach $updates [list ::mkitsql::rewriteSortSink $sr]
        set rd [sorterReader $sr] ; set g [readerGroup $rd]
    }
    set di 0 ; set nd [llength $deletes]
    for {set first 0} {$first < $n} {incr first 2000} {
        set rid $first
        foreach vals [::mkitsql::db::rows $path $props $first 2000] {
            if {$di < $nd && [lindex $deletes $di] == $rid} {
                incr di ; incr rid ; continue
            }
            if {[llength $g] && [lindex $g 0] == $rid} {
                foreach p $tpos v [lindex $g 1 0 1 1] { lset vals $p $v }
                set g [readerGroup $rd]
            }
            set j [::mkitsql::db::appendRow $tmp $props $vals]
            foreach sc $subs { copyRows $path!$rid.[lindex $sc 0] $tmp!$j.[lindex $sc 0] [lindex $sc 2] }
            incr rid
        }
    }
    if {$rd ne ""} { readerFree $rd }
    if {$sr ne ""} { sorterFree $sr }
}
proc ::mkitsql::rewriteSortSink {sr chunk} {
    set recs {}
    foreach r $chunk { lappend recs [list [lindex $r 0] $r] }
    sorterAdd $sr $recs
    return 0
}

proc ::mkitsql::ridSink {c chunk} {
    variable S
    foreach r $chunk { lappend S($c,ids) [lindex $r 0] }
    return 0
}

# tiny map helper (Tcl 8.5 has no lmap)
proc ::mkitsql::lmap2 {list spec} {
    lassign $spec var body
    set out {}
    foreach item $list { lappend out [apply [list $var $body] $item] }
    return $out
}

# ============================================================================
#  UPDATE / DELETE  (run as a synthetic SELECT that also returns _rowid)
# ============================================================================
proc ::mkitsql::syntheticSelect {st items} {
    set sel [dict create type select distinct 0 items $items \
        from [list table [dict get $st parts] [dict get $st subs] [dict get $st alias]] \
        where [dict get $st where] group {} having {}]
    return [dict create type query with {} body $sel order {} limit {} offset {}]
}

proc ::mkitsql::execUpdate {st} {
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set sets [dict get $st sets]
    set items {} ; set targets {} ; set seen {}
    foreach s $sets {
        lassign $s c e
        set lc [findLayoutCol $layout $c]
        if {$lc eq ""} { fail "Unknown column '$c' in '$label'.  Available: [join [lmap2 $layout {x {lindex $x 0}}] {, }]" }
        if {[lindex $lc 1] eq "V"} { fail "'$c' is a subview and cannot be assigned" }
        if {[lsearch -exact $seen [string tolower $c]] >= 0} { fail "Column '$c' is assigned twice" }
        lappend seen [string tolower $c]
        lappend targets [list [lindex $lc 0] [lindex $lc 1]]
        lappend items [list $e {} $c]
    }
    lappend items [list {col {} _rowid} {} _rowid]
    set bq [bindQuery [syntheticSelect $st $items]]
    set id [compileQuery $bq {}]
    # convert all new values before touching the file (into a spool: bounded memory)
    set sp [spoolNew]
    streamPlan $id {} [list ::mkitsql::convSink $sp [list ::mkitsql::convUpdate $targets]]
    assertClean
    variable bulkMin
    set varLen 0
    foreach t $targets { if {[lindex $t 1] in {S B}} { set varLen 1 } }
    if {$varLen && [spoolCount $sp] >= $bulkMin} {
        rewriteView $path $layout {} $sp $targets
    } else {
        spoolEach $sp [list ::mkitsql::applyUpdate $path $targets]
    }
    set n [spoolCount $sp]
    spoolFree $sp
    return [dict create kind message text "[plural $n row] updated in '$label'." affected $n tag $tag]
}

proc ::mkitsql::execDelete {st} {
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set items [list [list {col {} _rowid} {} _rowid]]
    set bq [bindQuery [syntheticSelect $st $items]]
    set id [compileQuery $bq {}]
    # only the row ids are kept (not the rows)
    variable S
    set rc [newId]
    set S($rc,ids) {}
    streamPlan $id {} [list ::mkitsql::ridSink $rc]
    set idx $S($rc,ids)
    array unset S $rc,*
    assertClean
    deleteRowsSmart $path $layout $idx
    set n [llength $idx]
    return [dict create kind message text "[plural $n row] deleted from '$label'." affected $n tag $tag]
}

# ============================================================================
#  MERGE   (matching is done by the ON condition, so no keys are needed)
# ============================================================================
# The statement runs as one SELECT  source LEFT JOIN target  that also computes every
# WHEN condition and every SET / VALUES expression; the file is only touched afterwards.
proc ::mkitsql::execMerge {st} {
    variable N
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set parts [dict get $st parts]
    set talias [dict get $st alias]
    if {$talias eq ""} {
        if {[llength [dict get $st subs]]} { set talias [lindex [dict get $st subs] end 1] } else { set talias [lindex $parts end] }
    }
    set items [list [list [list col $talias _rowid] {} _rowid]]
    set plan {}                       ;# per clause: {kind condIdx action ...}
    foreach cl [dict get $st clauses] {
        lassign $cl kind cond act
        set ci [llength $items]
        lappend items [list [expr {$cond eq "" ? {lit bool 1} : $cond}] {} cond]
        switch -- [lindex $act 0] {
            delete { lappend plan [list $kind $ci delete] }
            update {
                set targets {} ; set first [llength $items] ; set seen {}
                foreach sc [lindex $act 1] {
                    lassign $sc c e
                    set lc [findLayoutCol $layout $c]
                    if {$lc eq ""} { fail "Unknown column '$c' in '$label'" }
                    if {[lindex $lc 1] eq "V"} { fail "'$c' is a subview and cannot be assigned" }
                    if {[lsearch -exact $seen [string tolower $c]] >= 0} { fail "Column '$c' is assigned twice" }
                    lappend seen [string tolower $c]
                    lappend targets [list [lindex $lc 0] [lindex $lc 1]]
                    lappend items [list $e {} $c]
                }
                lappend plan [list $kind $ci update $first $targets]
            }
            insert {
                lassign [lrange $act 1 2] cols vals
                if {![llength $cols]} {
                    foreach c $layout { if {[lindex $c 1] ne "V"} { lappend cols [lindex $c 0] } }
                }
                if {[llength $cols] != [llength $vals]} {
                    fail "MERGE ... INSERT has [llength $cols] column[expr {[llength $cols] == 1 ? {} : {s}}] but [llength $vals] value[expr {[llength $vals] == 1 ? {} : {s}}]"
                }
                set targets {} ; set first [llength $items]
                foreach c $cols e $vals {
                    set lc [findLayoutCol $layout $c]
                    if {$lc eq ""} { fail "Unknown column '$c' in '$label'" }
                    if {[lindex $lc 1] eq "V"} { fail "'$c' is a subview" }
                    lappend targets [list [lindex $lc 0] [lindex $lc 1]]
                    lappend items [list $e {} $c]
                }
                lappend plan [list $kind $ci insert $first $targets]
            }
        }
    }
    set from [list join left [dict get $st source] [list table $parts [dict get $st subs] $talias] [dict get $st on] {}]
    set sel [dict create type select distinct 0 items $items from $from where {} group {} having {} windows [dict create]]
    set q [dict create type query with {} body $sel order {} limit {} offset {}]
    set bq [bindQuery $q]
    set id [compileQuery $bq {}]
    # classify and convert every row first (updates and inserts go to spools, so memory stays bounded)
    variable S
    set mg [newId]
    set S($mg,sU) [spoolNew] ; set S($mg,sI) [spoolNew] ; set S($mg,del) {}
    set S($mg,touch) [sorterNew {{key 0 asc "" int}}]
    streamPlan $id {} [list ::mkitsql::mergeSink $mg $plan]
    # a target row may be changed once: the sorted list of touched row ids must have no repeats
    set r [sorterReader $S($mg,touch)]
    while {[llength [set g [readerGroup $r]]]} {
        if {[llength [lindex $g 1]] > 1} {
            readerFree $r
            fail "MERGE would change the same target row twice: the ON condition matches one target row with more than one source row"
        }
    }
    readerFree $r
    assertClean
    spoolEach $S($mg,sU) [list ::mkitsql::mergeApplyUpdate $path]
    set deletes $S($mg,del)
    deleteRowsSmart $path $layout $deletes
    spoolEach $S($mg,sI) [list ::mkitsql::mergeApplyInsert $path]
    set nu [spoolCount $S($mg,sU)] ; set nd [llength $deletes] ; set ni [spoolCount $S($mg,sI)]
    spoolFree $S($mg,sU) ; spoolFree $S($mg,sI) ; sorterFree $S($mg,touch)
    array unset S $mg,*
    return [dict create kind message affected [expr {$nu + $nd + $ni}] tag $tag \
        text "MERGE into '$label': $nu updated, $nd deleted, $ni inserted."]
}
proc ::mkitsql::mergeSink {mg plan chunk} {
    variable S ; variable N
    set ups {} ; set ins {} ; set touched {}
    foreach r $chunk {
        set rid [lindex $r 0]
        set matched [expr {$rid ne $N}]
        foreach cl $plan {
            lassign $cl kind ci action
            if {($kind eq "matched") != $matched} continue
            if {[lindex $r $ci] ne "1"} continue
            switch -- $action {
                delete - update {
                    lappend touched [list $rid]
                    if {$action eq "delete"} {
                        lappend S($mg,del) $rid
                    } else {
                        set vals {} ; set k [lindex $cl 3]
                        foreach t [lindex $cl 4] { lappend vals [coerceValue [lindex $t 0] [lindex $t 1] [lindex $r $k]] ; incr k }
                        lappend ups [list $rid [lindex $cl 4] [::mkitsql::rt::sk $vals]]
                    }
                }
                insert {
                    set vals {} ; set props {} ; set k [lindex $cl 3]
                    foreach t [lindex $cl 4] { lappend props [lindex $t 0] ; lappend vals [coerceValue [lindex $t 0] [lindex $t 1] [lindex $r $k]] ; incr k }
                    lappend ins [::mkitsql::rt::sk [list [::mkitsql::rt::sk $props] [::mkitsql::rt::sk $vals]]]
                }
            }
            break
        }
    }
    if {[llength $touched]} { sorterAdd $S($mg,touch) $touched }
    if {[llength $ups]} { spoolAdd $S($mg,sU) $ups }
    if {[llength $ins]} { spoolAdd $S($mg,sI) $ins }
    return 0
}
proc ::mkitsql::mergeApplyUpdate {path chunk} {
    foreach u $chunk {
        lassign $u rid targets vals
        foreach t $targets v $vals { ::mkitsql::db::setCell $path $rid [lindex $t 0] $v }
    }
    return 0
}
proc ::mkitsql::mergeApplyInsert {path chunk} {
    foreach i $chunk { ::mkitsql::db::appendRow $path [lindex $i 0] [lindex $i 1] }
    return 0
}

# ============================================================================
#  DDL
# ============================================================================
# Where does a new table go?  Returns {tag name}.
proc ::mkitsql::newTableName {parts} {
    variable defaultDb
    set tags [::mkitsql::db::tags]
    if {![llength $tags]} { fail "No database is open." }
    if {[llength $parts] == 2} {
        set tag [findTag [lindex $parts 0]]
        if {$tag eq ""} { fail "Unknown database '[lindex $parts 0]'. Open databases: [join $tags {, }]" }
        return [list $tag [lindex $parts 1]]
    }
    if {$defaultDb ne "" && [findTag $defaultDb] ne ""} { return [list [findTag $defaultDb] [lindex $parts 0]] }
    if {[llength $tags] == 1} { return [list [lindex $tags 0] [lindex $parts 0]] }
    fail "Several databases are open ([join $tags {, }]).  Qualify the name, e.g. [lindex $tags 0].[lindex $parts 0]"
}

# Metakit names live in layout strings, so they cannot contain spaces or punctuation.
proc ::mkitsql::checkName {name what} {
    if {![regexp {^[[:alpha:]_][[:alnum:]_]*$} $name]} {
        fail "$what name '$name' is not allowed: Metakit names may only contain letters, digits and underscores, and cannot start with a digit"
    }
    # the engine and MK Studio use names starting with __mks for scratch views and columns they create and delete themselves
    if {[string match -nocase {__mks*} $name]} {
        fail "$what name '$name' is not allowed: names starting with __mks are reserved for temporary objects"
    }
}

# parser column definitions -> Metakit layout
proc ::mkitsql::defsToLayout {defs} {
    set layout {} ; set seen {}
    foreach d $defs {
        lassign $d name ty sub
        checkName $name Column
        if {[lsearch -exact $seen [string tolower $name]] >= 0} { fail "Column '$name' is defined twice" }
        lappend seen [string tolower $name]
        if {$ty eq "subview"} {
            lappend layout [list $name V [defsToLayout $sub]]
        } elseif {$ty eq "interval"} {
            fail "INTERVAL columns are not supported; store the length as a number of seconds or as text"
        } else {
            lappend layout [list $name [lindex [sqlType $ty] 0] {}]
        }
    }
    return $layout
}

proc ::mkitsql::execCreate {st} {
    lassign [newTableName [dict get $st parts]] tag name
    assertWritable $tag
    checkName $name Table
    if {[findView $tag $name] ne ""} {
        if {[dict get $st ifnotexists]} { return [dict create kind message text "Table '$name' already exists in '$tag'; nothing to do." affected 0 tag $tag] }
        fail "Table '$name' already exists in '$tag'."
    }
    if {[dict exists $st query]} { return [createTableAs $tag $name [dict get $st query]] }
    ::mkitsql::db::createView $tag $name [defsToLayout [dict get $st cols]]
    return [dict create kind message text "Table '$name' created in '$tag'." affected 0 tag $tag]
}

# CREATE TABLE name AS <query>:  column types come from the query's static types.
proc ::mkitsql::createTableAs {tag name q} {
    variable plans ; variable N ; variable S
    set bq [bindQuery $q]
    set id [compileQuery $bq {}]
    set names [dict get $bq outNames] ; set types [dict get $bq outTypes]
    # column types come from the static types; an INT column becomes BIGINT if any value is too big
    set seen {} ; set i 0 ; set intCols {}
    foreach n $names t $types {
        checkName $n Column
        if {[lsearch -exact $seen [string tolower $n]] >= 0} { fail "Column '$n' appears twice; give one an alias" }
        lappend seen [string tolower $n]
        if {$t in {int bool}} { lappend intCols $i }
        incr i
    }
    set cs [newId]
    set S($cs,raw) [spoolNew] ; set S($cs,big) {}
    streamPlan $id {} [list ::mkitsql::ctasRaw $cs $intCols]
    set layout {} ; set i 0
    foreach n $names t $types {
        switch -- $t {
            int - bool { set letter [expr {[lsearch -exact $S($cs,big) $i] >= 0 ? "L" : "I"}] }
            real { set letter D }
            blob { set letter B }
            default { set letter S }
        }
        lappend layout [list $n $letter {}]
        incr i
    }
    # convert everything before creating anything
    set S($cs,conv) [spoolNew]
    spoolEach $S($cs,raw) [list ::mkitsql::ctasConvert $S($cs,conv) $names $layout]
    spoolFree $S($cs,raw)
    assertClean
    ::mkitsql::db::createView $tag $name $layout
    spoolEach $S($cs,conv) [list ::mkitsql::applyInsert $tag.$name $names]
    set n [spoolCount $S($cs,conv)]
    spoolFree $S($cs,conv)
    array unset S $cs,*
    return [dict create kind message text "Table '$name' created in '$tag' with [plural $n row]." affected $n tag $tag]
}
proc ::mkitsql::ctasRaw {cs intCols chunk} {
    variable S ; variable N
    foreach i $intCols {
        if {[lsearch -exact $S($cs,big) $i] >= 0} continue
        foreach r $chunk {
            set v [lindex $r $i]
            if {$v ne $N && ($v < $::mkitsql::intMin || $v > $::mkitsql::intMax)} { lappend S($cs,big) $i ; break }
        }
    }
    spoolAdd $S($cs,raw) $chunk
    return 0
}
proc ::mkitsql::ctasConvert {dst names layout chunk} {
    set out {}
    foreach r $chunk {
        set vals {} ; set j 0
        foreach v $r { lappend vals [coerceValue [lindex $names $j] [lindex $layout $j 1] $v] ; incr j }
        lappend out [::mkitsql::rt::sk $vals]
    }
    spoolAdd $dst $out
    return 0
}

proc ::mkitsql::execDrop {st} {
    set parts [dict get $st parts]
    if {[dict get $st ifexists]} {
        if {[catch {resolveTable $parts} r]} {
            return [dict create kind message text "Table '[lindex $parts end]' does not exist; nothing to do." affected 0]
        }
    }
    lassign [resolveTable $parts] tag view
    assertWritable $tag
    ::mkitsql::db::dropView $tag $view
    return [dict create kind message text "Table '$view' dropped from '$tag'." affected 0 tag $tag]
}

proc ::mkitsql::execAlter {st} {
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    lassign [dict get $st action] what a1 a2
    switch -- $what {
        add {
            lassign $a1 name ty sub
            if {[findLayoutCol $layout $name] ne ""} { fail "Column '$name' already exists in '$label'." }
            checkName $name Column
            set new [lindex [defsToLayout [list $a1]] 0]
            ::mkitsql::db::restructure $path [concat $layout [list $new]]
            set text "Column '$name' added to '$label'.  Existing rows get the default (0 or empty text)."
        }
        drop {
            set c [findLayoutCol $layout $a1]
            if {$c eq ""} { fail "Unknown column '$a1' in '$label'." }
            if {[llength $layout] == 1} { fail "A table must keep at least one column." }
            set new {}
            foreach x $layout { if {$x ne $c} { lappend new $x } }
            ::mkitsql::db::restructure $path $new
            set text "Column '[lindex $c 0]' dropped from '$label'."
        }
        rename {
            set c [findLayoutCol $layout $a1]
            if {$c eq ""} { fail "Unknown column '$a1' in '$label'." }
            if {[lindex $c 1] eq "V"} { fail "Renaming a subview column is not supported (Metakit would discard its rows)." }
            checkName $a2 Column
            if {[findLayoutCol $layout $a2] ne "" && ![string equal -nocase $a1 $a2]} { fail "Column '$a2' already exists in '$label'." }
            ::mkitsql::db::rebuildColumn $path [lindex $c 0] $a2 [lindex $c 1]
            set text "Column '[lindex $c 0]' renamed to '$a2'.  (Metakit moves a renamed column to the end of the table.)"
        }
        retype {
            set c [findLayoutCol $layout $a1]
            if {$c eq ""} { fail "Unknown column '$a1' in '$label'." }
            if {[lindex $c 1] eq "V"} { fail "A subview column cannot change type." }
            set letter [lindex [sqlType $a2] 0]
            if {$letter eq [lindex $c 1]} {
                set text "Column '[lindex $c 0]' already has that type; nothing to do."
            } else {
                # Metakit keeps the old storage when a column's type changes under the same name: writes then fail or store
                # garbage and the file can hang on close (found on real Metakit).  Refuse, and say how to do it safely.
                fail "Metakit cannot change the type of column '[lindex $c 0]' in place (it would corrupt the file). Copy the table instead:  CREATE TABLE ${view}_new AS SELECT ..., CAST([lindex $c 0] AS $a2) AS [lindex $c 0], ... FROM $view;  DROP TABLE $view;  then COMMIT and create the table again from ${view}_new under the old name."
            }
        }
        renametable {
            if {[llength [dict get $st subs]]} { fail "Only a top-level table can be renamed." }
            checkName $a1 Table
            if {[findView $tag $a1] ne ""} { fail "Table '$a1' already exists in '$tag'." }
            # Metakit cannot rename a view: copy it (subviews included), then drop the original
            ::mkitsql::db::createView $tag $a1 $layout
            copyRows $path $tag.$a1 $layout
            ::mkitsql::db::dropView $tag $view
            set text "Table '$view' renamed to '$a1'."
        }
    }
    return [dict create kind message text $text affected 0 tag $tag]
}

# Copy every row (and, recursively, every subview) from one view to another
# that already has the same layout.
proc ::mkitsql::copyRows {src dst layout} {
    set props {} ; set subs {}
    foreach c $layout {
        if {[lindex $c 1] eq "V"} { lappend subs $c } else { lappend props [lindex $c 0] }
    }
    set n [::mkitsql::db::size $src]
    for {set first 0} {$first < $n} {incr first 1000} {
        set i $first
        foreach r [::mkitsql::db::rows $src $props $first 1000] {
            set j [::mkitsql::db::appendRow $dst $props $r]
            foreach sc $subs {
                set nm [lindex $sc 0]
                copyRows $src!$i.$nm $dst!$j.$nm [lindex $sc 2]
            }
            incr i
        }
    }
}

# ============================================================================
#  Transactions and administration
# ============================================================================
proc ::mkitsql::execTxn {what db} {
    variable defaultDb ; variable session ; variable txnOwner ; variable poisoned
    set tags [::mkitsql::db::tags]
    if {$db ne ""} {
        set t [findTag $db]
        if {$t eq ""} { fail "Unknown database '$db'. Open databases: [join $tags {, }]" }
        set targets [list $t]
    } else {
        set targets {}
        foreach t $tags {
            if {[::mkitsql::db::dirty $t] > 0 && ($session eq "" || ![info exists txnOwner($t)] || $txnOwner($t) eq $session)} { lappend targets $t }
        }
        if {![llength $targets]} {
            return [msg "Nothing to $what: there are no pending changes." 0]
        }
    }
    set total 0
    foreach t $targets {
        if {$session ne "" && [info exists txnOwner($t)] && $txnOwner($t) ne $session && [::mkitsql::db::dirty $t] > 0} {
            fail "Database '$t' has uncommitted changes from another session ($txnOwner($t)); only that session can $what them."
        }
        if {$what eq "commit"} {
            assertWritable $t
            set n [::mkitsql::db::dirty $t]
            ::mkitsql::db::commit $t
        } else {
            set n [::mkitsql::db::dirty $t]
            ::mkitsql::db::rollback $t
        }
        unset -nocomplain txnOwner($t) poisoned($t)
        incr total $n
    }
    if {$what eq "commit"} {
        return [msg "Changes to [join $targets {, }] committed to disk." $total]
    }
    return [msg "Rolled back [plural $total {pending change}] in [join $targets {, }]." $total]
}

proc ::mkitsql::rowset {cols types rows} {
    return [dict create kind rowset cols $cols types $types rows $rows rowids {} source "" \
        drill [dict create] truncated 0 editable 0]
}

proc ::mkitsql::execShowDbs {} {
    set rows {}
    foreach t [::mkitsql::db::tags] {
        lappend rows [list $t [::mkitsql::db::path $t] [llength [::mkitsql::db::views $t]] \
            [expr {[::mkitsql::db::readonly $t] ? "read-only" : "read/write"}] [::mkitsql::db::dirty $t]]
    }
    return [rowset {database file tables mode pending_changes} {"" "" N "" N} $rows]
}

proc ::mkitsql::execShowTables {db} {
    set tags [::mkitsql::db::tags]
    if {$db ne ""} {
        set t [findTag $db]
        if {$t eq ""} { fail "Unknown database '$db'. Open databases: [join $tags {, }]" }
        set tags [list $t]
    }
    set rows {}
    foreach t $tags {
        foreach v [::mkitsql::db::views $t] {
            lappend rows [list [cleanText $t] [cleanText $v] [::mkitsql::db::size $t.$v] [llength [::mkitsql::db::layout $t.$v]]]
        }
    }
    return [rowset {database table rows columns} {"" "" N N} $rows]
}

proc ::mkitsql::execDescribe {st} {
    lassign [resolveTable [dict get $st parts]] tag view
    set path $tag.$view ; set layout [::mkitsql::db::layout $path]
    if {[llength [dict get $st subs]]} { lassign [walkSubs $path $layout $view [dict get $st subs]] path layout label }
    set rows {} ; set n 0
    foreach r [flattenLayout $layout "" 0] { lappend rows [linsert $r 0 [incr n]] }
    return [rowset {# column type kind code} {N "" "" "" ""} $rows]
}
proc ::mkitsql::flattenLayout {layout prefix depth} {
    set out {}
    foreach c $layout {
        lassign $c n l sub
        if {$l eq "V"} {
            lappend out [list [cleanText $prefix$n] TABLE subview V]
            set out [concat $out [flattenLayout $sub "$prefix$n." [expr {$depth + 1}]]]
        } else {
            lappend out [list [cleanText $prefix$n] [letterSqlName $l] column $l]
        }
    }
    return $out
}
