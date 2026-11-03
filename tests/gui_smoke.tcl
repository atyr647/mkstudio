# GUI smoke test (needs a display, e.g. xvfb-run):  wish tests/gui_smoke.tcl
set here [file dirname [file normalize [info script]]]
set ::mkstudio_root [file join $here .. mkstudio.vfs]
source $here/mock_mk4tcl.tcl
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) /tmp/mks_home ; file mkdir $::env(HOME)
::app::main {}
update
puts "main window ok: [wm geometry .]"
exit 0
