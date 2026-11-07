# mkitsql.tcl -- mkit-sql: standard SQL for Metakit databases.
#
#   source mkitsql.tcl           (or: package require mkitsql)
#
# Storage: talks to Mk4tcl through ::mkitsql::db (db.tcl); inside MK Studio it forwards to MK Studio's
# ::store instead (db_studio.tcl).  Nothing else in the engine touches Mk4tcl.
#
# Engine API (what MK Studio uses; see engine_studio.tcl):
#   ::mkitsql::parseScript text                    -> list of {ast first end statementText}
#   ::mkitsql::execStatement ast ?defaultDb? ?params? -> result dict (rowset / message)
#
# Convenience API:
#   ::mkitsql::run   sql ?defaultDb? ?params?              -> result of the last statement
#   ::mkitsql::query sql ?defaultDb? ?params? ?nullValue?  -> {cols .. rows ..}
#   ::mkitsql::blobLimit / blobRef / blobRead / blobCopy    -> big blobs in results by reference (below)
#
# params: a list for `?` placeholders, a dict for `:name` placeholders (the statement says which it uses).
# nulls:  the parameters that are NULL - positions (1, 2, ..) for `?`, names for `:name`.  A parameter value
#         is never interpreted: no text, however it is spelled, can turn into NULL (and U+FDD0 is rejected).

package require Tcl 8.5-10

namespace eval ::mkitsql {
    variable version 0.6.0
    variable dir [file dirname [file normalize [info script]]]
}
foreach f {parser expr datetime verify bind plan spill exec window stmt dbcheck vtab kit} { source -encoding utf-8 [file join $::mkitsql::dir $f.tcl] }

# The storage layer.  Standalone (db.tcl, straight on Mk4tcl) unless MK Studio's ::store is already
# loaded, in which case the files are shared with it through db_studio.tcl.  Force one with
#     set ::mkitsql::backend standalone|studio     (before loading)    or the MKIT_BACKEND environment variable.
namespace eval ::mkitsql {
    if {![info exists backend]} { variable backend [expr {[info exists ::env(MKIT_BACKEND)] ? $::env(MKIT_BACKEND) : "auto"}] }
    if {$backend eq "auto"} { set backend [expr {[llength [info commands ::store::tags]] ? "studio" : "standalone"}] }
    if {$backend eq "studio"} {
        source -encoding utf-8 [file join $dir dbcommon.tcl]
        source -encoding utf-8 [file join $dir db_studio.tcl]
    } elseif {$backend eq "standalone"} {
        if {![llength [info commands ::mk::file]]} { catch {package require Mk4tcl} }
        source -encoding utf-8 [file join $dir dbcommon.tcl]
        source -encoding utf-8 [file join $dir db.tcl]
    } else {
        error "::mkitsql::backend must be auto, standalone or studio, not '$backend'"
    }
}

# Run every statement in `text`; returns the result of the last one.
proc ::mkitsql::run {text {db ""} {params {}} {nulls {}}} {
    set last ""
    foreach p [parseScript $text] { set last [execStatement [lindex $p 0] $db $params $nulls] }
    return $last
}

# Insert many rows that are already Tcl values - no SQL text is parsed, which is what dominates a big INSERT ... VALUES (about 150 us a row; this
# is about 25 us a row).  The same checks, conversions, range errors and all-or-nothing behaviour as INSERT.
#     ::mkitsql::insertRows $db tablename {id name} {{1 Ada} {2 Grace}}
#     ::mkitsql::insertRows $db {dbtag.t[0].kids} {name} $rows -null NIL        ;# a subview, and a token that means NULL
# `columns` empty = every column in table order; `table` is written as in SQL (dbtag.table, "quoted names", subview paths t[0].kids).  With
# -null token, values equal to the token are NULL (stored as the column's default, like any NULL).  Returns what INSERT returns (affected = row count).
proc ::mkitsql::insertRows {db table columns rows args} {
    set nullToken "" ; set useNull 0
    foreach {k v} $args {
        if {$k ne "-null" || [llength $args] % 2} { fail "insertRows: unknown option '$k' (the only option is -null token)" }
        set nullToken $v ; set useNull 1
    }
    # the table is named with the SQL grammar for a DELETE target: one statement, nothing else in it
    set parsed [parseScript "DELETE FROM $table"]
    if {[llength $parsed] != 1 || [lindex $parsed 0 0 0] ne "delete" || [dict get [lindex $parsed 0 0 1] where] ne "" || [dict get [lindex $parsed 0 0 1] alias] ne ""} {
        fail "insertRows: '[string range $table 0 60]' is not a table name"
    }
    set t [lindex $parsed 0 0 1]
    set st [dict create parts [dict get $t parts] subs [dict get $t subs] cols $columns rows $rows nullToken $nullToken useNull $useNull]
    return [execStatement [list insertrows $st] $db {} {}]
}

# Run one SELECT and hand the rows to `callback` in chunks (a list of rows per call) without ever
# holding the result: memory stays flat however big the table is.  The callback returns 1 to stop.
# NULL is passed as `nullValue`.  Returns {cols .. types .. count N}.
#     ::mkitsql::stream {SELECT * FROM big ORDER BY val} $db {} {myproc} 
proc ::mkitsql::stream {text {db ""} {params {}} {callback ""} {nullValue ""} {nulls {}}} {
    variable streamCb
    set parsed [parseScript $text]
    if {[llength $parsed] != 1 || [lindex $parsed 0 0 0] ne "select"} { fail "stream takes exactly one SELECT statement" }
    set streamCb [list $callback $nullValue]
    set rc [catch {execStatement [lindex $parsed 0 0] $db $params $nulls} res opts]
    set streamCb ""
    if {$rc} { return -options $opts $res }
    return $res
}

# ---- big blobs in results ------------------------------------------------------------------------------------------------
#   ::mkitsql::blobLimit ?bytes?    -1 (the default): a SELECT returns every blob whole, as it always has.  0 or more: a stored
#                                   blob that the outermost SELECT selects as it is (`SELECT name, data FROM t ...`, also through
#                                   `*`, joins, WHERE, ORDER BY other columns, LIMIT) comes back as itself when it has at most
#                                   `bytes` bytes and otherwise as a REFERENCE carrying its size and its first `bytes` bytes - the
#                                   value is not read.  Anything that compares or computes with the blob reads it as before.
#   ::mkitsql::blobRef value        "" for a value that is not a reference, else {db .. path .. row .. column .. size .. head ..}
#   ::mkitsql::blobRead ref ?offset? ?count?    bytes of the value: `count` (default: all the rest) from byte `offset` (0-based)
#   ::mkitsql::blobCopy ref channel             all of the value into a channel, 1 MiB at a time; returns its size in bytes
# A reference is good while its database stays open and unchanged.  After any change to it (a write, ROLLBACK, a reopen) or
# once it is closed, blobRead and blobCopy refuse the reference with -errorcode {MKIT BLOBSTALE}: run the query again.
# A value that is not a reference: {MKIT BLOBREF}.  (A blob is bytes, every character below U+0100; a reference begins with
# U+FDD1, so the two cannot be confused in a blob column.)
namespace eval ::mkitsql { variable blobLimit -1 }
proc ::mkitsql::blobLimit {args} {
    variable blobLimit
    if {[llength $args] > 1} { fail "usage: ::mkitsql::blobLimit ?bytes?" }
    if {[llength $args]} {
        set n [lindex $args 0]
        if {![string is wideinteger -strict $n] || $n < -1} { fail "blobLimit takes a number of bytes (0 or more), or -1 for whole values" }
        set blobLimit [expr {$n}]
    }
    return $blobLimit
}
proc ::mkitsql::blobRef {value} {
    set d [::mkitsql::db::blobRefParse $value]
    if {$d eq ""} { return "" }
    dict unset d generation
    return $d
}
# the reference, checked against the database as it is now
proc ::mkitsql::blobChecked {ref} {
    set d [::mkitsql::db::blobRefParse $ref]
    if {$d eq ""} { return -code error -errorcode {MKIT BLOBREF} "Not a blob reference (a value ::mkitsql::blobRef does not recognise is the blob itself)" }
    set stale "The database changed or was closed after the query that returned this blob reference ran: run the query again"
    set tag [dict get $d db] ; set path [dict get $d path] ; set row [dict get $d row]
    if {[lsearch -exact [::mkitsql::db::tags] $tag] < 0 || [::mkitsql::db::generation $tag] ne [dict get $d generation]} {
        return -code error -errorcode [list MKIT BLOBSTALE $tag] $stale
    }
    # (also where the storage layer counts no changes: the row must still be there with a value of the recorded size)
    if {[catch {::mkitsql::db::size $path} n] || $row < 0 || $row >= $n || [catch {mk::get $path!$row -size [dict get $d column]} size] || $size != [dict get $d size]} {
        return -code error -errorcode [list MKIT BLOBSTALE $tag] $stale
    }
    return $d
}
proc ::mkitsql::blobRead {ref {offset 0} {count -1}} {
    set d [blobChecked $ref]
    if {![string is wideinteger -strict $offset] || $offset < 0 || ![string is wideinteger -strict $count] || $count < -1} {
        fail "blobRead: offset must be 0 or more, count 0 or more (or -1 for the rest)"
    }
    set size [dict get $d size]
    if {$offset > $size} { set offset $size }
    if {$count < 0 || $offset + $count > $size} { set count [expr {$size - $offset}] }
    return [::mkitsql::db::readRange [dict get $d path]![dict get $d row] [dict get $d column] $offset $count]
}
proc ::mkitsql::blobCopy {ref channel} {
    set d [blobChecked $ref]
    ::mkitsql::db::copyCell [dict get $d path]![dict get $d row] [dict get $d column] $channel
    return [dict get $d size]
}

# Run one query and return {cols names rows rows}; NULL comes back as `nullValue`.
proc ::mkitsql::query {text {db ""} {params {}} {nullValue ""} {nulls {}}} {
    variable nullText
    set saved $nullText
    set nullText $nullValue
    set rc [catch {run $text $db $params $nulls} res opts]
    set nullText $saved
    if {$rc} { return -options $opts $res }
    if {$res eq "" || ![dict exists $res kind]} { return [dict create cols {} rows {} message {}] }       ;# an empty or comment-only script
    if {[dict get $res kind] ne "rowset"} { return [dict create cols {} rows {} message [dict get $res text]] }
    return [dict create cols [dict get $res cols] rows [dict get $res rows]]
}

package provide mkitsql $::mkitsql::version
