# lock_child_mkitsql.tcl -- like lock_child.tcl, but the process uses mkit-sql's OWN storage layer and lock
# implementation (a different code base following the same protocol).
#   MKITSQL_DIR=/path/to/mkit-sql tclkit tests/lock_child_mkitsql.tcl <db> <result-file> <go-file> ?hold-ms?
package require Mk4tcl
set ::env(MKIT_BACKEND) standalone
source $::env(MKITSQL_DIR)/mkitsql/mkitsql.tcl
lassign $argv db result go hold
if {$hold eq ""} { set hold 800 }
while {![file exists $go]} { after 1 }
set rc [catch {mkitsql::db::openFile $db} tag opts]
set h [open $result w]
if {!$rc} {
    puts $h WIN ; close $h
    after $hold
    mkitsql::db::closeFile $tag
} else {
    set code [dict get $opts -errorcode]
    if {[lindex $code 1] eq "LOCKED"} { puts $h "LOCKED $tag" } else { puts $h "ERROR $tag" }
    close $h
}
exit 0
