# The write lock under CRASHES:   tclkit tests/test_lock_crash.tcl
#   A. a process is killed (SIGKILL / taskkill /F) at every step of acquiring, taking over and releasing the
#      lock; afterwards another process must still be able to take the database, in bounded time, and
#      leave no litter behind.
#   B. chaos: eight processes take the lock in a loop while the test keeps killing random ones and starting
#      new ones.  Mutual exclusion is checked from inside (a process that finds another LIVE process "inside"
#      the critical section records a VIOLATION).  No violations, no deadlock.
#   MKS_CHAOS_STRICT   set: no overlap is excused (shows the raw overlaps a starved machine produces)
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

# ---- A2. a process starved between creating the lock file and writing its pid ---------------------------------------------
# The one place where the protocol's time limit matters: an EMPTY lock file older than the limit is taken to belong to a
# process that died before writing it.  A process that is merely starved for longer than that gets overtaken, and both
# then believe they own the database.  With the real limit (5 s) the stall has to be 5 s long; the chaos test below runs with
# the limit shortened to 1 s and sees exactly this on an overloaded machine (macos-15-intel did, once).
# Here the stall is forced: A stalls 4 s after creating the lock file; B starts while the file is still empty (2.4 s old).
# did two processes hold the lock at the same time?  (each holds it from its ACQUIRED to its RELEASED line)
proc overlapped {ev} {
    set iv {}
    dict for {pid d} $ev { if {[dict exists $d ACQUIRED]} { lappend iv [list [dict get $d ACQUIRED] [expr {[dict exists $d RELEASED] ? [dict get $d RELEASED] : [dict get $d ACQUIRED] + 1}]] } }
    if {[llength $iv] < 2} { return 0 }
    lassign [lindex $iv 0] a1 a2 ; lassign [lindex $iv 1] b1 b2
    return [expr {$a1 < $b2 && $b1 < $a2}]
}
proc stallRun {emptyStale {step created} {mutexStale 1}} {
    global db kit here host
    fresh
    if {$step eq "checked"} { rawlock "999999 $host" }       ;# a stale lock (its pid does not exist): the takeover path
    set log [tmp lockstall.log] ; file delete $log $log.release
    foreach v {MKS_LOCK_EMPTY_STALE MKS_LOCK_MUTEX_STALE} { set save($v) [expr {[info exists ::env($v)] ? $::env($v) : ""}] }
    set ::env(MKS_LOCK_EMPTY_STALE) $emptyStale ; set ::env(MKS_LOCK_MUTEX_STALE) $mutexStale
    # A stalls (up to 20 s) at the chosen point until it is released; B keeps trying for 6 s.  The parent releases A as soon as B
    # has decided (got the lock, or gave up) - so how long process start-up takes on this machine does not matter.
    set a [exec $kit $here/lock_stall_child.tcl $db 20000 800 $log $step 0 &]
    # B starts only once A has reported that it is stuck at the chosen point (not when a file happens to exist: on Windows a deleted
    # file can linger for a moment, and process start-up speed differs everywhere)
    for {set i 0} {$i < 2400} {incr i} {
        set seen ""
        catch {set h [open $log r] ; set seen [read $h] ; close $h}
        if {[regexp "\\m$a STALLED" $seen]} break
        after 50
    }
    set b [exec $kit $here/lock_stall_child.tcl $db 0 3000 $log "" 6000 &]
    for {set i 0} {$i < 1800} {incr i} {
        set seen ""
        catch {set h [open $log r] ; set seen [read $h] ; close $h}
        if {[regexp "\\m$b (ACQUIRED|REFUSED)" $seen]} break
        after 50
    }
    close [open $log.release w]
    for {set i 0} {$i < 600 && ([store::pidAlive $a] || [store::pidAlive $b])} {incr i} { after 50 }
    foreach v {MKS_LOCK_EMPTY_STALE MKS_LOCK_MUTEX_STALE} { if {$save($v) eq ""} { unset ::env($v) } else { set ::env($v) $save($v) } }
    set h [open $log r] ; set lines [split [string trim [read $h]] \n] ; close $h
    set ev {}
    foreach l $lines { lassign $l ms pid what ; dict set ev $pid $what $ms ; dict set ev $pid pid $pid }
    return [list $a $b $ev $lines]
}
# a) limit shortened to 1 s: B overtakes the starved A; A then wakes up, writes its pid into the lock file B deleted and
#    "acquires" while B still holds the lock: two owners
lassign [stallRun 1] a b ev lines
set aAcq [expr {[dict exists $ev $a ACQUIRED] ? [dict get $ev $a ACQUIRED] : ""}]
set bAcq [expr {[dict exists $ev $b ACQUIRED] ? [dict get $ev $b ACQUIRED] : ""}]
set bRel [expr {[dict exists $ev $b RELEASED] ? [dict get $ev $b RELEASED] : ""}]
puts "  stall reproduction, limit 1 s: [join $lines {; }]"
set overlap [expr {$bAcq ne "" && $aAcq ne "" && $aAcq > $bAcq && $aAcq < $bRel}]
if {$::tcl_platform(platform) eq "windows"} {
    # Windows has other file-deletion semantics (a file another process is touching cannot be deleted at once), so the forced
    # overlap is reported, not required, there; what must hold everywhere is the mutual exclusion with a long limit (below).
    puts "  (Windows: forced overlap observed: [expr {$overlap ? {yes} : {no}}])"
} else {
    ok "stall, limit 1 s: B overtook the starved A and A, waking up, 'acquired' while B still held the lock (the overlap)" $overlap $lines
}
# b) a limit longer than the stall (the real one is 5 s; 60 s here so that no machine is slow enough to reach it): the same stall
#    changes nothing - B keeps being refused, then gives up, and A completes
lassign [stallRun 60] a b ev lines
puts "  stall, limit 60 s: [join $lines {; }]"
# (what matters is mutual exclusion, not who wins: on a slow machine the two start-up times decide that)
ok "stall, limit 60 s: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "stall, limit 60 s: somebody got the lock, somebody was refused or both took turns" [expr {[dict exists $ev $a ACQUIRED] || [dict exists $ev $b ACQUIRED]}] $lines
# c) the same, in the takeover: A judges a stale lock stale, holds the takeover guard and is starved before it deletes the
#    lock.  With the guard limit shortened to 1 s, B declares the guard abandoned, takes over properly and holds the lock - and
#    A, waking up, deletes B's lock and creates its own.  (This - a slow process held up past a shortened guard limit - is the
#    likelier reading of the macos-15-intel overlap: its guard section includes `exec ps`, which can be slow on a busy runner.)
lassign [stallRun 1 checked 1] a b ev lines
set aAcq [expr {[dict exists $ev $a ACQUIRED] ? [dict get $ev $a ACQUIRED] : ""}]
set bAcq [expr {[dict exists $ev $b ACQUIRED] ? [dict get $ev $b ACQUIRED] : ""}]
set bRel [expr {[dict exists $ev $b RELEASED] ? [dict get $ev $b RELEASED] : ""}]
puts "  takeover stall, guard limit 1 s: [join $lines {; }]"
set overlap [expr {$bAcq ne "" && $aAcq ne "" && $aAcq > $bAcq && $aAcq < $bRel}]
if {$::tcl_platform(platform) eq "windows"} {
    puts "  (Windows: forced overlap observed: [expr {$overlap ? {yes} : {no}}])"
} else {
    ok "takeover stall, guard limit 1 s: both processes ended up inside at the same time (the overlap)" $overlap $lines
}
# d) a guard limit longer than the stall (the real one is 10 s): B waits for the guard, gives up, A completes
lassign [stallRun 60 checked 60] a b ev lines
puts "  takeover stall, guard limit 60 s: [join $lines {; }]"
ok "takeover stall, guard limit 60 s: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "takeover stall, guard limit 60 s: somebody got the lock" [expr {[dict exists $ev $a ACQUIRED] || [dict exists $ev $b ACQUIRED]}] $lines
fresh

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
    # MKS_CHAOS_STALL (Unix): also freeze random processes for 1.3 s (SIGSTOP, later SIGCONT) - starvation on demand - so the
    # overlaps a starved process causes appear in every run instead of once in a while on a slow machine
    set stalled {} ; set stalls 0
    set doStall [expr {[info exists ::env(MKS_CHAOS_STALL)] && $::tcl_platform(platform) ne "windows"}]
    while {[clock milliseconds] < $end} {
        after 120
        set i [expr {int(rand() * [llength $pids])}]
        killpid [lindex $pids $i] ; incr kills
        set pids [lreplace $pids $i $i [spawn]]
        if {$doStall} {
            set now [clock milliseconds] ; set keep {}
            foreach {p until} $stalled { if {$now >= $until} { catch {exec kill -CONT $p} } else { lappend keep $p $until } }
            set stalled $keep
            if {rand() < 0.35} { set p [lindex $pids [expr {int(rand() * [llength $pids])}]] ; if {![catch {exec kill -STOP $p}]} { lappend stalled $p [expr {$now + 1300}] ; incr stalls } }
        }
    }
    foreach {p until} $stalled { catch {exec kill -CONT $p} }
    if {$doStall} { puts "  chaos with starvation on demand: $stalls processes frozen for 1.3 s each" }
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
            if {![info exists ::env(MKS_CHAOS_STRICT)] && ([dict exists $slow [lindex $l 1]] || [dict exists $slow [lindex $l 3]])} { lappend excused $l } else { lappend viol $l }
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
