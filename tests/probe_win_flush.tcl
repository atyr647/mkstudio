# Probe (Windows, throwaway): can ONE long-lived PowerShell serve every flush of an editing session, and how fast is it?
# Compares: (a) the current way - a new PowerShell per flush; (b) a helper fed through its stdin; (c) a helper that polls a request file.
# Answers come back through files (a GUI program has no console to read from).  Prints, never fails.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
puts "Tcl [info patchlevel]"
set work [tmp mks_probe_flush] ; file delete -force $work ; file mkdir $work
set target $work/data.mk ; set h [open $target wb] ; puts -nonewline $h [string repeat x 100000] ; close $h
proc q {s} { return "'[string map {' ''} $s]'" }
# (a) one PowerShell per flush (what store::syncWindows does)
set t0 [clock milliseconds] ; set n 5
for {set i 0} {$i < $n} {incr i} { lassign [store::psRun "\$s=\[IO.File\]::Open([q [file nativename $target]],'Open','ReadWrite','ReadWrite'); try{ \$s.Flush(\$true) } finally{ \$s.Dispose() }"] ran ok out ; if {!$ok} { puts "  (a) flush $i failed" } }
puts "(a) a new PowerShell per flush: [expr {([clock milliseconds] - $t0) / $n}] ms each ($n flushes)"
# (c) a helper that polls for request files
set ack $work/ack ; file mkdir $work/req
set script "\$req=[q [file nativename $work/req]]; \$ack=[q [file nativename $ack]]; New-Item -ItemType File -Force -Path (Join-Path \$ack 'started') | Out-Null
for(;;){ foreach(\$f in Get-ChildItem -LiteralPath \$req -Filter *.txt){ \$p=(Get-Content -LiteralPath \$f.FullName -Raw).Trim(); Remove-Item -LiteralPath \$f.FullName -Force
 try{ \$s=\[IO.File\]::Open(\$p,'Open','ReadWrite','ReadWrite'); try{ \$s.Flush(\$true) } finally{ \$s.Dispose() }; \$r='ok' } catch { \$r='fail ' + \$_.Exception.Message }
 Set-Content -LiteralPath (Join-Path \$ack (\$f.BaseName + '.ack')) -Value \$r }
 if(Test-Path -LiteralPath (Join-Path \$req 'quit')){ break }; Start-Sleep -Milliseconds 5 }"
file mkdir $ack
set argv [store::psCommand $script]
set t0 [clock milliseconds]
exec {*}$argv > NUL 2> NUL &
for {set i 0} {$i < 200 && ![file exists $ack/started]} {incr i} { after 50 }
puts "(c) polling helper: started after [expr {[clock milliseconds] - $t0}] ms ([file exists $ack/started])"
set t0 [clock milliseconds] ; set okc 0
for {set i 0} {$i < 20} {incr i} {
    set h [open $work/req/r$i.tmp w] ; puts -nonewline $h [file nativename $target] ; close $h ; file rename $work/req/r$i.tmp $work/req/r$i.txt
    for {set k 0} {$k < 2000 && ![file exists $ack/r$i.ack]} {incr k} { after 2 }
    if {[file exists $ack/r$i.ack]} { set hh [open $ack/r$i.ack r] ; if {[string trim [read $hh]] eq "ok"} { incr okc } ; close $hh }
}
puts "(c) polling helper: [expr {([clock milliseconds] - $t0) / 20.0}] ms per flush round trip, $okc of 20 acknowledged ok"
close [open $work/req/quit w]
# (b) a helper reading commands from its stdin
set script2 {$ErrorActionPreference='Stop'; while(($l = [Console]::In.ReadLine()) -ne $null){ if($l -eq 'quit'){ break }; $p,$a = $l.Split('|'); try{ $s=[IO.File]::Open($p,'Open','ReadWrite','ReadWrite'); try{ $s.Flush($true) } finally{ $s.Dispose() }; Set-Content -LiteralPath $a -Value ok } catch { Set-Content -LiteralPath $a -Value ('fail ' + $_.Exception.Message) } }}
set argv2 [store::psCommand $script2]
if {[catch {set ch [open |$argv2 w]} err]} { puts "(b) stdin helper: could not start: $err" } else {
    fconfigure $ch -buffering line -translation lf
    set t0 [clock milliseconds] ; set okb 0
    for {set i 0} {$i < 20} {incr i} {
        set a $ack/b$i.ack
        puts $ch "[file nativename $target]|[file nativename $a]" ; flush $ch
        for {set k 0} {$k < 3000 && ![file exists $a]} {incr k} { after 2 }
        if {[file exists $a]} { incr okb }
    }
    puts "(b) stdin helper: [expr {([clock milliseconds] - $t0) / 20.0}] ms per flush round trip (first includes start-up), $okb of 20 acknowledged"
    catch {puts $ch quit ; close $ch}
}
file delete -force $work
puts "0 passed, 0 failed"
exit 0
