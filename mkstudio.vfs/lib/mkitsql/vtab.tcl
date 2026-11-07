# vtab.tcl -- the virtual-table registry: read-only tables whose rows come from Tcl code, not from a Metakit view.
#
#   ::mkitsql::registerVirtual schema table columns rowsCmd
#       columns   a list of {name type}, type one of  text int real blob
#       rowsCmd   a command prefix; called as  {*}$rowsCmd $ctx  and returns the rows: a list of lists of values,
#                 one value per column, in column order.  ctx is a dict:  schema, table, db (the statement's default
#                 database tag, "" if it has none).  An error it raises fails the statement with its message.
#   ::mkitsql::unregisterVirtual schema ?table?
#   ::mkitsql::virtualTables ?schema?        -> {schema table columns} for every registered table, sorted
#
# The tables are queried as  schema.table  like any other (SELECT, joins, subqueries, WHERE, ORDER BY ...); they cannot be
# changed.  information_schema.tables / columns are the first two, kit.* (kit.tcl) the next ones.  Name resolution:
# information_schema always means these tables; another registered schema is used only when no open database has that tag,
# so registering a schema never hides a database's tables.
#
# Rows are checked on the way in: the width must match, text never carries the engine's NULL marker (cleanText), an int or
# real column holds a number or "" (which is NULL).  Rows are produced in full each time the table is read: a provider that
# is expensive (kit.verify) should say so in its documentation.

namespace eval ::mkitsql {
    variable vtabs              ;# vtabs(schema.table) = dict schema table cols cmd   (names lower case)
    array set vtabs {}
}

proc ::mkitsql::registerVirtual {schema table columns rowsCmd} {
    variable vtabs
    foreach n [list $schema $table] {
        if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $n]} { error "registerVirtual: '$n' is not a plain name (letters, digits, _)" }
    }
    if {![llength $columns]} { error "registerVirtual: $schema.$table needs at least one column" }
    set seen {}
    foreach c $columns {
        if {[llength $c] != 2} { error "registerVirtual: a column is {name type}, not '$c'" }
        lassign $c n t
        if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $n]} { error "registerVirtual: column name '$n' is not a plain name" }
        if {$t ni {text int real blob}} { error "registerVirtual: column $n: type must be text, int, real or blob, not '$t'" }
        if {[lsearch -exact $seen [string tolower $n]] >= 0} { error "registerVirtual: column $n appears twice" }
        lappend seen [string tolower $n]
    }
    if {![llength $rowsCmd]} { error "registerVirtual: rowsCmd is empty" }
    set vtabs([string tolower $schema].[string tolower $table]) [dict create schema [string tolower $schema] \
        table [string tolower $table] cols $columns cmd $rowsCmd]
    return
}

proc ::mkitsql::unregisterVirtual {schema {table ""}} {
    variable vtabs
    set schema [string tolower $schema]
    if {$table eq ""} { array unset vtabs $schema.* } else { array unset vtabs $schema.[string tolower $table] }
    return
}

proc ::mkitsql::virtualTables {{schema ""}} {
    variable vtabs
    set out {}
    foreach k [lsort [array names vtabs]] {
        set v $vtabs($k)
        if {$schema ne "" && [dict get $v schema] ne [string tolower $schema]} continue
        lappend out [list [dict get $v schema] [dict get $v table] [dict get $v cols]]
    }
    return $out
}

# the binder: a source for  schema.table, or "" when the name is not a virtual table (then it is a database's table)
proc ::mkitsql::virtualSource {schema table alias} {
    variable vtabs ; variable defaultDb
    set s [string tolower $schema]
    if {$s ne "information_schema"} {
        if {![llength [array names vtabs $s.*]]} { return "" }
        foreach tag [::mkitsql::db::tags] { if {[string equal -nocase $tag $schema]} { return "" } }
    }
    set key $s.[string tolower $table]
    if {![info exists vtabs($key)]} {
        set have {}
        foreach k [lsort [array names vtabs $s.*]] { lappend have [dict get $vtabs($k) table] }
        fail "Unknown $s table '$table'.  Available: [join $have {, }]"
    }
    set cols {}
    foreach c [dict get $vtabs($key) cols] { lappend cols [list [lindex $c 0] [lindex $c 1] "" 0 {}] }
    return [newSource info [pickName $alias [string tolower $table]] $cols which $key db $defaultDb]
}

# the executor: the rows of a virtual table, checked
proc ::mkitsql::virtualRows {which db} {
    variable vtabs ; variable N
    if {![info exists vtabs($which)]} { fail "The virtual table $which is no longer registered" }
    set v $vtabs($which)
    set ctx [dict create schema [dict get $v schema] table [dict get $v table] db $db]
    if {[catch {{*}[dict get $v cmd] $ctx} rows]} { fail "$which: $rows" }
    set types {}
    foreach c [dict get $v cols] { lappend types [lindex $c 1] }
    set w [llength $types]
    set out {}
    foreach r $rows {
        if {[llength $r] != $w} { fail "$which: a row has [llength $r] values for $w columns" }
        set row {}
        foreach x $r t $types {
            switch -- $t {
                int { if {$x eq ""} { set x $N } elseif {![string is wideinteger -strict $x]} { fail "$which: '[string range $x 0 40]' in an int column" } }
                real { if {$x eq ""} { set x $N } elseif {![string is double -strict $x]} { fail "$which: '[string range $x 0 40]' in a real column" } }
                default { set x [cleanText $x] }
            }
            lappend row $x
        }
        lappend out $row
    }
    return $out
}

# ---- information_schema, the first two -------------------------------------------------------------------------------
::mkitsql::registerVirtual information_schema tables {{table_catalog text} {table_name text} {table_type text} {row_count int}} {::mkitsql::infoRows tables}
::mkitsql::registerVirtual information_schema columns {{table_catalog text} {table_name text} {column_name text} {ordinal_position int} {data_type text} {metakit_type text}} {::mkitsql::infoRows columns}
