# The native flush library (native/mksync/mksync.c):   tclkit tests/test_mksync.tcl
#   MKS_MKSYNC_DIR       folder holding the compiled mksync-<os>-<arch>.(so|dll|dylib)   (default: tools/ext)
#   MKS_REQUIRE_NATIVE   set: a missing library is a failure (CI sets it); unset: the library tests are skipped, the fallbacks still run
# What is checked: the package loads through the same pkgIndex.tcl the starpack carries; flush on files and folders, a missing path
# (skipped, not an error), several paths, names with a space / accents / CJK, a path beyond 260 characters, a file that another channel
# of this very process has open with unflushed data; the wrong-argument error; ::store::syncDisk really takes the native path and
# falls back to a program when the library is switched off; the time one flush takes.
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 150]> want <$want>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }

proc setRO {f on} {
    if {$::tcl_platform(platform) eq "windows"} { file attributes $f -readonly $on } else { file attributes $f -permissions [expr {$on ? "00444" : "00644"}] }
}
set libdir [expr {[info exists ::env(MKS_MKSYNC_DIR)] ? $::env(MKS_MKSYNC_DIR) : [file join $here .. tools ext]}]
set libs [glob -nocomplain -directory $libdir mksync-*]
set required [info exists ::env(MKS_REQUIRE_NATIVE)]

# the package, found exactly as in the starpack: lib/mksync/pkgIndex.tcl (the library comes from MKS_MKSYNC_DIR here)
set ::env(MKS_MKSYNC_DIR) $libdir
lappend ::auto_path [file normalize [file join $here .. mkstudio.vfs lib]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set ::store::durable 1                  ;# (CI turns the flushes off for most suites on Windows to save time; this one is about them)

set have [expr {![catch {package require mksync} err]}]
if {!$have} {
    if {$required} { ok "the native library loads (MKS_REQUIRE_NATIVE)" 0 "package require mksync: $err; libraries in $libdir: $libs" }
    puts "  (no native library for this system in $libdir: the native tests are skipped)"
} else {
    puts "  mksync [package provide mksync] loaded, method [mksync::method], Tcl [info patchlevel] on $::tcl_platform(os) $::tcl_platform(machine)"
    set exp [expr {$::tcl_platform(platform) eq "windows" ? "FlushFileBuffers" : ($::tcl_platform(os) eq "Darwin" ? "F_FULLFSYNC" : "fsync")}]
    check "the method of this system" [mksync::method] $exp
    set d [tmp mks_mksync_[pid]] ; file delete -force $d ; file mkdir $d
    set f $d/a.txt ; set h [open $f w] ; puts $h hello ; close $h
    check "a file and its folder" [mksync::flush $f $d] [expr {$::tcl_platform(platform) eq "windows" ? 1 : 2}]
    check "the same file again" [mksync::flush $f] 1
    check "a missing file is skipped, not an error" [mksync::flush $d/missing $f] 1
    check "a missing folder is skipped" [mksync::flush $d/nope/deeper/x] 0
    ok "no argument: an error" [catch {mksync::flush} m] ; ok "...which says how to call it" [string match "wrong # args*" $m] $m
    # names with a space, accents, CJK (built from code points: the test file stays ASCII)
    set odd "$d/caf[format %c 233] [format %c 20013][format %c 25991] 'q' \[x\] \$y.mk"
    set h [open $odd w] ; puts $h x ; close $h
    check "a name with a space, accents, CJK, quotes and brackets" [mksync::flush $odd] 1
    # a file another channel of this process has open, with data not yet written out
    set g $d/open.dat ; set h [open $g w] ; puts $h [string repeat x 100000]
    check "a file that is open for writing elsewhere" [catch {mksync::flush $g}] 0
    close $h
    # a path beyond 260 characters
    set deep $d ; for {set i 0} {[string length $deep] < 330} {incr i} { append deep /[string repeat d 40] }
    if {![catch {file mkdir $deep ; set h [open $deep/long.txt w] ; puts $h x ; close $h}]} {
        check "a path beyond 260 characters" [catch {mksync::flush $deep/long.txt}] 0
    } else { puts "  (the system cannot make a path of [string length $deep] characters: skipped)" }
    # a read-only file: not a failure (Windows: skipped - FlushFileBuffers needs write access; Unix: flushed through a read handle)
    set ro $d/ro.txt ; set h [open $ro w] ; puts $h x ; close $h ; setRO $ro 1
    check "a read-only file" [catch {mksync::flush $ro}] 0
    setRO $ro 0

    # ::store::syncDisk takes the native path ...
    check "store: the native library is in use" [store::nativeFlush] 1
    ok "store: flushMethod names it" [string match "native (*" [store::flushMethod]] [store::flushMethod]
    check "store: syncDisk reports success" [store::syncDisk $f] 1
    # ... and a failure of the native call is a failure, not silently retried
    check "store: a failing native flush is reported" [store::syncDisk $d/missing] 1
    rename ::mksync::flush ::mksync::flush_real
    proc ::mksync::flush args { error "disk on fire" }
    check "store: an error from the native call is a failure" [store::syncDisk $f] 0
    rename ::mksync::flush {} ; rename ::mksync::flush_real ::mksync::flush
    # timing
    set n 20 ; set t0 [clock milliseconds]
    for {set i 0} {$i < $n} {incr i} { store::syncDisk $f }
    set native_ms [expr {([clock milliseconds] - $t0) / double($n)}]
    puts [format "  one native flush (file + folder): %.1f ms" $native_ms]
    ok "a native flush takes well under a second" [expr {$native_ms < 500}] $native_ms
    file delete -force $d
}

# the fallback: no library, the program is started instead
set save $::store::native
set ::store::native 0
set d [tmp mks_mksync_fb_[pid]] ; file delete -force $d ; file mkdir $d
set f $d/b.txt ; set h [open $f w] ; puts $h hello ; close $h
ok "fallback: flushMethod is a program" [expr {[store::flushMethod] in {sync PowerShell none}}] [store::flushMethod]
if {[store::flushMethod] ne "none"} {
    set t0 [clock milliseconds]
    check "fallback: syncDisk succeeds through a program" [store::syncDisk $f] 1
    puts "  one flush through [store::flushMethod]: [expr {[clock milliseconds] - $t0}] ms"
}
set ::store::native $save
file delete -force $d
puts "mksync: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
