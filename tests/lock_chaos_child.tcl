# lock_chaos_child.tcl -- takes the write lock over and over, checking that nobody else is inside at the same time.
#   tclkit tests/lock_chaos_child.tcl <db> <log-file> <stop-file>
# "Inside" = holding the lock.  Inside, the process writes its pid to <db>.inside and checks on the way out that it is still
# its own; another process writing there meanwhile means two held the lock at once - recorded as VIOLATION.  Wins: WIN.
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv db log stop
proc logline {text} { global log ; set h [open $log a] ; fconfigure $h -translation lf ; puts $h $text ; close $h }
expr {srand([pid])}
while {![file exists $stop]} {
    if {[catch {store::openFile $db} tag]} { after [expr {1 + int(rand() * 8)}] ; continue }
    # Inside the critical section: write our pid into <db>.inside, hold for a moment, and check on the way out that
    # nobody else wrote to it meanwhile.  Someone else writing there while we are inside means two processes held the
    # lock at the same time.  (No process-liveness test: a killed process simply never checks again, and a leftover
    # marker from one is overwritten by the next owner, which is not a violation.)
    set marker $db.inside
    set h [open $marker w] ; puts -nonewline $h [pid] ; close $h
    logline "WIN [pid]"
    after [expr {2 + int(rand() * 25)}]
    set seen ""
    catch {set h [open $marker r] ; set seen [string trim [read $h]] ; close $h}
    if {$seen ne [pid]} { logline "VIOLATION [pid] found $seen inside with it" }
    file delete $marker
    store::closeFile $tag
}
exit 0
