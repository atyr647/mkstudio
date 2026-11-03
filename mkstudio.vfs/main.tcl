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
if {[llength [info commands ::mk::file]] == 0} {
    ::app::main {}
    ::ui::problem "Mk4tcl (the Metakit binding) was not found.\n\nMK Studio is meant to run as a starpack built on a tclkit, which includes Metakit. You can still look around, but databases cannot be opened." "Metakit not available"
} else {
    ::app::main $::mkstudio_args
}
