# Power safety beyond the commit record: the first commit of a new database, silent corruption (checksum), backups,
# the force-to-disk call.      tclkit tests/run.tcl tests/test_durability.tcl
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 150]> want <[string range $want 0 150]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
proc readbin {p} { set h [open $p rb] ; set d [read $h] ; close $h ; return $d }
proc writebin {p d} { set h [open $p wb] ; puts -nonewline $h $d ; close $h }
proc clean {f} { foreach x [glob -nocomplain $f $f.*] { file delete -force $x } }
proc rows {t} { store::size $t.items }
proc mkdb {f n} {
    clean $f
    set t [store::openFile $f -create]
    store::createView $t items {id:I label:S}
    for {set i 0} {$i < $n} {incr i} { store::appendRow $t.items {id label} [list $i "row number $i with some text to fill pages"] }
    store::commit $t
    return $t
}

# ---- force to disk -----------------------------------------------------------------------------------------------------
set f [tmp dur_sync.mk] ; clean $f ; writebin $f "x"
set r [store::syncDisk $f]
if {$::tcl_platform(platform) eq "windows"} {
    puts "  syncDisk on Windows (PowerShell FlushFileBuffers): $r"
    ok sync_windows_reported [expr {$r in {0 1}}]
    # CI sets MKS_EXPECT_FLUSH on a runner that has PowerShell: there the flush must really have happened
    if {[info exists ::env(MKS_EXPECT_FLUSH)]} { check sync_windows_flushed $r 1 }
    set t0 [clock milliseconds] ; store::syncDisk $f ; puts "  one flush takes [expr {[clock milliseconds] - $t0}] ms"
    # PowerShell started straight from a Windows GUI program does nothing at all (exit status 0, no effect) - the first version of
    # this flush was a no-op for that reason and every check above still passed.  So: prove that a script really RUNS.
    set pm [tmp dur_ps_ran.txt] ; file delete -force $pm
    lassign [store::psRun "Set-Content -LiteralPath '[string map {' ''} [file nativename $pm]]' -Value ran"] ran ok out
    check powershell_started $ran 1
    check powershell_finished_ok $ok 1
    ok powershell_really_executed_the_script [file exists $pm] "no marker file: PowerShell did not run"
    file delete -force $pm
    lassign [store::psRun "exit 3"] ran ok out ; check powershell_exit_status_comes_back $ok 0
    lassign [store::psRun "throw 'boom'"] ran ok out ; check powershell_script_error_is_a_failure $ok 0
    set st [store::procStartTime [pid]]
    ok windows_process_start_time_is_found [expr {$st ne "" && abs([clock seconds] - $st) < 36000}] "got <$st>"
    # the flush itself: a file held open by another handle is flushed, a file that does not exist is not an error
    set t0 [clock milliseconds] ; lassign [store::psRun "Start-Sleep -Milliseconds 1"] a b c
    puts "  PowerShell round trip: [expr {[clock milliseconds] - $t0}] ms"
    # a file that is open in another program (Metakit holds the database open) can still be flushed
    set hh [open $f r+b]
    check sync_windows_while_open [store::syncDisk $f] $r
    close $hh
} else {
    check sync_forced_to_disk $r 1
}
# a path with an accented letter, spaces, parentheses and a quote: the names reach PowerShell inside the command text, intact
# (they used to travel in an environment variable and the flush silently did nothing for such a database)
set weirdDir [tmp "dur sync caf\u00e9 (1) it's"] ; file delete -force $weirdDir ; file mkdir $weirdDir
set wf $weirdDir/da\u00efta.mk ; writebin $wf "x"
set rw [store::syncDisk $wf]
check sync_weird_path_same_as_plain $rw $r
if {$::tcl_platform(platform) eq "windows" && [info exists ::env(MKS_EXPECT_FLUSH)]} { check sync_windows_weird_path_flushed $rw 1 }
file delete -force $weirdDir
set store::durable 0 ; check sync_off [store::syncDisk $f] 0 ; set store::durable 1
# a missing file is not an error
ok sync_missing_ok [expr {[catch {store::syncDisk /nonexistent/zz.mk}] == 0}]

# ---- the first commit of a new database ---------------------------------------------------------------------------------
set f [tmp dur_first.mk]
set t [mkdb $f 50]
check first_commit_leaves_no_record [file exists $f.commit] 0
check first_commit_written [rows $t] 50
check first_commit_has_a_sum [file exists $f.sum] 1
check first_commit_no_backup_of_nothing [file exists $f.bak] 0
store::closeFile $t
# an interrupted first commit: the record says "empty", the file has (part of) the new content
file copy -force $f $f.full
set h [open $f.commit w] ; puts -nonewline $h "empty 0" ; close $h
set t [store::openFile $f]
check first_commit_undone_size [file size $f] 0
ok first_commit_undone_reported [expr {[string match "*first save*" [store::repairedNote $t]]}] [store::repairedNote $t]
check first_commit_undone_views [store::views $t] {}
check first_commit_record_gone [file exists $f.commit] 0
store::closeFile $t
# a record left after a first commit that was fully written is also treated as unconfirmed (documented): same outcome
# no record, empty file: nothing to do
set t [store::openFile $f] ; check empty_file_quiet [store::repairedNote $t] "" ; store::closeFile $t
# a garbage record (killed while writing the record itself) does not break opening
file copy -force $f.full $f ; set h [open $f.commit w] ; close $h
set t [store::openFile $f] ; check garbage_record_ignored [rows $t] 50 ; check garbage_record_removed [file exists $f.commit] 0 ; store::closeFile $t
# a record with a half-written header
file copy -force $f.full $f ; set h [open $f.commit w] ; puts -nonewline $h "4a4c1a00" ; close $h
set t [store::openFile $f] ; check short_record_ignored [rows $t] 50 ; store::closeFile $t

# ---- really killing the first commit (Linux with strace) ---------------------------------------------------------------
set kit [info nameofexecutable]
set haveStrace [expr {$::tcl_platform(os) eq "Linux" && ![catch {exec strace -V}]}]
if {$haveStrace} {
    set dir [tmp dur_first_real] ; file delete -force $dir ; file mkdir $dir
    set killed 0 ; set outcomes [dict create] ; set N 1
    while {$N < 300} {
        set g $dir/k$N.mk
        set rc [catch {exec strace -f -qq -P $g -e trace=write -e inject=write:signal=SIGKILL:when=$N -o /dev/null $kit $here/durability_first_child.tcl $g 2>/dev/null}]
        if {!$rc} break
        incr killed
        # the raw file, as the kill left it
        set rawsize [file size $g] ; set hadRecord [file exists $g.commit]
        set t [store::openFile $g]
        set n [expr {[llength [store::views $t]] ? [rows $t] : -1}]
        store::closeFile $t
        set cls [expr {$n == 300 ? "NEW" : ($n == -1 ? "EMPTY" : "PARTIAL($n)")}]
        dict incr outcomes $cls
        ok "kill after write $N of the first commit: empty or complete ($cls)" [expr {$cls in {NEW EMPTY}}]
        ok "kill after write $N: the unfinished record is gone after opening" [expr {![file exists $g.commit]}]
        incr N [expr {$N < 8 ? 1 : 5}]
    }
    set parts {} ; dict for {c n} $outcomes { lappend parts "$n $c" }
    puts "  first commit killed at $killed points: [join $parts {, }]"
    ok first_commit_kills_happened [expr {$killed > 3}] "killed $killed"
    file delete -force $dir
} else { puts "  (no strace here - real-kill section skipped)" }

# ---- checksum: silent corruption ---------------------------------------------------------------------------------------
set f [tmp dur_sum.mk]
set t [mkdb $f 400] ; store::closeFile $t
check sum_ok_after_commit [store::sumCheck $f] ok
set t [store::openFile $f] ; check open_reports_ok [store::integrityState $t] ok ; store::closeFile $t
# flip one byte in the middle of the data, keep size and modification time: that is what bit rot looks like
set mt [file mtime $f] ; set d [readbin $f] ; set pos [expr {[string length $d] / 2}]
set orig [string index $d $pos] ; set flipped [format %c [expr {([scan $orig %c] + 1) % 256}]]
writebin $f [string replace $d $pos $pos $flipped] ; file mtime $f $mt
check sum_detects_bit_flip [store::sumCheck $f] damaged
set crcBefore [store::crcFile $f]
set t [store::openFile $f]
check open_reports_damaged [store::integrityState $t] damaged
check open_does_not_touch_a_damaged_file [store::crcFile $f] $crcBefore
check damaged_sum_not_rebaselined [store::sumCheck $f] damaged
store::closeFile $t
check integrity_state_cleared_on_close [store::integrityState $t] ""
# a read-only open does not run the check or write anything
set before [glob -nocomplain $f*]
set ro [store::openFile $f -readonly] ; store::closeFile $ro
check readonly_open_writes_nothing [glob -nocomplain $f*] $before
# another program changed the file legitimately (size or time differ): not damage, a new baseline
set f2 [tmp dur_sum2.mk] ; set t [mkdb $f2 100] ; store::closeFile $t
file mtime $f2 [expr {[file mtime $f2] - 100}]
check sum_changed_when_time_differs [store::sumCheck $f2] changed
set t [store::openFile $f2] ; check changed_not_damage [store::integrityState $t] changed ; store::closeFile $t
check changed_gets_new_baseline [store::sumCheck $f2] ok
# a file with no sum (made by an older version or another program) gets one
file delete $f2.sum
check no_sum_is_none [store::sumCheck $f2] none
set t [store::openFile $f2] ; store::closeFile $t
check baseline_written_when_missing [store::sumCheck $f2] ok
# too big to cover
set store::sumLimit 0
check not_covered_is_none [store::sumCheck $f2] none
set store::sumLimit 512
# the crc32 is computed in chunks: same as in one go
check crc_matches_one_shot [store::crcFile $f2] [format %08x [zlib crc32 [readbin $f2]]]

# ---- backup ---------------------------------------------------------------------------------------------------------------
set f [tmp dur_bak.mk]
set t [mkdb $f 100] ; store::closeFile $t
check no_backup_before_any_edit [file exists $f.bak] 0
set v1 [store::crcFile $f]
set t [store::openFile $f]
store::setCell $t.items 3 label "edited once" ; store::commit $t
check backup_is_the_state_before_the_session [store::crcFile $f.bak] $v1
set v2 [store::crcFile $f]
store::setCell $t.items 4 label "edited twice" ; store::commit $t
check backup_taken_once_per_session [store::crcFile $f.bak] $v1
check backup_has_no_temp_left [file exists $f.bak.tmp] 0
store::closeFile $t
set t [store::openFile $f] ; store::setCell $t.items 5 label "third" ; store::commit $t ; store::closeFile $t
ok new_session_new_backup [expr {[store::crcFile $f.bak] ne $v1}]
# a damaged file never replaces the backup
set good [store::crcFile $f.bak]
set mt [file mtime $f] ; set d [readbin $f] ; set pos [expr {[string length $d] / 3}]
writebin $f [string replace $d $pos $pos [format %c [expr {([scan [string index $d $pos] %c] + 7) % 256}]]] ; file mtime $f $mt
set t [store::openFile $f]
check damaged_seen_before_editing [store::integrityState $t] damaged
store::setCell $t.items 6 label "after damage" ; store::commit $t
check damaged_file_does_not_overwrite_the_backup [store::crcFile $f.bak] $good
store::closeFile $t
# restoring
store::restoreBackup $f
check restore_is_the_backup [store::crcFile $f] $good
check restore_keeps_the_damaged_file [file exists $f.damaged] 1
check restore_sum_ok [store::sumCheck $f] ok
set t [store::openFile $f] ; check restore_opens [rows $t] 100 ; store::closeFile $t
check restore_without_backup [catch {store::restoreBackup [tmp dur_nothing.mk]}] 1
# switched off
set store::backups 0
set f3 [tmp dur_nobak.mk] ; set t [mkdb $f3 20] ; store::closeFile $t
set t [store::openFile $f3] ; store::setCell $t.items 1 label x ; store::commit $t ; store::closeFile $t
check backups_off [file exists $f3.bak] 0
set store::backups 1


# ---- found by the code review: the commit record can never undo a FINISHED commit ----------------------------------------
# (a virus scanner holds the record on Windows, or the unlink is lost in a power cut on Linux: the old record then says
# "undo the commit that follows" about a commit that is complete - and for a first commit "empty 0" empties the whole database)
proc withDeleteFailing {pattern body} {
    rename ::file ::tcl_file_real
    proc ::file {args} [format {
        if {[lindex $args 0] eq "delete" && [string match {%s} [lindex $args end]]} { return -code error "permission denied (simulated)" }
        uplevel 1 [list ::tcl_file_real {*}$args]
    } $pattern]
    set rc [catch {uplevel 1 $body} res opts]
    rename ::file {}
    rename ::tcl_file_real ::file
    return -options $opts $res
}
foreach {label first} {first_commit 1 later_commit 0} {
    set f [tmp dur_stale.mk] ; clean $f
    if {$first} {
        set t [store::openFile $f -create] ; store::createView $t items {id:I label:S}
    } else {
        set t [mkdb $f 3] ; store::closeFile $t ; set t [store::openFile $f]
    }
    store::appendRow $t.items {id label} [list 99 "kept"]
    set before [rows $t]
    withDeleteFailing *.commit { store::commit $t }
    ok "${label}_commit_returned_with_the_record_undeletable" 1
    check "${label}_record_is_still_there" [file exists $f.commit] 1
    set rec [readbin $f.commit]
    set info [store::headerInfo $f]
    check "${label}_record_describes_the_finished_file" $rec "[dict get $info header] [dict get $info size]"
    store::closeFile $t
    set t [store::openFile $f]
    check "${label}_reopen_keeps_the_data" [rows $t] $before
    check "${label}_nothing_was_undone" [store::repairedNote $t] ""
    store::closeFile $t
    check "${label}_record_gone_after_reopen" [file exists $f.commit] 0
}
# and when the record can neither be changed nor deleted the user is told, not left to lose the save later
set f [tmp dur_stale2.mk] ; set t [mkdb $f 3] ; store::closeFile $t ; set t [store::openFile $f]
store::appendRow $t.items {id label} [list 100 x]
# (a record nobody can write, rename or delete: every such call on a *.commit path fails, as under a scanner that locks the file)
store::beginCommit $f ; mk::file commit $t       ;# (the two halves of store::commit, with the trouble only in the second)
rename ::file ::tcl_file_real ; rename ::open ::tcl_open_real
proc ::file {args} {
    if {[lindex $args 0] in {delete rename} && [string match *.commit* [lindex $args end]]} { return -code error "permission denied (simulated)" }
    uplevel 1 [list ::tcl_file_real {*}$args]
}
proc ::open {path args} {
    if {[string match *.commit* $path] && [llength $args] && [string match w* [lindex $args 0]]} { return -code error "permission denied (simulated)" }
    uplevel 1 [list ::tcl_open_real $path {*}$args]
}
set rec_dir_trick [catch { store::endCommit $f } msg]
rename ::file {} ; rename ::open {} ; rename ::tcl_file_real ::file ; rename ::tcl_open_real ::open
check commit_says_when_the_record_is_stuck $rec_dir_trick 1
ok commit_stuck_message_explains [string match "*leftover file*" $msg] $msg
file delete -force $f.commit
catch {store::closeFile $t}

# ---- found by the code review: one database, one name (symbolic links), and an unreadable lock is a held lock ---------------
if {$::tcl_platform(platform) ne "windows"} {
    set dir [tmp dur_links] ; file delete -force $dir ; file mkdir $dir/real $dir/links
    set real $dir/real/sales.mk
    set t [mkdb $real 3] ; store::closeFile $t
    file link -symbolic $dir/links/current.mk ../real/sales.mk
    file link -symbolic $dir/links/twice.mk current.mk
    check canonical_resolves_the_last_link [store::canonical $dir/links/current.mk] [file normalize $real]
    check canonical_resolves_a_chain [store::canonical $dir/links/twice.mk] [file normalize $real]
    check canonical_leaves_plain_paths [store::canonical $real] [file normalize $real]
    set t [store::openFile $dir/links/current.mk]
    check opened_through_a_link_is_the_real_path [store::path $t] [file normalize $real]
    ok lock_file_is_the_real_ones [file exists $real.lock]
    ok no_lock_file_next_to_the_link [expr {![file exists $dir/links/current.mk.lock]}]
    check second_name_is_refused [catch {store::openFile $real}] 1
    check second_name_via_chain_is_refused [catch {store::openFile $dir/links/twice.mk}] 1
    file link -hard $dir/links/hard.mk $real
    check hard_link_to_an_open_database_is_refused [catch {store::openFile $dir/links/hard.mk}] 1
    store::closeFile $t
    file delete -force $dir
}
# an existing lock that cannot be read is held by somebody we cannot name - never "free" (a directory stands in for an
# unreadable file: it exists and cannot be read, whoever runs the test)
set f [tmp dur_unread.mk] ; clean $f ; set t [mkdb $f 2] ; store::closeFile $t
file mkdir $f.lock
check unreadable_lock_is_held [dict get [store::lockInfo $f] state] held
check unreadable_lock_refuses_a_writer [catch {store::openFile $f}] 1
file delete -force $f.lock
check lock_gone_means_free [dict get [store::lockInfo $f] state] free
# the escape hatch for a lock nobody holds any more
set h [open $f.lock w] ; puts -nonewline $h "424242 some-other-machine" ; close $h
check foreign_host_lock_is_held [dict get [store::lockInfo $f] state] held
check break_lock_returns_what_it_removed [store::breakLock $f] "424242 some-other-machine"
check break_lock_frees_it [dict get [store::lockInfo $f] state] free
set t [store::openFile $f] ; store::closeFile $t

# a database whose folder will not take new files can be written but has no lock, record or backup: the user is told
if {$::tcl_platform(platform) ne "windows" && $::tcl_platform(user) ne "root"} {
    set dir [tmp dur_rofolder] ; file delete -force $dir ; file mkdir $dir
    set t [mkdb $dir/x.mk 3] ; store::closeFile $t
    file attributes $dir -permissions 0555
    set t [store::openFile $dir/x.mk]
    ok unprotected_open_is_flagged [expr {[store::unprotectedNote $t] ne ""}]
    ok unprotected_note_says_why [string match "*does not allow new files*" [store::unprotectedNote $t]]
    store::closeFile $t
    file attributes $dir -permissions 0755
    set t [store::openFile $dir/x.mk]
    check protected_open_has_no_note [store::unprotectedNote $t] ""
    store::closeFile $t
    file delete -force $dir
}

# ---- found by the code review: a damaged file's good backup survives, and restoring never clobbers an earlier .damaged ------
set f [tmp dur_bak2.mk] ; set t [mkdb $f 30] ; store::closeFile $t
set t [store::openFile $f] ; store::setCell $t.items 1 label "session one" ; store::commit $t ; store::closeFile $t
set good [store::crcFile $f.bak]
set mt [file mtime $f] ; set d [readbin $f] ; set pos [expr {[string length $d] / 3}]
writebin $f [string replace $d $pos $pos [format %c [expr {([scan [string index $d $pos] %c] + 7) % 256}]]] ; file mtime $f $mt
set t [store::openFile $f]
check damaged_open_anyway_verdict [store::integrityState $t] damaged
store::setCell $t.items 2 label "edited on top of damage" ; store::commit $t ; store::closeFile $t
ok good_backup_has_a_protected_copy [file exists $f.bak.good]
check protected_copy_is_the_good_one [store::crcFile $f.bak.good] $good
# the NEXT session sees a file that checks out, and copies the damaged data over .bak ...
set t [store::openFile $f] ; store::setCell $t.items 3 label "next session" ; store::commit $t ; store::closeFile $t
ok later_session_replaced_the_plain_backup [expr {[store::crcFile $f.bak] ne $good}]
# ... but the good one is still there, and is the one restored
check backup_file_prefers_the_protected_copy [store::backupFile $f] $f.bak.good
store::restoreBackup $f
check restore_gives_the_good_state [store::crcFile $f] $good
ok restore_uses_up_the_protected_copy [expr {![file exists $f.bak.good]}]
ok restore_kept_the_damaged_file [file exists $f.damaged]
# a second restore must not overwrite the first .damaged
set d1 [readbin $f.damaged]
set t [store::openFile $f] ; store::setCell $t.items 4 label "again" ; store::commit $t ; store::closeFile $t
store::restoreBackup $f
check second_restore_keeps_the_first_damaged_file [readbin $f.damaged] $d1
ok second_restore_made_its_own_damaged_file [file exists $f.damaged.1]
clean [tmp dur_stale.mk] ; clean [tmp dur_stale2.mk] ; clean [tmp dur_unread.mk] ; clean [tmp dur_bak2.mk]

foreach x {dur_sync dur_first dur_sum dur_sum2 dur_bak dur_nobak} { clean [tmp $x.mk] }
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]        ;# (explicit: a Windows GUI tclkit would otherwise wait in its event loop)
