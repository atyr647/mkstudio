puts "Tcl [info patchlevel]"
foreach p {Tk Mk4tcl vfs starkit} { puts "$p: [catch {package require $p} v] $v" }
puts "mk::file commands: [llength [info commands mk::file]]"
exit
