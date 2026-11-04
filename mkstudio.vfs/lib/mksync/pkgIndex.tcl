# mksync: the native flush (native/mksync/mksync.c).  The compiled library for this platform sits next to this file (CI builds it for
# each system and build.sh puts it in the starpack); a source checkout or a platform without one simply has no such package, and
# every caller falls back to starting a program (see ::store::syncDisk).
set _mks_os [string tolower $::tcl_platform(os)]
if {[string match windows* $_mks_os]} { set _mks_os windows ; set _mks_ext .dll } elseif {$_mks_os eq "darwin"} { set _mks_os macos ; set _mks_ext .dylib } else { set _mks_os linux ; set _mks_ext .so }
set _mks_arch [string tolower $::tcl_platform(machine)]
if {$_mks_arch eq "amd64" || $_mks_arch eq "x64"} { set _mks_arch x86_64 } elseif {$_mks_arch eq "aarch64"} { set _mks_arch arm64 }
# (MKS_MKSYNC_DIR: another folder to look in - for the tests, which run from a checkout with the libraries CI built elsewhere)
set _mks_dirs [list $dir] ; if {[info exists ::env(MKS_MKSYNC_DIR)]} { lappend _mks_dirs $::env(MKS_MKSYNC_DIR) }
foreach _mks_d $_mks_dirs {
    set _mks_lib [file join $_mks_d mksync-$_mks_os-$_mks_arch$_mks_ext]
    if {[file exists $_mks_lib]} { package ifneeded mksync 1.0 [list load $_mks_lib Mksync] ; break }
}
unset -nocomplain _mks_os _mks_ext _mks_arch _mks_lib _mks_dirs _mks_d
