# child of test_wide.tcl: a program whose Mk4tcl "cannot read wide files" (MKS_WIDE=0) is asked to open one.  Writes "refused STORE WIDEFILE" or "opened" to the
# file named by the second argument (a Windows GUI program has no stdout to read).
set here [file dirname [file normalize [info script]]]
set ::env(MKS_WIDE) 0
package require Mk4tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv f out
if {[catch {store::openFile $f} m opts]} { set r "refused [lrange [dict get $opts -errorcode] 0 1]" } else { set r "opened" }
set h [open $out w] ; puts $h $r ; close $h
# a GUI-subsystem Tk runtime would otherwise stay in its event loop after the script, and the parent that is waiting for this process would wait for ever
exit 0
