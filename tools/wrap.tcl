# wrap.tcl -- build a starpack without sdx.   Run it with a tclkit:
#     tclkit wrap.tcl <runtime-tclkit> <app.vfs dir> <output>
# It copies the runtime, mounts the Metakit payload appended to the copy (the
# same thing `sdx wrap -runtime` does) and merges the application tree into it.
package require vfs::mk4
lassign $argv runtime vfsdir out
file copy -force $runtime $out
vfs::mk4::Mount $out $out
foreach item [glob -directory $vfsdir *] {
    set dest [file join $out [file tail $item]]
    if {[file isdirectory $item]} {
        file mkdir $dest
        foreach sub [glob -nocomplain -directory $item *] { file copy -force $sub $dest }
    } else { file copy -force $item $dest }
}
vfs::unmount $out
puts "wrote $out ([file size $out] bytes)"
