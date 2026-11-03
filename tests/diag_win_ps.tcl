# Diagnostic (Windows): PowerShell started straight from a GUI-subsystem tclkit does nothing (Tcl starts console programs without a
# console for a program that has none).  Which launcher does work?  Success = the file the command writes appears.
#     <kit>.exe tests/run.tcl tests/diag_win_ps.tcl        Prints, never fails.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
puts "Tcl [info patchlevel]  kit: [info nameofexecutable]"
set root $::env(SystemRoot)
set ps  $root/System32/WindowsPowerShell/v1.0/powershell.exe
set cmdexe $root/System32/cmd.exe
set work [tmp mks_diag3] ; file delete -force $work ; file mkdir $work
set wn [file nativename $work]
# pure Tcl base64 (no 8.6-only commands)
proc b64 {bytes} {
    set tbl ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
    set out "" ; set n [string length $bytes]
    for {set i 0} {$i < $n} {incr i 3} {
        binary scan [string range $bytes $i [expr {$i + 2}]] c* v
        set a [expr {[lindex $v 0] & 255}] ; set b [expr {[llength $v] > 1 ? [lindex $v 1] & 255 : 0}] ; set c [expr {[llength $v] > 2 ? [lindex $v 2] & 255 : 0}]
        set x [expr {($a << 16) | ($b << 8) | $c}]
        append out [string index $tbl [expr {($x >> 18) & 63}]] [string index $tbl [expr {($x >> 12) & 63}]]
        append out [expr {[llength $v] > 1 ? [string index $tbl [expr {($x >> 6) & 63}]] : "="}] [expr {[llength $v] > 2 ? [string index $tbl [expr {$x & 63}]] : "="}]
    }
    return $out
}
proc enc {text} { return [b64 [encoding convertto unicode $text]] }
proc readf {f} { if {![file exists $f]} { return "(no file)" } ; set h [open $f rb] ; set d [read $h] ; close $h ; return [string map {\r {} \n { | }} [string trim $d]] }
proc show {label rc out f} { puts [format "%-52s rc=%d file=%s  out=[string range [string map {\n { | }} [string trim $out]] 0 60]  %s" $label $rc [file exists $f] [expr {[file exists $f] ? [readf $f] : {}}]] }
set base "-NoProfile -NonInteractive -ExecutionPolicy Bypass"
set n 0
proc nf {} { global work n ; incr n ; return $work/f$n.txt }

# 1. straight from Tcl (known not to work) - for the record
set f [nf] ; set b [enc "Set-Content -LiteralPath '[file nativename $f]' -Value direct"]
set rc [catch {exec $ps {*}$base -EncodedCommand $b 2>@1} out] ; show "1 direct, -EncodedCommand" $rc $out $f
# 2. through cmd.exe /c (cmd makes the console), EncodedCommand = no quotes, no spaces, ASCII only
set f [nf] ; set b [enc "Set-Content -LiteralPath '[file nativename $f]' -Value viacmd"]
set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1} out] ; show "2 cmd /c ps -EncodedCommand" $rc $out $f
# 3. same, output captured
set b [enc "Write-Output 'hello from powershell'"]
set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1} out] ; puts "3 captured output: rc=$rc out=[string trim $out]"
# 4. a failing command: does the exit code show it?
set b [enc "Get-Item -LiteralPath 'C:\\no\\such\\thing' -ErrorAction Stop"]
set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1} out] ; puts "4 failing command: rc=$rc (want 1) out=[string range [string map {\n { | }} [string trim $out]] 0 80]"
set b [enc "exit 7"]
set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1} out opts] ; puts "4b exit 7: rc=$rc code=[expr {$rc ? [dict get $opts -errorcode] : {-}}]"
# 5. non-ASCII name inside the encoded command, file made in a folder with spaces, parentheses and an accented letter
set d $work/upd\ real\ (1)\ caf\u00e9 ; file mkdir $d
set f $d/mkstudio\ (1)\ \u00fcber.txt
set b [enc "Set-Content -LiteralPath '[file nativename $f]' -Value unicode"]
set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1} out] ; show "5 accented path via -EncodedCommand" $rc $out $f
puts "   folder lists: [join [glob -nocomplain -tails -directory $d *] { | }]"
# 6. through an open | pipe
set f [nf] ; set b [enc "Set-Content -LiteralPath '[file nativename $f]' -Value piped"]
set ch [open |[list $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1] r] ; set out [read $ch] ; set rc [catch {close $ch}] ; show "6 open | pipe" $rc $out $f
# 7. in the background (the update helper): started, then the test carries on
set f [nf] ; set b [enc "Start-Sleep -Seconds 2; Set-Content -LiteralPath '[file nativename $f]' -Value background"]
set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b > NUL 2> NUL &} out] ; puts "7 background: started rc=$rc, file now: [file exists $f]"
after 5000 ; show "7 background, 5 s later" 0 "" $f
# 8. a flush of a real file, the way store::syncWindows does it
set target $work/flushme.mk ; set h [open $target wb] ; puts -nonewline $h "data" ; close $h
set marker [nf]
set b [enc "\$s=\[IO.File\]::Open('[file nativename $target]','Open','ReadWrite','ReadWrite'); try{ \$s.Flush(\$true) } finally{ \$s.Dispose() }; Set-Content -LiteralPath '[file nativename $marker]' -Value flushed"]
set t0 [clock milliseconds] ; set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1} out] ; show "8 flush ([expr {[clock milliseconds] - $t0}] ms)" $rc $out $marker
# 9. Get-Process start time, as store::procStartTime asks for it
set b [enc "\$p=Get-Process -Id [pid] -ErrorAction Stop; (\[DateTimeOffset\]\$p.StartTime).ToUnixTimeSeconds()"]
set rc [catch {exec $cmdexe /c $ps {*}$base -EncodedCommand $b 2>@1} out] ; puts "9 start time of this process: rc=$rc out=[string trim $out]  now=[clock seconds]"
file delete -force $work
puts "0 passed, 0 failed"
exit 0
