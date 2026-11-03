# Create the sample database at the path given as argument:  tclkit tests/make_sample.tcl out.mk
package require Mk4tcl
source [file join [file dirname [file normalize [info script]]] .. mkstudio.vfs lib app-mkstudio store.tcl]
file delete [lindex $argv 0]
store::createSample [lindex $argv 0]
exit 0
