# lock_stall_child.tcl -- takes the write lock, but is "descheduled" at one point of the acquisition (what a starved process on an
# overloaded machine looks like): it waits there until the parent creates <log>.release, then carries on and holds the lock.
#   tclkit tests/lock_stall_child.tcl <db> <stall-max-ms> <hold-ms> <log-file> ?<step>? ?<retry-ms>? ?<release-name>?
#   step:  created (default) = the lock file exists but is still empty | checked = holding the takeover guard, the lock has been judged
#          stale, nothing deleted yet.   stall-max-ms 0 = no stall.
#   guard-aged = the takeover guard was judged abandoned (older than the limit) and is about to be deleted.
#   release-name: the stalled process waits for the file <log>.<release-name> (default "release"), so two stalled processes can be freed separately.
#   retry-ms: keep trying to get the lock for this long (a process that finds the lock held tries again); then give up (REFUSED)
# Log lines:  <ms-since-epoch> <pid> STALLED | ACQUIRED | REFUSED | VERIFY ok|lost | RELEASED
# (Nothing here depends on how fast processes start: the parent releases the stalled process once the other one has decided.)
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv db stall hold log step retry rel
if {$step eq ""} { set step created }
if {$rel eq ""} { set rel release }
if {$retry eq ""} { set retry 0 }
proc logline {t} { global log ; set h [open $log a] ; puts $h "[clock milliseconds] [pid] $t" ; close $h }
set ::store::lockHook [list apply {{step stall log rel name} {
    if {$name eq $step && $stall > 0} {
        uplevel #0 {logline STALLED}                  ;# tells the parent that this process is now stuck at the chosen point
        for {set i 0} {$i < $stall / 20 && ![file exists $log.$rel]} {incr i} { after 20 }
    }
}} $step $stall $log $rel]
set t0 [clock milliseconds]
while 1 {
    if {![catch {store::openFile $db} tag]} break
    if {[clock milliseconds] - $t0 >= $retry} { logline REFUSED ; exit 0 }
    after 100
}
logline ACQUIRED
after $hold
# is the lock still ours?  (what a commit checks just before it writes)
logline "VERIFY [expr {[catch {store::verifyLock $tag}] ? {lost} : {ok}}]"
logline RELEASED
store::closeFile $tag
exit 0
