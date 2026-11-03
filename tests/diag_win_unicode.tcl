# Diagnostic (Windows): how does a non-ASCII character reach PowerShell from this Tcl?  Run through tests/run.tcl.
# Prints, never fails.  Tells which transport (command text, environment variable, stdin script file) is intact.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
puts "Tcl [info patchlevel]  encoding system: [encoding system]  platform: $::tcl_platform(platform)"
set ps [expr {[file isfile $::env(SystemRoot)/System32/WindowsPowerShell/v1.0/powershell.exe] ? "$::env(SystemRoot)/System32/WindowsPowerShell/v1.0/powershell.exe" : "powershell"}]
set e "café"
# 1. in the command text
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "\[int\]\[char\]'é'" 2>@1} out]
puts "command text : rc=$rc out=[string trim $out]   (233 = intact)"
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "'$e'.Length; (\[int\[\]\]\[char\[\]\]'$e') -join ','" 2>@1} out]
puts "command text, word : rc=$rc out=[string map {\n { | }} [string trim $out]]   (4 | 99,97,102,233)"
# 2. in an environment variable
set ::env(MKS_DIAG) $e
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command {(\[int[]\]\[char[]\]$env:MKS_DIAG) -join ','} 2>@1} out]
puts "env variable : rc=$rc out=[string trim $out]"
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command {($env:MKS_DIAG.ToCharArray() | ForEach-Object { [int]$_ }) -join ','} 2>@1} out]
puts "env variable, loop : rc=$rc out=[string trim $out]"
# 3. a script file (UTF-8 with BOM) given with -File
set d [tmp "diag café (1)"] ; file delete -force $d ; file mkdir $d
puts "Tcl made the folder: [file isdirectory $d]   names in temp: [llength [glob -nocomplain -directory [tmpdir] {diag caf*}]]"
set h [open $d/s.ps1 wb] ; puts -nonewline $h "\xef\xbb\xbf" ; puts -nonewline $h [encoding convertto utf-8 "(\[int\[\]\]\[char\[\]\]'$e') -join ','"] ; close $h
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $d/s.ps1 2>@1} out]
puts "-File (UTF-8 BOM): rc=$rc out=[string trim $out]"
# 4. does PowerShell see the folder Tcl made?  and does Tcl see what PowerShell makes?
set q "'[string map {' ''} [file nativename $d]]'"
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Test-Path -LiteralPath $q" 2>@1} out]
puts "PowerShell sees Tcl's folder (path in command text): rc=$rc out=[string trim $out]"
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "New-Item -ItemType File -Force -Path ($q + '\\made.txt') | Out-Null" 2>@1} out]
puts "PowerShell made a file there: rc=$rc out=[string trim $out]   Tcl sees it: [file exists $d/made.txt]   folder lists: [glob -nocomplain -tails -directory $d *]"
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath [string map {' ''} \"'[file nativename [tmpdir]]'\"] | ForEach-Object { \$_.Name } " 2>@1} out]
puts "temp folder as PowerShell lists it: [string map {\n { | }} [string trim [string range $out 0 600]]]"
# 5. Tcl-side: is the name really U+00E9 on disk? (a wide-API build lists it back with the same code point)
foreach n [glob -nocomplain -tails -directory [tmpdir] {diag caf*}] { set codes {} ; foreach c [split $n {}] { lappend codes [scan $c %c] } ; puts "Tcl lists: [join $codes ,]" }
file delete -force $d
unset ::env(MKS_DIAG)
puts "0 passed, 0 failed"
exit 0
