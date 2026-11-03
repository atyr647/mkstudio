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
    # a file that is open in another program (Metakit holds the database open) can still be flushed
    set hh [open $f r+b]
    check sync_windows_while_open [store::syncDisk $f] $r
    close $hh
} else {
    check sync_forced_to_disk $r 1
}
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

foreach x {dur_sync dur_first dur_sum dur_sum2 dur_bak dur_nobak} { clean [tmp $x.mk] }
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]        ;# (explicit: a Windows GUI tclkit would otherwise wait in its event loop)
