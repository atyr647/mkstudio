# lock_crash_child.tcl -- acquires the write lock and is killed (SIGKILL / taskkill /F) at one named step.
#   tclkit tests/lock_crash_child.tcl <db> <step> <done-file>
# steps: created (lock file exists, still empty) | written (lock complete) | mutex (holds the takeover mutex)
#        | deleted (mutex held, stale lock removed, new one not yet created) | released (after a normal close)
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv db step done
proc killself {} {
    if {$::tcl_platform(platform) eq "windows"} { catch {exec taskkill /F /PID [pid]} } else { catch {exec kill -9 [pid]} }
    after 5000
}
set ::store::lockHook [list apply {{step name} { if {$name eq $step} { killself } }} $step]
catch {store::openFile $db} tag
if {$step eq "released"} { catch {store::closeFile $tag} }
set h [open $done w] ; puts $h "survived $tag" ; close $h
exit 0
