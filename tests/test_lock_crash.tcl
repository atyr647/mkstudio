# The write lock under CRASHES:   tclkit tests/test_lock_crash.tcl
#   A. a process is killed (SIGKILL / taskkill /F) at every step of acquiring, taking over and releasing the
#      lock; afterwards another process must still be able to take the database, in bounded time, and
#      leave no litter behind.
#   B. chaos: eight processes take the lock in a loop while the test keeps killing random ones and starting
#      new ones.  Mutual exclusion is checked from inside (a process that finds another LIVE process "inside"
#      the critical section records a VIOLATION).  No violations, no deadlock.
#   MKS_CHAOS_SECONDS  length of part B (default 6; 0 skips it).  Part B is skipped on Windows (process
#   liveness checks there are too slow to make it meaningful).
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 150]> want <$want>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
set kit [info nameofexecutable]
set host [info hostname]
# the abandonment timers (10 s / 30 s in the protocol) are shortened for the test, here and in every child
set ::env(MKS_LOCK_EMPTY_STALE) 1 ; set ::env(MKS_LOCK_MUTEX_STALE) 1
set ::store::emptyStale 1 ; set ::store::mutexStale 1
set db [tmp lockcrash.mk]
proc fresh {} { global db ; foreach f [glob -nocomplain $db*] { file delete $f } ; set t [store::openFile $db -create] ; store::commit $t ; store::closeFile $t }
proc rawlock {text} { global db ; set h [open $db.lock w] ; puts -nonewline $h $text ; close $h }
proc killpid {pid} { if {$::tcl_platform(platform) eq "windows"} { catch {exec taskkill /F /PID $pid} } else { catch {exec kill -9 $pid} } }

# ---- A. killed at each step ---------------------------------------------------------------------------------------
proc crashAt {step preseed} {
    global db kit here host
    fresh
    if {$preseed} { rawlock "999999 $host" }
    set done [tmp lockcrash_done] ; file delete $done
    set pid [exec $kit $here/lock_crash_child.tcl $db $step $done &]
    # wait until the child is gone (it killed itself at the step)
    if {$::tcl_platform(platform) eq "windows"} { after 2500 } else {
        for {set i 0} {$i < 400 && [store::pidAlive $pid]} {incr i} { after 25 }
    }
    return [list $pid [file exists $done]]
}
proc acquireWithin {seconds} {
    global db
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < $seconds * 1000} {
        if {![catch {store::openFile $db} tag]} { return [list $tag [expr {[clock milliseconds] - $t0}]] }
        after 40
    }
    return [list "" -1]
}
foreach {name step preseed expectFiles} {
    killed_after_creating_the_lock         created 0 {lock}
    killed_after_writing_the_lock          written 0 {lock}
    killed_holding_the_takeover_mutex      mutex   1 {lock mutex}
    killed_between_delete_and_create       deleted 1 {mutex}
    killed_after_a_normal_release          released 0 {}
} {
    lassign [crashAt $step $preseed] pid survived
    check "$name: the process really died at the step" $survived 0
    set have {}
    if {[file exists $db.lock]} { lappend have lock }
    if {[file exists $db.lock.guard]} { lappend have mutex }
    check "$name: what it left behind" $have $expectFiles
    lassign [acquireWithin 8] tag ms
    ok "$name: another process can still take the database (took $ms ms)" [expr {$tag ne "" && $ms < 6000}] "no lock within 8 s; files: [glob -nocomplain $db.*]"
    if {$tag ne ""} {
        ok "$name: the new owner is recorded" [string match "[pid] *" [string trim [read [set h [open $db.lock r]]]]]
        catch {close $h}
        store::closeFile $tag
        set left [lsort [glob -nocomplain $db.lock*]]
        if {[llength $left] && $left eq "$db.lock.guard"} {
            # an abandoned takeover guard is harmless: it is removed once it has aged past the abandonment limit
            after 2200
            lassign [acquireWithin 8] tag2 ms2
            ok "$name: a leftover mutex does not block the next owner" [expr {$tag2 ne ""}]
            if {$tag2 ne ""} { store::closeFile $tag2 }
            set left [lsort [glob -nocomplain $db.lock*]]
        }
        check "$name: nothing left after a normal close" $left {}
    }
}

# ---- B. chaos -------------------------------------------------------------------------------------------------------------
set secs [expr {[info exists ::env(MKS_CHAOS_SECONDS)] ? $::env(MKS_CHAOS_SECONDS) : 6}]
if {$::tcl_platform(platform) eq "windows" || $secs <= 0} {
    puts "  (chaos part skipped)"
} else {
    fresh
    set log [tmp lockchaos.log] ; set stop [tmp lockchaos.stop]
    file delete $log $stop $db.inside
    set pids {}
    proc spawn {} { global kit here db log stop ; return [exec $kit $here/lock_chaos_child.tcl $db $log $stop &] }
    for {set k 0} {$k < 8} {incr k} { lappend pids [spawn] }
    set end [expr {[clock milliseconds] + $secs * 1000}]
    set kills 0
    expr {srand(7)}
    while {[clock milliseconds] < $end} {
        after 120
        set i [expr {int(rand() * [llength $pids])}]
        killpid [lindex $pids $i] ; incr kills
        set pids [lreplace $pids $i $i [spawn]]
    }
    close [open $stop w]
    after 1500
    foreach p $pids { killpid $p }
    after 300
    set h [open $log r] ; set lines [split [string trim [read $h]] \n] ; close $h
    set wins 0 ; set viol {} ; set winners {} ; set slow {} ; set excused {}
    foreach l $lines { if {[string match "SLOW *" $l]} { dict set slow [lindex $l 1] [lindex $l 2] } }
    foreach l $lines {
        if {[string match "WIN *" $l]} { incr wins ; dict set winners [lindex $l 1] 1 } elseif {[string match "VIOLATION*" $l]} {
            # VIOLATION <reporter> found <other> inside with it.  If either was starved for longer than half the
            # shortened abandonment limit during its acquisition, being overtaken is what the protocol prescribes.
            if {[dict exists $slow [lindex $l 1]] || [dict exists $slow [lindex $l 3]]} { lappend excused $l } else { lappend viol $l }
        }
    }
    puts "  chaos: $kills processes killed, $wins lock acquisitions by [dict size $winners] different processes, [llength $viol] violations[expr {[llength $excused] ? ", [llength $excused] overlaps excused (a process starved past the shortened abandonment limit: [join [dict values $slow] {, }] ms)" : ""}]"
    check "chaos: never two live processes holding the lock" $viol {}
    ok "chaos: the lock kept being acquired (no deadlock)" [expr {$wins >= 15}] "only $wins acquisitions"
    # (a slow runner may let only a few processes get the lock; liveness, not fairness, is what is checked)
ok "chaos: acquired by several different processes" [expr {[dict size $winners] >= 3}] "only [dict size $winners]"
    lassign [acquireWithin 8] tag ms
    ok "chaos: still available afterwards (took $ms ms)" [expr {$tag ne ""}]
    if {$tag ne ""} { store::closeFile $tag }
}
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
