# main.tcl -- entry point of the MK Studio starkit / starpack.
#
# Inside a starpack, tclkit has already mounted this tree; unwrapped (development)
# it works from a plain checkout:   wish mkstudio.vfs/main.tcl ?database.mk ...?
#
# Metakit's Tcl binding (Mk4tcl) is built into every tclkit, so a starpack
# built from one needs nothing else.

set ::mkstudio_root [file dirname [file normalize [info script]]]
if {![catch {package require starkit}]} {
    if {[starkit::startup] eq "sourced"} { }
}
lappend ::auto_path [file join $::mkstudio_root lib]

# Command-line switches that must work without opening a window (a GUI-subsystem Windows build has no console,
# so --selftest writes its answer to a file):
#   --version              print the version and exit
#   --selftest FILE        write "ok <version> mk4tcl yes|no" to FILE and exit   (the updater runs this on a download)
#   --info FILE            write what this build is made of (version, Tcl, system, how it forces data to disk) to FILE and exit
source [file join $::mkstudio_root lib app-mkstudio version.tcl]
if {[lindex $argv 0] eq "--version"} {
    puts $::version::current
    catch {if {[info exists ::env(MKS_TEST_LOG)]} { set h [open $::env(MKS_TEST_LOG) a] ; puts $h $::version::current ; close $h }}
    exit 0
}
if {[lindex $argv 0] eq "--selftest"} {
    source [file join $::mkstudio_root lib app-mkstudio update.tcl]
    set rc [catch {
        set h [open [lindex $argv 1] w] ; puts $h [::update::selftestText] ; close $h
    }]
    exit $rc
}

if {[lindex $argv 0] eq "--info"} {
    catch {package require Mk4tcl}
    source [file join $::mkstudio_root lib app-mkstudio store.tcl]
    set rc [catch {
        set h [open [lindex $argv 1] w]
        puts $h "version $::version::current"
        puts $h "tcl [info patchlevel]"
        puts $h "system $::tcl_platform(os) $::tcl_platform(osVersion) $::tcl_platform(machine)"
        puts $h "metakit [expr {[catch {package present Mk4tcl} v] ? {none} : $v}] (files over 2 GiB: [expr {[::store::wideCapable] ? {yes} : {no}}])"
        set sql ""
        catch { set sh [open [file join $::mkstudio_root lib mkitsql SOURCE] r] ; set sl [split [read $sh] \n] ; close $sh ; set sql "[lindex $sl 0] ([string range [lindex [lindex $sl 1] 1] 0 11])" }
        puts $h "sql $sql"
        puts $h "flush [::store::flushMethod]"
        close $h
    }]
    exit $rc
}

# Metakit: real Mk4tcl when available.  `--mock` (development only) loads the
# pure-Tcl stand-in from tests/ so the UI can be exercised without Metakit.
set ::mkstudio_args {}
foreach a $argv {
    if {$a eq "--mock"} {
        source [file join $::mkstudio_root .. tests mock_mk4tcl.tcl]
    } else { lappend ::mkstudio_args $a }
}
if {[llength [info commands ::mk::file]] == 0} { catch {package require Mk4tcl} }

package require app-mkstudio
# an error while starting (before the window exists) still leaves a report and a message, not a silent exit
proc ::mkstudio_fatal {err opts} {
    set report ""
    catch {lassign [::crash::record $err [dict get $opts -errorinfo] Startup] report}
    catch {tk_messageBox -icon error -title "MK Studio" -message "MK Studio could not start.\n\n$err\n\nA report was saved:\n$report"}
    puts stderr "MK Studio could not start: $err\n[dict get $opts -errorinfo]"
    exit 1
}
if {[llength [info commands ::mk::file]] == 0} {
    ::app::main {}
    ::ui::problem "Mk4tcl (the Metakit binding) was not found.\n\nMK Studio is meant to run as a starpack built on a tclkit, which includes Metakit. You can still look around, but databases cannot be opened." "Metakit not available"
} else {
    if {[catch {::app::main $::mkstudio_args} err opts]} { ::mkstudio_fatal $err $opts }
}
