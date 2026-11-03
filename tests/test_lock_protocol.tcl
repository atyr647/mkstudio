# The write-lock protocol (see CONCURRENCY.md), checked against independent implementations of it:
#   tclkit tests/test_lock_protocol.tcl
# The point of a shared policy is that OTHER components (the SQL engine, a server) can follow it
# without sharing code, so these tests write and read the lock file by hand, the way another
# implementation would, and race real processes against each other.
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 150]> want <$want>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
set kit [info nameofexecutable]
set host [info hostname]

set db [tmp lockproto.mk]
proc fresh {} { global db ; foreach f [glob -nocomplain $db*] { file delete $f } ; set t [store::openFile $db -create] ; store::commit $t ; store::closeFile $t }
proc rawlock {text} { global db ; set h [open $db.lock w] ; puts -nonewline $h $text ; close $h }
proc rawread {} { global db ; set h [open $db.lock r] ; set d [read $h] ; close $h ; return $d }

# ---- 1. the file we write is what the spec says -------------------------------------------------
fresh
set t [store::openFile $db]
check lock_content_format [regexp {^(\d+) (\S+)$} [rawread] -> p h] 1
check lock_pid  $p [pid]
check lock_host $h $host
check lock_info_ours [dict get [store::lockInfo $db] state] ours
store::closeFile $t
ok lock_removed_on_close [expr {![file exists $db.lock]}]
check lock_info_free [dict get [store::lockInfo $db] state] free

# ---- 2. a lock written by another implementation is respected ------------------------------------
fresh
rawlock "999 some-other-machine"
set e [catch {store::openFile $db} msg opts]
check foreign_refused $e 1
check foreign_errorcode [lrange [dict get $opts -errorcode] 0 3] {STORE LOCKED 999 some-other-machine}
set t [store::openFile $db -readonly]
ok foreign_readonly_allowed [expr {[store::lockedByOther $t] ne ""}]
store::closeFile $t
check foreign_lock_untouched [rawread] "999 some-other-machine"
rawlock "999 some-other-machine server tcp://db.example:5433"
catch {store::openFile $db} msg opts
ok role_in_message [expr {[string first "server" $msg] >= 0 && [string first "tcp://db.example:5433" $msg] >= 0}] $msg
check role_in_errorcode [lrange [dict get $opts -errorcode] 4 5] {server tcp://db.example:5433}
file delete $db.lock

# ---- 3. stale locks (same host, dead process) are taken over -----------------------------------------
rawlock "999999 $host"
set t [store::openFile $db]
check stale_taken_over [regexp "^[pid] $host\$" [rawread]] 1
store::closeFile $t
rawlock "999999 $host server tcp://gone:1"
set t [store::openFile $db]
check stale_with_role_taken_over [regexp "^[pid] $host\$" [rawread]] 1
store::closeFile $t
# empty lock: its creator may be mid-write, so respect it - until it is clearly abandoned
rawlock ""
check empty_fresh_respected [catch {store::openFile $db}] 1
file mtime $db.lock [expr {[clock seconds] - 60}]
set t [store::openFile $db]
ok empty_old_taken_over [string match "[pid] *" [rawread]]
store::closeFile $t
# a takeover mutex abandoned by a crash does not block
rawlock "999999 $host"
set h [open $db.lock.guard w] ; close $h ; file mtime $db.lock.guard [expr {[clock seconds] - 60}]
set t [store::openFile $db]
ok abandoned_mutex_ignored [string match "[pid] *" [rawread]]
store::closeFile $t
ok mutex_cleaned_up [expr {![file exists $db.lock.guard]}]

# a process that got the pid of the dead writer is not the writer (Linux: it started after the lock was written)
if {[file exists /proc/self/stat]} {
    set other [exec sleep 60 &]
    after 100
    rawlock "$other $host"
    file mtime $db.lock [expr {[clock seconds] - 3600}]            ;# the lock is an hour old, the process just started
    check reused_pid_is_stale [dict get [store::lockInfo $db] state] stale
    rawlock "$other $host"                                         ;# a lock written just now by a process that is running
    file mtime $db.lock [expr {[clock seconds] + 5}]
    check same_process_is_held [dict get [store::lockInfo $db] state] held
    catch {exec kill $other}
    file delete $db.lock
}
# a live process of ANOTHER user is alive even though it cannot be signalled
if {$::tcl_platform(platform) ne "windows"} { check other_users_process_is_alive [store::pidAlive 1] 1 }       ;# (init: owned by root, not ours to signal)

# a competitor deletes the stale lock between our failed create and our look at the file: we must RETRY and
# take the lock (this once made a process carry on "unlocked", i.e. two owners)
fresh
rawlock "999999 $host"
set ::hookCalls 0
proc vanish {step} { if {$step eq "create-failed" && [incr ::hookCalls] == 1} { file delete $::db.lock } }
set ::store::lockHook vanish
set got [store::takeLock $db]
set ::store::lockHook ""
ok vanished_lock_is_retried_not_ignored [expr {$got ne ""}] "takeLock returned <$got>"
check vanished_lock_then_ours [expr {[file exists $db.lock] && [string match "[pid] *" [rawread]]}] 1
file delete $db.lock
# a read-only folder is the one case where carrying on without a lock is right
if {$::tcl_platform(platform) ne "windows" && [exec id -u] != 0} {
    set ro [tmp lock_ro_dir] ; file delete -force $ro ; file mkdir $ro ; file attributes $ro -permissions 0555
    check readonly_folder_runs_unlocked [store::takeLock $ro/x.mk] ""
    file attributes $ro -permissions 0755 ; file delete -force $ro
}

# ---- 4. we only ever remove OUR lock ---------------------------------------------------------------------
fresh
set t [store::openFile $db]
rawlock "999 some-other-machine"                ;# someone replaced it while we held the file
store::closeFile $t
check close_leaves_foreign_lock [rawread] "999 some-other-machine"
file delete $db.lock

# ---- 5. a long-lived owner announces itself ----------------------------------------------------------------
fresh
set ::store::lockRole server ; set ::store::lockEndpoint tcp://localhost:5433
set t [store::openFile $db]
check role_written [rawread] "[pid] $host server tcp://localhost:5433"
set ::store::lockRole "" ; set ::store::lockEndpoint ""
set go [tmp lock_go] ; file delete $go
set res [tmp lock_res_0] ; file delete $res
exec $kit $here/lock_child.tcl $db $res $go 100 &
close [open $go w]
for {set i 0} {$i < 300 && ![file exists $res]} {incr i} { after 20 }
after 100
set line [expr {[file exists $res] ? [string trim [read [set h [open $res r]]]] : "(no answer)"}]
catch {close $h}
ok other_process_sees_role [expr {[string match "LOCKED*server*tcp://localhost:5433*" $line]}] $line
store::closeFile $t

# ---- 6. races: exactly one of several processes wins ----------------------------------------------------------
proc race {round setup {mix 0}} {
    global db kit here
    fresh
    {*}$setup
    set go [tmp lock_go_$round] ; file delete $go
    set results {}
    for {set k 0} {$k < 6} {incr k} {
        set r [tmp lock_res_${round}_$k] ; file delete $r
        lappend results $r
        if {$mix && $k % 2} {
            exec $kit $here/lock_child_mkitsql.tcl $db $r $go 1500 &    ;# every other process is mkit-sql's implementation
        } else {
            exec $kit $here/lock_child.tcl $db $r $go 1500 &
        }
    }
    after 500                                   ;# let every child reach its wait loop
    close [open $go w]
    set outcome {}
    foreach r $results {
        for {set i 0} {$i < 600 && ![file exists $r]} {incr i} { after 25 }
        after 20
        if {[file exists $r]} { set h [open $r r] ; lappend outcome [lindex [string trim [read $h]] 0] ; close $h } else { lappend outcome NONE }
    }
    after 2000                                  ;# the winner closes and releases
    return $outcome
}
proc count {l what} { set n 0 ; foreach x $l { if {$x eq $what} { incr n } } ; return $n }
set rounds [expr {[info exists ::env(MKS_RACE_ROUNDS)] ? $::env(MKS_RACE_ROUNDS) : 4}]
for {set round 1} {$round <= $rounds} {incr round} {
    set o [race $round {}]
    check "race_$round (no lock yet): winners" [count $o WIN] 1
    check "race_$round: everyone else refused" [count $o LOCKED] 5
    ok "race_$round: lock released after the winner closed" [expr {![file exists $db.lock]}]
}
for {set round 101} {$round <= 100 + $rounds} {incr round} {
    set o [race $round [list rawlock "999999 $host"]]
    check "stale_race_$round: winners" [count $o WIN] 1
    check "stale_race_$round: everyone else refused" [count $o LOCKED] 5
}
# ---- 7. interoperability with mkit-sql's own implementation of the protocol (a separate code base) ----------------
if {[info exists ::env(MKITSQL_DIR)] && [file exists $::env(MKITSQL_DIR)/mkitsql/mkitsql.tcl]} {
    puts "  (interoperability with mkit-sql at $::env(MKITSQL_DIR))"
    for {set round 201} {$round <= 200 + $rounds} {incr round} {
        set o [race $round {} 1]
        check "mixed_race_$round (free lock): winners" [count $o WIN] 1
        check "mixed_race_$round: everyone else refused" [count $o LOCKED] 5
    }
    for {set round 301} {$round <= 300 + $rounds} {incr round} {
        set o [race $round [list rawlock "999999 $host"] 1]
        check "mixed_stale_race_$round: winners" [count $o WIN] 1
        check "mixed_stale_race_$round: everyone else refused" [count $o LOCKED] 5
    }
    # a lock WE wrote (with start token, role and endpoint) is respected by them: not mistaken for stale
    fresh
    set ::store::lockRole server ; set ::store::lockEndpoint tcp://localhost:5433
    set t [store::openFile $db]
    set ::store::lockRole "" ; set ::store::lockEndpoint ""
    set go [tmp lock_go_x] ; file delete $go ; set res [tmp lock_res_x] ; file delete $res
    exec $kit $here/lock_child_mkitsql.tcl $db $res $go 100 &
    close [open $go w]
    for {set i 0} {$i < 300 && ![file exists $res]} {incr i} { after 20 }
    after 100
    set h [open $res r] ; set line [string trim [read $h]] ; close $h
    ok mkitsql_respects_our_lock [string match "LOCKED*" $line] $line
    store::closeFile $t
    # a lock THEY hold is respected by us (and their format is read correctly)
    fresh
    set go [tmp lock_go_y] ; file delete $go ; set res [tmp lock_res_y] ; file delete $res
    exec $kit $here/lock_child_mkitsql.tcl $db $res $go 3000 &
    close [open $go w]
    for {set i 0} {$i < 300 && ![file exists $res]} {incr i} { after 20 }
    after 200
    ok mkitsql_lock_names_its_owner [regexp {^\d+ \S+} [string trim [rawread]]]
    set e [catch {store::openFile $db} msg opts]
    check we_respect_mkitsql_lock $e 1
    check mkitsql_holder_pid_reported [string is integer -strict [lindex [dict get $opts -errorcode] 2]] 1
    after 3300
    # each implementation honours the other's takeover mutex
    foreach impl {studio mkitsql} {
        fresh
        rawlock "999999 $host"
        set h [open $db.lock.guard w] ; close $h                      ;# someone else is mid-takeover
        set go [tmp lock_go_z] ; file delete $go ; set res [tmp lock_res_z] ; file delete $res
        exec $kit $here/[expr {$impl eq "studio" ? "lock_child.tcl" : "lock_child_mkitsql.tcl"}] $db $res $go 100 &
        close [open $go w]
        for {set i 0} {$i < 750 && ![file exists $res]} {incr i} { after 20 }      ;# (they wait a few seconds for the guard)
        after 100
        set h [open $res r] ; set line [string trim [read $h]] ; close $h
        ok "${impl}_waits_for_the_others_takeover_mutex" [expr {![string match WIN* $line]}] $line
        file delete $db.lock.guard
    }
} else { puts "  (set MKITSQL_DIR to a mkit-sql checkout to test interoperability)" }

puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
