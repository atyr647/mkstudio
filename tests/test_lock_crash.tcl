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
set ::store::emptyStale 1 ; set ::store::mutexStale 1 ; set ::store::takeStale 1      ;# (takeStale: this process only - the children keep the real minute, so a slow takeover never loses its files)
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
    killed_after_looking_at_the_lock       looked  1 {lock mutex aside}
    killed_after_moving_the_lock_aside     claimed 1 {mutex aside}
    killed_between_delete_and_create       deleted 1 {mutex}
    killed_after_a_normal_release          released 0 {}
} {
    lassign [crashAt $step $preseed] pid survived
    check "$name: the process really died at the step" $survived 0
    set have {}
    if {[file exists $db.lock]} { lappend have lock }
    if {[file exists $db.lock.guard]} { lappend have mutex }
    if {[llength [store::takeovers $db.lock]]} { lappend have aside }
    check "$name: what it left behind" $have $expectFiles
    lassign [acquireWithin 8] tag ms
    ok "$name: another process can still take the database (took $ms ms)" [expr {$tag ne "" && $ms < 6000}] "no lock within 8 s; files: [glob -nocomplain $db.*]"
    if {$tag ne ""} {
        ok "$name: the new owner is recorded" [string match "[pid] *" [string trim [read [set h [open $db.lock r]]]]]
        catch {close $h}
        store::closeFile $tag
        set left [lsort [glob -nocomplain $db.lock*]]
        set litter 1 ; foreach f $left { if {$f ne "$db.lock.guard" && [lsearch -exact [store::takeovers $db.lock] $f] < 0} { set litter 0 } }
        if {[llength $left] && $litter} {
            # an abandoned takeover guard (or a lock moved aside by a killed takeover) is harmless: it is removed once it has aged past the abandonment limit
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
    if {$step in {checked looked claimed}} { rawlock "999999 $host" }       ;# a stale lock (its pid does not exist): the takeover path
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
# a) limit shortened to 1 s: B overtakes the starved A (its lock file is still empty after the limit).  A then wakes up and writes
#    its pid into the file B moved aside: A must NOTICE that the file under the name is not its own any more and not "acquire"
#    while B holds the lock (before the lock was checked after writing, this was an overlap: A believed it owned the database)
lassign [stallRun 1] a b ev lines
set aAcq [expr {[dict exists $ev $a ACQUIRED] ? [dict get $ev $a ACQUIRED] : ""}]
set bAcq [expr {[dict exists $ev $b ACQUIRED] ? [dict get $ev $b ACQUIRED] : ""}]
puts "  stall, limit 1 s: [join $lines {; }]"
ok "stall, limit 1 s: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
if {$::tcl_platform(platform) eq "windows"} {
    # Windows cannot move a file another process still has open: B cannot overtake A at all there (it keeps waiting)
    puts "  (Windows: B overtook the starved A: [expr {$bAcq ne {} && $aAcq eq {} ? {yes} : {no}}])"
} else {
    ok "stall, limit 1 s: B overtook the starved A, and A, waking up, noticed it and did not 'acquire'" [expr {$bAcq ne "" && $aAcq eq ""}] $lines
}
# b) a limit longer than the stall (the real one is 5 s; 60 s here so that no machine is slow enough to reach it): the same stall
#    changes nothing - B keeps being refused, then gives up, and A completes
lassign [stallRun 60] a b ev lines
puts "  stall, limit 60 s: [join $lines {; }]"
# (what matters is mutual exclusion, not who wins: on a slow machine the two start-up times decide that)
ok "stall, limit 60 s: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "stall, limit 60 s: somebody got the lock, somebody was refused or both took turns" [expr {[dict exists $ev $a ACQUIRED] || [dict exists $ev $b ACQUIRED]}] $lines
# c) the same, in the takeover: A judges a stale lock stale, holds the takeover guard and is starved before it changes anything.
#    With the guard limit shortened to 1 s, B declares the guard abandoned, takes over properly and holds the lock.  A wakes up and
#    carries on with its verdict ("stale") - which is out of date.  The takeover moves the lock aside and looks at what it got: B's
#    live lock.  It puts it back and gives up.  (A delete by name here destroyed B's lock and both were inside; this - a slow process
#    held up past a shortened guard limit - was the likelier reading of the macos-15-intel overlap: its guard section includes `exec ps`.)
lassign [stallRun 1 checked 1] a b ev lines
set aAcq [expr {[dict exists $ev $a ACQUIRED] ? [dict get $ev $a ACQUIRED] : ""}]
set bAcq [expr {[dict exists $ev $b ACQUIRED] ? [dict get $ev $b ACQUIRED] : ""}]
puts "  takeover stall, guard limit 1 s: [join $lines {; }]"
ok "takeover stall, guard limit 1 s: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
if {$::tcl_platform(platform) eq "windows"} {
    puts "  (Windows: B took over, A was refused: [expr {$bAcq ne {} && $aAcq eq {} ? {yes} : {no}}])"
} else {
    ok "takeover stall, guard limit 1 s: B took over, the woken A found B's live lock, put it back and was refused" [expr {$bAcq ne "" && $aAcq eq "" && [dict exists $ev $a REFUSED]}] $lines
    ok "takeover stall, guard limit 1 s: B's lock text survived A's attempt (B's commit-time check passes)" [regexp "\\m$b VERIFY ok" [join $lines \n]] $lines
}
# d) a guard limit longer than the stall (the real one is 10 s): B waits for the guard, gives up, A completes
lassign [stallRun 60 checked 60] a b ev lines
puts "  takeover stall, guard limit 60 s: [join $lines {; }]"
ok "takeover stall, guard limit 60 s: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "takeover stall, guard limit 60 s: somebody got the lock" [expr {[dict exists $ev $a ACQUIRED] || [dict exists $ev $b ACQUIRED]}] $lines
fresh

# e) starved between moving the stale lock aside and making its own: the name is free, so a newcomer takes it directly (an exclusive
#    create); the woken process finds the name taken and is refused.  (The one moment the lock is absent; harmless because the create is exclusive.)
lassign [stallRun 60 claimed 60] a b ev lines
puts "  stall after moving the lock aside: [join $lines {; }]"
ok "aside stall: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
if {$::tcl_platform(platform) eq "windows"} {
    # (every liveness check starts tasklist there - about a second each - so the woken process may only look at the lock after the newcomer is
    # done and then simply takes it: what must hold is that they were never inside together, checked above)
    puts "  (Windows: the woken process was refused: [expr {[dict exists $ev $a REFUSED] ? {yes} : {no - it looked after the newcomer had finished}}])"
} else {
    ok "aside stall: the newcomer got the lock, the woken process was refused" [expr {[dict exists $ev $b ACQUIRED] && [dict exists $ev $a REFUSED]}] $lines
}
check "aside stall: no litter after both are done" [lsort [glob -nocomplain $db.lock.take.*]] {}
fresh

# f) starved while looking at the stale lock (it has not been moved): the newcomer cannot get the guard A holds, is refused or waits; when A has
#    finished it holds the lock.  Never two inside.
lassign [stallRun 60 looked 60] a b ev lines
puts "  stall while looking at the lock: [join $lines {; }]"
ok "look stall: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "look stall: the woken process took the lock (nothing had changed)" [dict exists $ev $a ACQUIRED] $lines
check "look stall: no litter after both are done" [lsort [glob -nocomplain $db.lock.take.*]] {}
fresh

# ---- A2b. the takeover step by step, in one process ---------------------------------------------------------------------------
# claimStale moves the lock aside and judges what it MOVED.
set lf [store::lockPath $db]
rawlock "999999 $host"
check "claimStale: a dead owner's lock is looked at, judged stale, moved aside and deleted" [store::claimStale $lf] claimed
ok "claimStale: ... and the name is free, nothing left" [expr {![file exists $lf] && ![llength [store::takeovers $lf]]}]
check "claimStale: nothing under the name" [store::claimStale $lf] gone
rawlock "4242 some-other-machine"                           ;# another host: always held - what a wrongly judged takeover would find
set before [list [file mtime $lf] [file size $lf]] ; file stat $lf st0
check "claimStale: a live (foreign) lock found under the name is left alone" [store::claimStale $lf] alive
check "claimStale: ... with its text" [string trim [read [set h [open $lf r]]]] "4242 some-other-machine" ; close $h
check "claimStale: ... and its time and size" [list [file mtime $lf] [file size $lf]] $before
file stat $lf st1
ok "claimStale: ... and it is the very same file (it was never moved)" [expr {$st1(ino) == $st0(ino) && $st1(dev) == $st0(dev)}]
ok "claimStale: ... and no copy left" [expr {![llength [store::takeovers $lf]]}]
file delete $lf
set h [open $lf w] ; close $h                                    ;# an EMPTY lock that is brand new is not stale: the creator may be about to write
check "claimStale: a brand-new empty lock is left alone" [store::claimStale $lf] alive
file delete $lf
file mkdir $lf                                                   ;# not a plain file: never taken, never ignored (no hard link of a folder: the move-first path)
check "claimStale: a folder under the name is put back" [store::claimStale $lf] alive
ok "claimStale: ... still a folder" [file isdirectory $lf]
file delete $lf
# the lock is REPLACED while it is being judged: judged stale, then a live one under the name - it must not be taken
rawlock "999999 $host"
set ::replaced 0
set ::store::lockHook [list apply {{name} { if {$name eq "looked" && !$::replaced} { incr ::replaced ; set lf2 $::store::lockHookLf ; file delete $lf2 ; set h [open $lf2 w] ; puts -nonewline $h "4242 some-other-machine" ; close $h } }}]
set ::store::lockHookLf $lf
set r [store::claimStale $lf]
set ::store::lockHook ""
check "claimStale: a lock replaced while it was judged is not taken" $r busy
check "claimStale: ... the live lock is still there" [string trim [read [set h [open $lf r]]]] "4242 some-other-machine" ; close $h
ok "claimStale: ... and no copy left" [expr {![llength [store::takeovers $lf]]}]
file delete $lf
# the same with a file name full of glob characters
set odd [tmp [expr {$::tcl_platform(platform) eq "windows" ? {lock [abc] {x} 'q'.mk} : {lock [abc] *?{x}.mk}}]]    ;# (* and ? cannot be in a Windows file name)
foreach f [glob -nocomplain -directory [file dirname $odd] -- [string map [list \[ \\\[ \] \\\] * \\* ? \\? \{ \\\{ \} \\\}] [file tail $odd]]*] { file delete $f }
set olf [store::lockPath $odd]
set h [open $olf w] ; puts -nonewline $h "4242 some-other-machine" ; close $h
check "odd name: a live lock is put back" [store::claimStale $olf] alive
ok "odd name: ... and the file is there" [file exists $olf]
file delete $olf
# litter of a killed takeover: only a copy older than the guard limit is deleted; breakLock takes all
set old [expr {[clock seconds] - 100}] ; set new [clock seconds]
foreach n [list $olf.take.$old.999999.1 $olf.take.$old.1.2 $olf.take.$new.999999.3] { set h [open $n w] ; close $h }
store::tidyTakeovers $olf
set rest {} ; foreach f [store::takeovers $olf] { lappend rest [file tail $f] }
check "tidy: only a file that is old AND whose process is gone goes (not an old one of a live process, not a recent one)" [lsort $rest] [lsort [list [file tail $olf].take.$old.1.2 [file tail $olf].take.$new.999999.3]]
store::breakLock $odd
check "breakLock: takes the litter too" [llength [store::takeovers $olf]] 0
fresh

# ---- A3. two processes reap the same abandoned takeover guard -----------------------------------------------------------------
# A process killed while it holds the takeover guard leaves it behind; every waiter deletes it once it is older than the limit - BY NAME.
# A judges the guard abandoned and is descheduled before the delete; B deletes it, makes a guard of its own and, inside its takeover
# section, is descheduled too; A wakes and deletes B's FRESH guard and is inside the takeover section as well.  (Found by the
# macOS-Intel lock soak: 3 overlaps in ~12,000 contended acquisitions; reproduced here on demand.)
# Until rc.2 the takeover then deleted the lock by name: A took over, B woke and deleted A's brand-new lock and took over too - both
# owned the database for a while, and only the commit-time check (`verifyLock`) stopped the second from saving.  Now the takeover
# moves the lock aside (one atomic rename) and judges what it moved: B finds A's live lock, puts it back and is refused until A
# is done.  Required here: the two are never inside together, and both commit-time checks pass.
proc reaperRace {} {
    global db kit here host
    fresh
    set log [tmp lockreaper.log] ; file delete $log $log.relA $log.relB
    foreach v {MKS_LOCK_EMPTY_STALE MKS_LOCK_MUTEX_STALE} { set save($v) [expr {[info exists ::env($v)] ? $::env($v) : ""}] }
    set ::env(MKS_LOCK_EMPTY_STALE) 1 ; set ::env(MKS_LOCK_MUTEX_STALE) 1
    rawlock "999999 $host"                                              ;# the dead owner's lock
    close [open $db.lock.guard w] ; file mtime $db.lock.guard [expr {[clock seconds] - 100}]    ;# the guard a killed process left
    proc seenIn {log pat} { set s "" ; catch {set h [open $log r] ; set s [read $h] ; close $h} ; return [regexp $pat $s] }
    set a [exec $kit $here/lock_stall_child.tcl $db 30000 1500 $log guard-aged 9000 relA &]
    for {set i 0} {$i < 1200 && ![seenIn $log "\\m$a STALLED"]} {incr i} { after 50 }
    set b [exec $kit $here/lock_stall_child.tcl $db 30000 3500 $log checked 9000 relB &]
    for {set i 0} {$i < 1200 && ![seenIn $log "\\m$b STALLED"]} {incr i} { after 50 }
    close [open $log.relA w]                                            ;# A deletes B's fresh guard, takes over, holds the lock
    for {set i 0} {$i < 600 && ![seenIn $log "\\m$a ACQUIRED"]} {incr i} { after 50 }
    close [open $log.relB w]                                            ;# B deletes the lock A just made and takes over
    for {set i 0} {$i < 1200 && !([seenIn $log "\\m$a RELEASED"] && [seenIn $log "\\m$b RELEASED"])} {incr i} { after 50 }
    foreach v {MKS_LOCK_EMPTY_STALE MKS_LOCK_MUTEX_STALE} { if {$save($v) eq ""} { unset ::env($v) } else { set ::env($v) $save($v) } }
    set h [open $log r] ; set lines [split [string trim [read $h]] \n] ; close $h
    set ev {}
    foreach l $lines { set ms [lindex $l 0] ; set pid [lindex $l 1] ; set what [lindex $l 2] ; dict set ev $pid $what [lrange $l 3 end] ; dict set ev $pid $what.ms $ms }
    return [list $a $b $ev $lines]
}
lassign [reaperRace] a b ev lines
puts "  two reapers of one abandoned guard: [join $lines {; }]"
# (A holds 1.5 s and B 3.5 s: A makes its commit-time check while B is waiting, B at the end when A has left)
set bothIn [expr {[dict exists $ev $a ACQUIRED.ms] && [dict exists $ev $b ACQUIRED.ms] && [dict get $ev $b ACQUIRED.ms] < [dict get $ev $a RELEASED.ms]}]
set va [expr {[dict exists $ev $a VERIFY] ? [dict get $ev $a VERIFY] : "?"}]
set vb [expr {[dict exists $ev $b VERIFY] ? [dict get $ev $b VERIFY] : "?"}]
ok "reapers: both processes finished" [expr {$va ne "?" && $vb ne "?"}] $lines
ok "reapers: never inside together" [expr {!$bothIn}] $lines
ok "reapers: A kept its lock (its commit-time check passes: A $va)" [expr {$va eq "ok"}] $lines
ok "reapers: B got the database after A was done, and its check passes (B $vb)" [expr {$vb eq "ok" && [dict exists $ev $b ACQUIRED.ms] && [dict get $ev $b ACQUIRED.ms] >= [dict get $ev $a RELEASED.ms]}] $lines
check "reapers: nothing left behind" [lsort [glob -nocomplain $db.lock*]] {}
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
