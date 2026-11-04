# wrap.tcl -- build a starpack without sdx.   Run it with a tclkit:
#     tclkit wrap.tcl <runtime-tclkit> <app.vfs dir> <output> ?<native library> ...?
# It copies the runtime, mounts the Metakit payload appended to the copy (the
# same thing `sdx wrap -runtime` does) and merges the application tree into it.
# Native libraries (the compiled mksync flush library for this platform: tools/build-native.sh) go into lib/mksync.
package require vfs::mk4
lassign $argv runtime vfsdir out
set natives [lrange $argv 3 end]
file copy -force $runtime $out
vfs::mk4::Mount $out $out
foreach item [glob -directory $vfsdir *] {
    set dest [file join $out [file tail $item]]
    if {[file isdirectory $item]} {
        file mkdir $dest
        foreach sub [glob -nocomplain -directory $item *] { file copy -force $sub $dest }
    } else { file copy -force $item $dest }
}
foreach lib $natives {
    file mkdir [file join $out lib mksync]
    file copy -force $lib [file join $out lib mksync [file tail $lib]]
    puts "  + native library [file tail $lib]"
}
vfs::unmount $out
puts "wrote $out ([file size $out] bytes)"
