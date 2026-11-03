# Verify a built starpack's embedded application matches mkstudio.vfs byte for byte.
#   tclkit tests/verify_payload.tcl dist/mkstudio-windows-x86_64.exe ...
# (never executes the starpack - it only mounts the Metakit payload read-only)
package require vfs::mk4
set src [file join [file dirname [file normalize [info script]]] .. mkstudio.vfs]
set bad 0
proc slurp {f} { set h [open $f rb] ; set d [read $h] ; close $h ; return $d }
proc walk {dir} {
    set out {}
    foreach f [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $f]} { set out [concat $out [walk $f]] } else { lappend out $f }
    }
    return $out
}
foreach pack $argv {
    set mnt /mnt_verify_[incr n]
    vfs::mk4::Mount $pack $mnt -readonly
    set files 0 ; set mism 0
    foreach f [walk $src] {
        set rel [string range $f [expr {[string length $src] + 1}] end]
        set m $mnt/$rel
        if {![file exists $m]} { puts "  MISSING $rel" ; incr mism ; continue }
        if {[slurp $f] ne [slurp $m]} { puts "  DIFFERS $rel" ; incr mism }
        incr files
    }
    vfs::unmount $mnt
    puts "[file tail $pack]: $files files compared, [expr {$mism ? "$mism PROBLEM(S)" : "payload identical"}]"
    incr bad $mism
}
exit [expr {$bad ? 1 : 0}]
