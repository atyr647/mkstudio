# lock_chaos_child.tcl -- takes the write lock over and over, checking that nobody else is inside at the same time.
#   tclkit tests/lock_chaos_child.tcl <db> <log-file> <stop-file>
# "Inside" = holding the lock.  Inside, the process creates <db>.inside exclusively; if that file exists and names a
# process that is still alive, two processes hold the lock at once - recorded as VIOLATION.  Wins are recorded as WIN.
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv db log stop
proc logline {text} { global log ; set h [open $log a] ; fconfigure $h -translation lf ; puts $h $text ; close $h }
expr {srand([pid])}
while {![file exists $stop]} {
    if {[catch {store::openFile $db} tag]} { after [expr {1 + int(rand() * 8)}] ; continue }
    set marker $db.inside
    if {[catch {set h [open $marker {WRONLY CREAT EXCL}] ; puts -nonewline $h [pid] ; close $h}]} {
        # someone else's marker: a violation only if its owner is alive (a killed owner leaves it behind)
        set other ""
        catch {set h [open $marker r] ; set other [string trim [read $h]] ; close $h}
        if {$other ne "" && $other ne [pid] && [store::pidAlive $other]} { logline "VIOLATION [pid] saw $other inside" }
        file delete $marker
        catch {set h [open $marker {WRONLY CREAT EXCL}] ; puts -nonewline $h [pid] ; close $h}
    }
    logline "WIN [pid]"
    after [expr {2 + int(rand() * 25)}]
    file delete $marker
    store::closeFile $tag
}
exit 0
