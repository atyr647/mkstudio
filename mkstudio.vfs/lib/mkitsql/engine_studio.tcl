# engine_studio.tcl -- plugs mkit-sql into MK Studio's ::engine seam.
#
# MK Studio's UI talks to its query language only through ::engine (see engine.tcl in
# MK Studio).  Load this file after store.tcl and engine.tcl and the standard-SQL engine
# replaces the built-in dialect:
#
#     source /path/to/mkit-sql/mkitsql/mkitsql.tcl
#     source /path/to/mkit-sql/mkitsql/engine_studio.tcl
#
# The UI sets ::engine::cancel / progressHook and reads maxRows; those variables are
# shared with ::mkitsql (not copied), so Stop and the progress callback work inside the
# engine's loops.

foreach v {cancel maxRows progressHook} {
    unset -nocomplain ::mkitsql::$v
    namespace eval ::mkitsql [list namespace upvar ::engine $v $v]
}

set ::engine::name "mkit-sql $::mkitsql::version (standard SQL)"
set ::engine::keywords [lsort -unique [concat $::mkitsql::keywords $::mkitsql::winFuncs]]
set ::engine::functions [lsort -unique [concat $::mkitsql::aggs $::mkitsql::winFuncs $::mkitsql::functions]]
set ::engine::types {
    INT INTEGER SMALLINT BIGINT REAL FLOAT DOUBLE PRECISION DECIMAL NUMERIC BOOLEAN
    VARCHAR CHAR CHARACTER TEXT STRING BLOB BINARY DATE TIME TIMESTAMP INTERVAL
}
set ::engine::tokenRe $::mkitsql::tokenRe

proc ::engine::parseScript {text} { ::mkitsql::parseScript $text }
proc ::engine::execute {handle defaultDb} { ::mkitsql::execStatement $handle $defaultDb }

# Big bytes by reference.  A MK Studio whose engine.tcl declares ::engine::blobPreview shows a bytes cell of a result as its size and
# that many first bytes, and asks ::engine::blobRef for references: a stored blob that a query selects as it is and that is longer
# then comes back as a reference (::mkitsql::blobLimit), so selecting a 1 GB value does not load it.  An older MK Studio (no
# blobPreview) gets whole values, as before.
proc ::engine::blobRef {value} { ::mkitsql::blobRef $value }
if {[info exists ::engine::blobPreview]} { ::mkitsql::blobLimit $::engine::blobPreview }
