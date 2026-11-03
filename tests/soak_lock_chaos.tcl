# Lock chaos soak:   tclkit tests/soak_lock_chaos.tcl <rounds> [seconds-per-round]
# The chaos part of test_lock_crash.tcl, repeated, with every violation printed in full and the raw logs kept - to find out how
# often (if ever) two live processes hold the write lock at once, and by which route each acquired it.  Used by the manual
# "lock soak" CI job; not part of the normal suite.
#   MKS_CHAOS_REAL_LIMITS=1   keep the real abandonment limits (5 s / 10 s) instead of the test's 1 s - what a user would run
#   MKS_CHAOS_STALL=1         also freeze random processes (SIGSTOP) for 1.3 s at a time
#   MKS_CHAOS_KEEP=<dir>      copy each round's log there
# Exit status 0 always: the output is the result.  Lines:  ROUND n ... ; VIOLATION ... ; SUMMARY ...
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv rounds secs
if {$rounds eq ""} { set rounds 5 }
if {$secs eq ""} { set secs 15 }
set kit [info nameofexecutable]
set real [info exists ::env(MKS_CHAOS_REAL_LIMITS)]
if {!$real} {
    set ::env(MKS_LOCK_EMPTY_STALE) 1 ; set ::env(MKS_LOCK_MUTEX_STALE) 1
    set ::store::emptyStale 1 ; set ::store::mutexStale 1
}
set doStall [expr {[info exists ::env(MKS_CHAOS_STALL)] && $::tcl_platform(platform) ne "windows"}]
set db [tmp lockchaos_soak.mk]
proc killpid {pid} { catch {exec kill -9 $pid} }
puts "soak: $rounds rounds of $secs s; limits [expr {$real ? {REAL (5 s / 10 s)} : {shortened (1 s / 1 s)}}]; stall [expr {$doStall ? {on} : {off}}]; Tcl [info patchlevel] on $::tcl_platform(os) $::tcl_platform(machine)"
set totalViol 0 ; set totalSlow 0 ; set totalWins 0 ; set routes [dict create]
for {set r 1} {$r <= $rounds} {incr r} {
    foreach f [glob -nocomplain $db*] { file delete $f }
    set t [store::openFile $db -create] ; store::commit $t ; store::closeFile $t
    set log [tmp lockchaos_soak.log] ; set stop [tmp lockchaos_soak.stop]
    file delete $log $stop $db.inside
    proc spawn {} { global kit here db log stop ; return [exec $kit $here/lock_chaos_child.tcl $db $log $stop &] }
    set pids {}
    for {set k 0} {$k < 8} {incr k} { lappend pids [spawn] }
    set end [expr {[clock milliseconds] + $secs * 1000}]
    expr {srand($r * 7)}
    set stalled {} ; set kills 0
    while {[clock milliseconds] < $end} {
        after 120
        set i [expr {int(rand() * [llength $pids])}]
        killpid [lindex $pids $i] ; incr kills
        set pids [lreplace $pids $i $i [spawn]]
        if {$doStall} {
            set now [clock milliseconds] ; set keep {}
            foreach {p until} $stalled { if {$now >= $until} { catch {exec kill -CONT $p} } else { lappend keep $p $until } }
            set stalled $keep
            if {rand() < 0.35} { set p [lindex $pids [expr {int(rand() * [llength $pids])}]] ; if {![catch {exec kill -STOP $p}]} { lappend stalled $p [expr {$now + 1300}] } }
        }
    }
    foreach {p until} $stalled { catch {exec kill -CONT $p} }
    close [open $stop w]
    after 1500
    foreach p $pids { killpid $p }
    after 300
    set h [open $log r] ; set lines [split [string trim [read $h]] \n] ; close $h
    set wins 0 ; set viol {} ; set slow {}
    foreach l $lines {
        if {[string match "WIN *" $l]} {
            incr wins
            if {[regexp {path=(\S*)} $l -> p]} { dict incr routes $p }
        } elseif {[string match "SLOW *" $l]} { lappend slow $l } elseif {[string match "VIOLATION*" $l]} { lappend viol $l }
    }
    puts "ROUND $r: $kills kills, $wins acquisitions, [llength $viol] violations, [llength $slow] slow acquisitions"
    foreach v $viol { puts "VIOLATION round $r: $v" }
    foreach s $slow { puts "SLOW round $r: $s" }
    if {[llength $viol] && [info exists ::env(MKS_CHAOS_KEEP)]} {
        file mkdir $::env(MKS_CHAOS_KEEP)
        file copy -force $log [file join $::env(MKS_CHAOS_KEEP) chaos-round$r.log]
    }
    incr totalViol [llength $viol] ; incr totalSlow [llength $slow] ; incr totalWins $wins
}
puts "routes taken by acquisitions:"
dict for {p n} $routes { puts "  $n x $p" }
puts "SUMMARY: $rounds rounds, $totalWins acquisitions, $totalViol violations, $totalSlow slow"
exit 0
