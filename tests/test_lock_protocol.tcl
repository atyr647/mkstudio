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
# a takeover guard abandoned by a crash does not block
rawlock "999999 $host"
set h [open $db.lock.guard w] ; close $h ; file mtime $db.lock.guard [expr {[clock seconds] - 60}]
set t [store::openFile $db]
ok abandoned_guard_ignored [string match "[pid] *" [rawread]]
store::closeFile $t
ok guard_cleaned_up [expr {![file exists $db.lock.guard]}]

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
proc race {round setup} {
    global db kit here
    fresh
    {*}$setup
    set go [tmp lock_go_$round] ; file delete $go
    set results {}
    for {set k 0} {$k < 6} {incr k} {
        set r [tmp lock_res_${round}_$k] ; file delete $r
        lappend results $r
        exec $kit $here/lock_child.tcl $db $r $go 1500 &
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
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
