# lock_child.tcl -- a process that tries to open a database for writing at a given moment.
#   tclkit tests/lock_child.tcl <db> <result-file> <go-file> ?hold-ms?
# Waits for <go-file> to appear (so several children start together), then reports one line in
# <result-file>:  WIN | LOCKED <message> | ERROR <message>
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv db result go hold
if {$hold eq ""} { set hold 800 }
while {![file exists $go]} { after 1 }
set rc [catch {store::openFile $db} tag opts]
set h [open $result w]
if {!$rc} {
    puts $h WIN ; close $h
    after $hold
    store::closeFile $tag
} else {
    set code [dict get $opts -errorcode]
    if {[lindex $code 0] eq "STORE" && [lindex $code 1] eq "LOCKED"} { puts $h "LOCKED $tag" } else { puts $h "ERROR $tag" }
    close $h
}
exit 0
