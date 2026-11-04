# loader.tcl -- loads every MK Studio source file, in dependency order.
package require Tk 8.5
set ::mkstudio_lib [file dirname [info script]]
foreach f {version theme icons menus widgets store engine} {
    source -encoding utf-8 [file join $::mkstudio_lib $f.tcl]
}
# The query language.  Standard SQL by mkit-sql (mkstudio.vfs/lib/mkitsql, vendored: see tools/sync-mkitsql.sh), which plugs into
# the ::engine seam and shares ::store's open files.  The small built-in dialect (mkql.tcl) stays in the tree: the tests use it
# as a stand-in and a reference, and MKS_ENGINE=mkql starts the program with it instead.
if {[info exists ::env(MKS_ENGINE)] && $::env(MKS_ENGINE) eq "mkql"} {
    source -encoding utf-8 [file join $::mkstudio_lib mkql.tcl]
} else {
    source -encoding utf-8 [file join $::mkstudio_lib .. mkitsql mkitsql.tcl]
    source -encoding utf-8 [file join $::mkstudio_lib .. mkitsql engine_studio.tcl]
}
foreach f {grid editor explorer docs update crash app} {
    source -encoding utf-8 [file join $::mkstudio_lib $f.tcl]
}
package provide app-mkstudio 1.0
