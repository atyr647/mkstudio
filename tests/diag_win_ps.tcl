# Diagnostic (Windows): which way of starting PowerShell from a GUI-subsystem tclkit actually RUNS it?  Success = the file the
# command writes appears.  Prints, never fails.    <kit>.exe tests/run.tcl tests/diag_win_ps.tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
puts "Tcl [info patchlevel]  kit: [info nameofexecutable]  encoding: [encoding system]"
set ps $::env(SystemRoot)/System32/WindowsPowerShell/v1.0/powershell.exe
puts "tmpdir=[tmpdir]  env TEMP=[expr {[info exists ::env(TEMP)] ? $::env(TEMP) : {-}}]  TMPDIR=[expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : {-}}]"
set work [tmp mks_diag2] ; file delete -force $work ; file mkdir $work
puts "work=$work exists=[file isdirectory $work] native=[file nativename $work]"
set wn [file nativename $work]
# PowerShell writing into ITS OWN idea of the temp folder (no path passes from Tcl at all): did it run, which version, any error?
set probeFile $::env(TEMP)/mks_ps_probe.txt ; file delete -force $probeFile
set script {try { $v = $PSVersionTable.PSVersion.ToString(); Set-Content -Path (Join-Path $env:TEMP 'mks_ps_probe.txt') -Value ('ran ' + $v + ' cwd=' + (Get-Location).Path + ' user=' + $env:USERNAME) } catch { Set-Content -Path (Join-Path $env:TEMP 'mks_ps_probe.txt') -Value ('ERROR ' + $_.Exception.Message) }}
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $script 2>@1} out]
puts "self-contained probe: rc=$rc file=[file exists $probeFile] [expr {[file exists $probeFile] ? [string trim [read [set h [open $probeFile r]]]] : {}}]"
catch {close $h}
# the same with a path from Tcl in a plain ASCII folder that certainly exists
set plain $::env(TEMP)/mks_plain.txt ; file delete -force $plain
set rc [catch {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '[file nativename $plain]' -Value ok" 2>@1} out]
puts "path from Tcl, directly in TEMP: rc=$rc file=[file exists $plain]  nativename=[file nativename $plain]"
set n 0
proc probe {label body} {
    global work n
    incr n
    set f $work/p$n.txt
    set t0 [clock milliseconds]
    set res2 ""
    set rc [catch {uplevel 1 [string map [list @F@ [file nativename $f]] $body]} res2]
    set dt [expr {[clock milliseconds] - $t0}]
    puts [format "%-46s file=%s rc=%d %4d ms  %s" $label [file exists $f] $rc $dt [string range [string map {\n { | }} $res2] 0 90]]
}
set cmd "Set-Content -LiteralPath '@F@' -Value ok"
probe "A exec -Command, 2>@1"            {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" 2>@1}
probe "B exec -Command, no redirects"    {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok"}
probe "C exec -Command, > NUL 2> NUL"    {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" > NUL 2> NUL}
probe "D exec -Command, stdin from empty" {exec $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" << "" 2>@1}
probe "E exec without -NonInteractive"   {exec $ps -NoProfile -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" 2>@1}
probe "F exec -WindowStyle Hidden"       {exec $ps -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" 2>@1}
probe "G exec cmd /c powershell"         {exec cmd /c $ps -NoProfile -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" 2>@1}
probe "H exec & (background), then wait"  {exec $ps -NoProfile -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" > NUL 2> NUL & ; after 3000}
probe "I open | pipe, read"              {set ch [open |[list $ps -NoProfile -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" 2>@1] r] ; set d [read $ch] ; catch {close $ch} ; set d}
probe "J open | pipe r+, close write"    {set ch [open |[list $ps -NoProfile -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value ok" 2>@1] r+] ; close $ch write ; set d [read $ch] ; catch {close $ch} ; set d}
probe "K -EncodedCommand"                {set b [binary encode base64 [encoding convertto unicode "Set-Content -LiteralPath '@F@' -Value ok"]] ; exec $ps -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b 2>@1}
set sf $work/s.ps1 ; set h [open $sf w] ; puts $h "Set-Content -LiteralPath \$args\[0\] -Value ok" ; close $h
probe "L -File script.ps1"               {exec $ps -NoProfile -ExecutionPolicy Bypass -File [file nativename $work/s.ps1] @F@ 2>@1}
probe "M cmd.exe writes a file (control)" {exec cmd /c "echo ok > \"@F@\"" 2>@1}
probe "N certutil (control, prints)"      {exec certutil -hashfile $ps SHA256 2>@1}
set ::env(MKS_X) 1
probe "O exec -Command with MKS_X env"   {exec $ps -NoProfile -ExecutionPolicy Bypass -Command "Set-Content -LiteralPath '@F@' -Value \$env:MKS_X" 2>@1}
puts "0 passed, 0 failed"
file delete -force $work
exit 0
