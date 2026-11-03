# lock_stall_child.tcl -- takes the write lock, but is "descheduled" for <stall> ms between creating the lock file and
# writing its pid into it (what a starved process on an overloaded machine looks like), then holds the lock for <hold> ms.
#   tclkit tests/lock_stall_child.tcl <db> <stall-ms> <hold-ms> <log-file> ?<step>?     (step: created (default) | checked)
# "checked" = holding the takeover guard, the lock has been judged stale, nothing deleted yet.
# Log lines:  <ms-since-epoch> <pid> ACQUIRED | REFUSED | RELEASED
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv db stall hold log step
if {$step eq ""} { set step created }
proc logline {t} { global log ; set h [open $log a] ; puts $h "[clock milliseconds] [pid] $t" ; close $h }
set ::store::lockHook [list apply {{step stall name} { if {$name eq $step && $stall > 0} { after $stall } }} $step $stall]
if {[catch {store::openFile $db} tag]} { logline REFUSED ; exit 0 }
logline ACQUIRED
after $hold
logline RELEASED
store::closeFile $tag
exit 0
