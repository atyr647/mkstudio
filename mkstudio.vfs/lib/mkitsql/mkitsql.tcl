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
#
# params: a list for `?` placeholders, a dict for `:name` placeholders (the statement says which it uses).
# nulls:  the parameters that are NULL - positions (1, 2, ..) for `?`, names for `:name`.  A parameter value
#         is never interpreted: no text, however it is spelled, can turn into NULL (and U+FDD0 is rejected).

package require Tcl 8.5-10

namespace eval ::mkitsql {
    variable version 0.4.2
    variable dir [file dirname [file normalize [info script]]]
}
foreach f {parser expr datetime verify bind plan spill exec window stmt dbcheck} { source -encoding utf-8 [file join $::mkitsql::dir $f.tcl] }

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
