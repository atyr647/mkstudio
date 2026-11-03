# loader.tcl -- loads every MK Studio source file, in dependency order.
package require Tk 8.5
set ::mkstudio_lib [file dirname [info script]]
foreach f {theme icons widgets store mkql grid editor explorer docs app} {
    source -encoding utf-8 [file join $::mkstudio_lib $f.tcl]
}
package provide app-mkstudio 1.0
