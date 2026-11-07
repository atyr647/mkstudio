# kitverify.tcl -- the separate process the Kit tab verifies a kit in:   <mkstudio> --kitverify KIT
#
# Metakit can crash or loop on damaged data, which Tcl cannot catch; so the full read of an untrusted kit happens here, and
# the Kit tab (kit.tcl) only reads what this prints on stdout:
#     P <done> <total>     progress, in bytes (at most every 100 ms)
#     R <dict>             the result of kitfmt verify, on one line
#     anything else        an error message
# Mk4tcl is the library named by MKS_KIT_MK4TCL (the one the parent loaded), or the one built into the tclkit.
namespace eval ::kitverify { variable last 0 }
proc ::kitverify::say {line} { puts stdout $line ; flush stdout }
proc ::kitverify::tick {done total} {
    variable last
    set now [clock milliseconds]
    if {$now - $last >= 100 || $done == $total} { set last $now ; say "P $done $total" }
    return go
}
proc ::kitverify::run {path} {
    if {[catch {
        if {[info exists ::env(MKS_KIT_MK4TCL)] && $::env(MKS_KIT_MK4TCL) ne ""} { uplevel #0 [list load $::env(MKS_KIT_MK4TCL) Mk4tcl] }
        if {![llength [info commands ::mk::file]]} { uplevel #0 {package require Mk4tcl} }
        package require kitfmt 1
        if {[info exists ::env(MKS_KIT_KEYS)] && [string trim $::env(MKS_KIT_KEYS)] ne ""} {
            kitfmt configure -keys [split [string trim $::env(MKS_KIT_KEYS)]]
        }
        set h [kitfmt open $path -force 1]
        set v [kitfmt verify $h -progress ::kitverify::tick]
        kitfmt close $h
        say "R [string map [list \n { } \r { }] $v]"
    } err]} {
        say [string map [list \n { }] $err]
        return 1
    }
    return 0
}
