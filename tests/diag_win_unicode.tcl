# Diagnostic (Windows): does PowerShell started from this (GUI-subsystem) Tcl run at all, and how does a non-ASCII character
# reach it?  Everything PowerShell finds out is written to a file with an ASCII name and read back here, because a GUI program
# has no console to capture.  Prints, never fails.      tclkit tests/run.tcl tests/diag_win_unicode.tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
puts "Tcl [info patchlevel]  encoding system: [encoding system]"
set ps $::env(SystemRoot)/System32/WindowsPowerShell/v1.0/powershell.exe
puts "powershell.exe exists: [file isfile $ps]"
set work [tmp mks_diag] ; file delete -force $work ; file mkdir $work
set wn [file nativename $work]
proc psrun {label script} {
    global ps
    set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $script 2>@1} out opts]
    puts "$label: rc=$rc errorcode=[expr {$rc ? [dict get $opts -errorcode] : {-}}] captured=[string map {\n { | }} [string trim [string range $out 0 200]]]"
}
proc readf {f} { if {![file exists $f]} { return "(no file)" } ; set h [open $f rb] ; set d [read $h] ; close $h ; return [string map {\r {} \n { | }} [string trim $d]] }
# 1. does it run at all?
psrun "run check" "Set-Content -LiteralPath '$wn\\ran.txt' -Value 'ran'"
puts "  ran.txt: [readf $work/ran.txt]"
# 2. what does a character in the command text arrive as?
psrun "command text" "(\[int\[\]\]\[char\[\]\]'caf\u00e9') -join ',' | Set-Content -LiteralPath '$wn\\cmdtext.txt'"
puts "  cmdtext.txt: [readf $work/cmdtext.txt]   (99,97,102,233 = intact)"
# 3. in an environment variable
set ::env(MKS_DIAG) "caf\u00e9"
psrun "env variable" "(\$env:MKS_DIAG.ToCharArray() | ForEach-Object { \[int\]\$_ }) -join ',' | Set-Content -LiteralPath '$wn\\env.txt'"
puts "  env.txt: [readf $work/env.txt]"
unset ::env(MKS_DIAG)
# 4. a folder with an accented name made by Tcl: does PowerShell see it, and can it put a file there?
set d $work/upd\ real\ (1)\ caf\u00e9 ; file mkdir $d
set dn [file nativename $d]
psrun "folder seen" "Test-Path -LiteralPath '$dn' | Set-Content -LiteralPath '$wn\\seen.txt'"
puts "  seen.txt: [readf $work/seen.txt]"
psrun "file made there" "Set-Content -LiteralPath '$dn\\made.txt' -Value 'x'"
puts "  Tcl sees made.txt: [file exists $d/made.txt]   Tcl lists the folder: [glob -nocomplain -tails -directory $d *]"
psrun "copy a file there" "Copy-Item -LiteralPath '$wn\\ran.txt' -Destination '$dn\\copy (1).txt' -Force"
puts "  Tcl sees 'copy (1).txt': [file exists "$d/copy (1).txt"]   folder now: [glob -nocomplain -tails -directory $d *]"
# 5. what PowerShell lists in our work folder, as code points
psrun "listing" "Get-ChildItem -LiteralPath '$wn' -Directory | ForEach-Object { (\[int\[\]\]\[char\[\]\]\$_.Name) -join ',' } | Set-Content -LiteralPath '$wn\\listing.txt'"
puts "  PowerShell's name for the folder: [readf $work/listing.txt]"
set codes {} ; foreach n [glob -nocomplain -tails -directory $work -types d *] { foreach c [split $n {}] { lappend codes [scan $c %c] } ; lappend codes | }
puts "  Tcl's name for the folder       : [join $codes ,]"
# 6. the same through a pipe opened by Tcl (what ::update::run uses)
set ch [open |[list $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "'piped'" 2>@1] rb]
set got [read $ch] ; catch {close $ch}
puts "open | pipe captured: [string trim $got]"
file delete -force $work
puts "0 passed, 0 failed"
exit 0
