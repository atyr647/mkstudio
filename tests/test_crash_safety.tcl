# Crash-safe editing tests (real Metakit):  tclkit tests/test_crash_safety.tcl
#
# A child process edits and commits a database in a tight loop and the parent kills it
# (SIGKILL / taskkill /F) at awkward moments, then checks that the file is never corrupt
# and never half-committed.  The workload makes a torn commit detectable: every commit
# rewrites ALL rows to one "generation" g with chk = g*100000 + id, so a mixture of
# generations, a bad checksum or a missing row can only come from a partial commit.
#
# Scope (be honest): this exercises PROCESS crashes - the OS survives and flushes what was
# written.  It cannot simulate power loss or a failing disk.
#
#   MKS_CRASH_TRIALS   number of kill trials per scenario (default 25)
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }

set pass 0 ; set fail 0
proc check {name ok {detail ""}} {
    global pass fail
    if {$ok} { incr pass } else { incr fail ; puts "FAIL $name  $detail" }
}
set trials [expr {[info exists ::env(MKS_CRASH_TRIALS)] ? $::env(MKS_CRASH_TRIALS) : 25}]
set rows 2000
set kit [info nameofexecutable]
set childScript [file join $here crash_child.tcl]

proc stamp {g i} { return "[format {g%07d-r%05d} $g $i][string repeat [format %c [expr {97 + ($g + 1000) % 26}]] 1500]" }
proc readfile {f} { if {[catch {set h [open $f rb] ; set d [read $h] ; close $h}]} { return "" } ; return $d }
# (the child rewrites these small progress files all the time; on Windows a read can hit the instant the file is
# being replaced and see nothing - retry instead of treating that as "no progress")
proc readnum {f} {
    for {set try 0} {$try < 20} {incr try} {
        set d [string trim [readfile $f]]
        if {[string is integer -strict $d]} { return $d }
        if {![file exists $f]} { return -1 }
        after 5
    }
    return -1
}

proc killpid {pid} {
    if {$::tcl_platform(platform) eq "windows"} { catch {exec taskkill /F /PID $pid} } else { catch {exec kill -9 $pid} }
}
proc spawn {mode db prog} {
    global kit childScript
    foreach s {started committed ready} { file delete $prog.$s }
    return [exec $kit $childScript $mode $db $prog &]
}
proc waitFor {cond {ms 15000}} {
    set end [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $end} { if {[uplevel 1 $cond]} { return 1 } ; after 1 }
    return 0
}

# baseline database: view `items` {id gen chk label}, `gen` 0, plus a second view as bystander
proc makeBaseline {path} {
    global rows
    file delete $path
    set t [store::openFile $path -create]
    store::createView $t items {{id I {}} {gen I {}} {chk I {}} {label S {}}}
    store::createView $t bystander {{k S {}} {v I {}} {sub V {{x S {}}}}}
    for {set i 0} {$i < $rows} {incr i} { store::appendRow $t.items {id gen chk label} [list $i 0 $i [stamp 0 $i]] }
    for {set i 0} {$i < 50} {incr i} {
        set r [store::appendRow $t.bystander {k v} [list key$i $i]]
        store::appendRow $t.bystander!$r.sub {x} [list sub$i]
    }
    store::commit $t
    store::closeFile $t
}

# Every invariant of a consistent database; returns "" when fine, else a description.
# Gives back the generation found via the global `foundGen`.
proc verify {path {allowExtra 0}} {
    global rows foundGen
    if {[catch {set t [store::openFile $path]} err]} { return "cannot open: $err" }
    set problem ""
    if {[catch {
        if {[lsort [store::views $t]] ne {bystander items}} { error "views are [store::views $t]" }
        if {[store::size $t.items] != $rows} { error "items has [store::size $t.items] rows, expected $rows" }
        if {[store::size $t.bystander] != 50} { error "bystander damaged: [store::size $t.bystander] rows" }
        for {set i 0} {$i < 50} {incr i} {
            if {[store::rows $t.bystander!$i.sub {x} 0 5] ne [list [list sub$i]]} { error "bystander subview $i damaged" }
        }
        set lay [store::layout $t.items]
        set base {{id I {}} {gen I {}} {chk I {}} {label S {}}}
        set hasExtra [expr {[store::findCol $lay extra] ne ""}]
        if {!$allowExtra && $lay ne $base} { error "layout changed: $lay" }
        if {$allowExtra && $lay ne $base && $lay ne [concat $base {{extra I {}}}]} { error "layout is neither version: $lay" }
        set gens {}
        set data [store::rows $t.items {id gen chk label} 0 $rows]
        set i 0
        foreach r $data {
            lassign $r id gen chk label
            if {$id != $i} { error "row $i has id $id" }
            if {$chk != $gen * 100000 + $i} { error "row $i: chk $chk does not match gen $gen" }
            if {$label ne [stamp $gen $i]} { error "row $i label '$label' does not match gen $gen" }
            dict set gens $gen 1
            incr i
        }
        if {[dict size $gens] != 1} { error "TORN COMMIT: rows from generations [dict keys $gens]" }
        set foundGen [lindex [dict keys $gens] 0]
        if {$hasExtra} {
            # structural scenario: every `extra` value must match across all rows
            set ex [lsort -unique [lmap_col [store::rows $t.items {extra} 0 $rows]]]
            if {[llength $ex] != 1} { error "extra column torn: values $ex" }
        }
    } err]} { set problem $err }
    store::closeFile $t
    return $problem
}
proc lmap_col {rows} { set o {} ; foreach r $rows { lappend o [lindex $r 0] } ; return $o }

set base [tmp crash_baseline.mk]
set work [tmp crash_work.mk]
set prog [tmp crash_progress]
makeBaseline $base
check baseline_ok [expr {[verify $base] eq ""}] [verify $base]

# ---- 0. negative controls: the verifier must be able to FAIL ---------------------------------
# (otherwise every check below could pass vacuously)
file copy -force $base $work
set t [store::openFile $work]
for {set i 0} {$i < 700} {incr i} { mk::set $t.items!$i gen 5 chk [expr {5 * 100000 + $i}] label [stamp 5 $i] }
store::commit $t ; store::closeFile $t       ;# rows 0..699 at generation 5, the rest at 0: a "torn commit"
set v [verify $work]
check control_detects_torn_commit [string match "*TORN COMMIT*" $v] $v
file copy -force $base $work
set t [store::openFile $work] ; mk::set $t.items!7 chk 42 ; store::commit $t ; store::closeFile $t
set v [verify $work]
check control_detects_bad_checksum [string match "*chk*" $v] $v
file copy -force $base $work
set sz [file size $work] ; set h [open $work r+b] ; chan truncate $h [expr {$sz * 7 / 10}] ; close $h
set v [verify $work]
check control_detects_truncation [expr {$v ne ""}] "a 30% truncated file passed verification"

# ---- 1. uncommitted edits are never written: SIGKILL leaves the file byte-identical -------------
file copy -force $base $work
set before [readfile $work]
set pid [spawn editkill $work $prog]
check editkill_ready [waitFor {file exists $prog.ready}]
after 100
killpid $pid
after 300
check uncommitted_file_identical [expr {[readfile $work] eq $before}] "file changed although nothing was committed"
check uncommitted_still_valid [expr {[verify $work] eq ""}] [verify $work]

# ---- 2. rollback restores exactly (cells, adds, deletes, restructure) --------------------------
file copy -force $base $work
set t [store::openFile $work]
set snapshot [store::rows $t.items {id gen chk label} 0 $rows]
store::setCell $t.items 10 label "edited!"
store::appendRow $t.items {id} [list 99999]
store::deleteRows $t.items {0 1 2}
store::restructure $t.items [concat [store::layout $t.items] [list {scratch D {}}]]
check dirty_counted [expr {[store::dirty $t] > 0}]
store::rollback $t
check rollback_rows [expr {[store::size $t.items] == $rows}]
check rollback_data [expr {[store::rows $t.items {id gen chk label} 0 $rows] eq $snapshot}]
check rollback_layout [expr {[llength [store::layout $t.items]] == 4}]
check rollback_clean [expr {[store::dirty $t] == 0}]
store::closeFile $t
check rollback_file_unchanged [expr {[readfile $work] eq $before}]

# ---- 3. kill during commits: never torn, never corrupt ----------------------------------------
proc killTrials {mode allowExtra count} {
    global base work prog
    set inCommit 0 ; set atOld 0 ; set atNew 0 ; set bad 0 ; set gensSeen {} ; set durs {}
    for {set trial 0} {$trial < $count} {incr trial} {
        file copy -force $base $work
        set pid [spawn $mode $work $prog]
        # let it run a few generations, then strike at a random moment right after a commit begins
        set target [expr {2 + int(rand() * 4)}]
        if {![waitFor {expr {[readnum $prog.started] >= $target}}]} { killpid $pid ; incr bad ; puts "trial $trial: child never reached generation $target" ; continue }
        set s0 [readnum $prog.started]
        waitFor {expr {[readnum $prog.started] > $s0}} 5000
        # strike somewhere inside the commit that just began: spread the delay over its measured duration
        set dur [readnum $prog.dur]
        set window [expr {$dur > 0 ? max(2, int($dur / 1000.0 * 1.3)) : 10}]
        lappend durs $dur
        set delay [expr {int(rand() * $window)}]
        set t0 [clock microseconds]
        while {([clock microseconds] - $t0) < $delay * 1000} {}
        killpid $pid
        after 150
        set started [readnum $prog.started] ; set committed [readnum $prog.committed]
        # a child killed while rewriting a progress file leaves it empty: then all we know is that it was at most
        # one generation ahead of the last commit it reported
        if {$started < $committed} { set started [expr {$committed + 1}] }
        set problem [verify $work $allowExtra]
        if {$problem ne ""} {
            incr bad
            puts "TRIAL $trial ($mode) CORRUPT: $problem   (started $started committed $committed)"
            file copy -force $work [tmp crash_failed_$mode.$trial.mk]
            continue
        }
        global foundGen
        lappend gensSeen $foundGen
        # the survivor must be exactly the last committed generation, or the one in flight
        if {$mode eq "commitloop"} {
            if {$foundGen < $committed || $foundGen > $started} { incr bad ; puts "TRIAL $trial: generation $foundGen outside \[$committed,$started\]" ; continue }
            if {$foundGen == $started} { incr atNew } else { incr atOld }
            if {$started > $committed} { incr inCommit }
        }
        # and the file must still be fully usable: edit, commit, verify again
        set t [store::openFile $work]
        store::setCell $t.items 0 label [stamp $foundGen 0]
        store::commit $t ; store::closeFile $t
        if {[verify $work $allowExtra] ne ""} { incr bad ; puts "TRIAL $trial: not usable after recovery: [verify $work $allowExtra]" }
    }
    return [list $bad $inCommit $atOld $atNew]
}

lassign [killTrials commitloop 0 $trials] bad inCommit atOld atNew
check kill_during_commit_never_corrupt [expr {$bad == 0}] "$bad of $trials trials failed"
puts "  commit-kill trials: $trials; kill landed while a commit was in flight in $inCommit of them; file then held the old state $atOld x and the new state $atNew x"

lassign [killTrials structloop 1 [expr {max(5, $trials / 2)}]] bad2 inC2 atOld2 atNew2
check kill_during_structure_change_never_corrupt [expr {$bad2 == 0}] "$bad2 trials failed"

# ---- 5. advisory write lock: refuse a second writer, allow read-only, recover after a crash ------
file copy -force $base $work
file delete [store::lockPath $work]
set pid [spawn holdlock $work $prog]
check lock_child_ready [waitFor {file exists $prog.ready}]
check lock_file_created [file exists [store::lockPath $work]]
set refused [catch {store::openFile $work} msg opts]
check lock_second_writer_refused [expr {$refused && [lrange [dict get $opts -errorcode] 0 1] eq "STORE LOCKED"}] $msg
set t [store::openFile $work -readonly]
check lock_readonly_allowed_with_warning [expr {[store::lockedByOther $t] ne ""}]
store::closeFile $t
check lock_untouched_by_reader [file exists [store::lockPath $work]]
killpid $pid ; after 300                                    ;# the holder CRASHES: its lock file is left behind
check lock_left_behind_by_crash [file exists [store::lockPath $work]]
set t [store::openFile $work]                                ;# ...and is recognised as stale
check lock_stale_taken_over [expr {[store::lockedByOther $t] eq ""}]
check lock_now_ours [regexp "^[pid] [store::thisHost] \\S+\$" [string trim [readfile [store::lockPath $work]]]] 1
store::closeFile $t
check lock_released_on_close [expr {![file exists [store::lockPath $work]]}]
# a lock claiming a dead local process is ignored; one from another host is respected
set h [open [store::lockPath $work] w] ; puts -nonewline $h "999999 [store::thisHost]" ; close $h
check lock_dead_pid_ignored [expr {![catch {set t [store::openFile $work]}]}]
catch {store::closeFile $t}
set h [open [store::lockPath $work] w] ; puts -nonewline $h "4242 some-other-machine" ; close $h
check lock_foreign_host_respected [catch {store::openFile $work}]
file delete [store::lockPath $work]

# ---- 4. a second process reading while the first commits (PROBE: reports, does not fail) -------
# Metakit has no locking, so this documents what actually happens rather than asserting safety.
file copy -force $base $work
set pid [spawn commitloop $work $prog]
waitFor {expr {[readnum $prog.started] >= 2}}
set reads 0 ; set torn 0 ; set failedOpen 0
set endt [expr {[clock milliseconds] + 4000}]
while {[clock milliseconds] < $endt} {
    incr reads
    if {[catch {set t [store::openFile $work -readonly]} err]} { incr failedOpen ; continue }
    if {[catch {
        set gens {}
        foreach r [store::rows $t.items {gen chk label} 0 $rows] { dict set gens [lindex $r 0] 1 }
        if {[dict size $gens] != 1} { incr torn }
    }]} { incr torn }
    store::closeFile $t
}
killpid $pid
puts "  concurrent-reader probe: $reads reads while a writer committed continuously; $torn saw a mixed/unreadable state, $failedOpen failed to open"

puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
