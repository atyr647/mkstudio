# child of test_wide.tcl: a program whose Mk4tcl "cannot read wide files" (MKS_WIDE=0) is asked to open one.  Prints "refused STORE WIDEFILE" or "opened".
set here [file dirname [file normalize [info script]]]
set ::env(MKS_WIDE) 0
package require Mk4tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
if {[catch {store::openFile [lindex $argv 0]} m opts]} { puts "refused [lrange [dict get $opts -errorcode] 0 1]" } else { puts "opened" }
