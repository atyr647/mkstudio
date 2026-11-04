# verify_child.tcl -- run as a SEPARATE PROCESS by ::mkitsql::verifyFile:   <tclsh|tclkit> verify_child.tcl <file>
# Opens a Metakit file read-only and reads every cell of every table, subtables included.  Metakit trusts the file
# completely (no checksums): a damaged one can crash or hang the reader, which is why this is not done in the caller.
# Prints  OK <rows> <views>   or   ERR <message>.
# the Mk4tcl the parent uses, when it is a shared library loaded by path (MKIT_VERIFY_LIB), else the one a tclkit has or the package
if {[info exists ::env(MKIT_VERIFY_LIB)] && $::env(MKIT_VERIFY_LIB) ne "" && [catch {load $::env(MKIT_VERIFY_LIB) Mk4tcl}] == 0} {
} elseif {[catch {package require Mk4tcl} msg]} { puts "ERR Mk4tcl is not available: $msg" ; exit 0 }
fconfigure stdout -buffering line
set f [lindex $argv 0]
if {[catch {mk::file open vf $f -readonly -nocommit} msg]} { puts "ERR $msg" ; exit 0 }
set rows 0
# (mk::view layout of a sub-table path returns the PARENT's layout, so the nested layout is passed down)
proc walk {path layout} {
    global rows
    set props {} ; set subs {}
    foreach el $layout {
        if {[llength $el] == 2} { lappend subs $el } else { lappend props [lindex [split $el :] 0] }
    }
    set n [mk::view size $path]
    for {set i 0} {$i < $n} {incr i} {
        if {[llength $props]} { mk::get $path!$i {*}$props }
        foreach s $subs { walk $path!$i.[lindex $s 0] [lindex $s 1] }
        incr rows
    }
}
if {[catch {
    set views [mk::file views vf]
    foreach v $views { walk vf.$v [mk::view layout vf.$v] }
} msg]} { puts "ERR $msg" ; exit 0 }
puts "OK $rows [llength $views]"
exit 0
