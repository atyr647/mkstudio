# Power loss, best effort:   tclkit tests/test_power_loss.tcl
#
# Killing a process (test_crash_safety.tcl) is NOT a power cut: the operating system keeps everything the process
# had already written.  A power cut loses whatever had not reached the disk, in any order.  There is no way to pull
# the plug from a test, so this builds the files a power cut could leave and opens every one of them:
#
#   1. Run a real commit and keep the file before (A) and after (B).
#   2. Find the pages (4 KiB; also 512-byte sectors) that differ.  After a power cut each of them is either old (A)
#      or new (B) independently - unless the program forced them to disk in a given order (fsync), which Metakit
#      never does: strace of a commit shows ZERO fsync/fdatasync/msync calls, and the LAST write is the 8-byte
#      header at offset 0 that points at the new data (append the data, then flip the pointer).
#   3. Synthesise states from models and classify each in a separate process (Metakit may crash on garbage):
#        ORDERED   writes persist in the order they were made and the power fails at some point - what a normal OS
#                  gives after a kill, and what an fsync between data and header would give after a power cut
#        HEADER    the new header persisted, the new data did not (the dangerous reordering)
#        REORDER   any subset of the changed pages persisted
#        TORN      any subset of the changed 512-byte sectors persisted
#      Outcomes: OLD / NEW (the file holds exactly state A / B - correct), SILENT (opens, holds neither: silent
#      corruption), DETECTED (will not open: Metakit noticed), CRASH (Metakit itself died), HANG.
#
# What is asserted: the harness works (all-old is OLD, all-new is NEW, deliberately damaged data is not OLD/NEW), and
# ORDERED is always correct.  The other models are MEASUREMENTS; set MKS_POWER_STRICT=1 to also demand that they
# never silently corrupt (a database with a durable commit protocol would pass that).
#
# Limits, honestly: this does not model a failing disk, a filesystem that loses a whole file, or data older than the
# last commit; it assumes an 8-byte header write is atomic (it lies inside one 512-byte sector); and writes that
# overwrite the same page twice in one commit are represented by the page's final content.
#
#   MKS_POWER_STATES  scale of the random sampling (default 1; 3 = three times as many states)
#   MKS_POWER_STRICT  1 = REORDER / HEADER / TORN must have no SILENT, CRASH or HANG (raw Metakit, which fails this)
#   MKS_POWER_SCENARIOS  comma-separated scenario names to run (default: all; CI on slow runners uses three)
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set kit [info nameofexecutable]
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 150]> want <[string range $want 0 150]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
set scale [expr {[info exists ::env(MKS_POWER_STATES)] ? $::env(MKS_POWER_STATES) : 1}]
set strict [expr {[info exists ::env(MKS_POWER_STRICT)] && $::env(MKS_POWER_STRICT)}]
expr {srand(20240611)}
proc readbin {p} { set h [open $p rb] ; set d [read $h] ; close $h ; return $d }
proc writebin {p d} { set h [open $p wb] ; puts -nonewline $h $d ; close $h }

# ---- the baseline database and the commits that will be interrupted ------------------------------------------------
proc buildA {path} {
    foreach f [glob -nocomplain $path*] { file delete $f }
    set t [store::openFile $path -create]
    store::createView $t items {{id I {}} {gen I {}} {label S {}} {w D {}}}
    store::createView $t other {{k S {}} {v I {}} {sub V {{x S {}}}}}
    for {set i 0} {$i < 600} {incr i} { store::appendRow $t.items {id gen label w} [list $i 0 "label $i [string repeat p 150]" [expr {$i / 4.0}]] }
    for {set i 0} {$i < 20} {incr i} {
        set r [store::appendRow $t.other {k v} [list key$i $i]]
        store::appendRow $t.other!$r.sub {x} [list sub$i]
    }
    store::commit $t ; store::closeFile $t
}
set scenarios {
    edit_one_cell     {store::setCell $t.items 7 label "edited label"}
    edit_number       {store::setCell $t.items 9 gen 41}
    append_rows       {for {set i 0} {$i < 40} {incr i} { store::appendRow $t.items {id gen label w} [list [expr {900 + $i}] 1 "new $i" 1.5] }}
    delete_rows       {store::deleteRows $t.items {3 4 5 100 101 400}}
    rewrite_everything {for {set i 0} {$i < 600} {incr i} { store::setCell $t.items $i label "rewritten $i [string repeat q 150]" }}
    add_column        {store::restructure $t.items [concat [store::layout $t.items] [list {extra I {}}]]}
    two_views         {store::setCell $t.items 1 gen 5 ; store::setCell $t.other 2 k "changed key" ; store::appendRow $t.other!3.sub {x} [list added]}
}

# ---- candidate states -----------------------------------------------------------------------------------------------------
proc pageOf {data i P} { return [string range $data [expr {$i * $P}] [expr {$i * $P + $P - 1}]] }
# pages (size P) where the two files differ; beyond the shorter file the missing side counts as zeros
proc changedPages {a b P} {
    set n [expr {(max([string length $a], [string length $b]) + $P - 1) / $P}] ; set out {}
    for {set i 0} {$i < $n} {incr i} {
        set x [pageOf $a $i $P] ; set y [pageOf $b $i $P]
        set pad [expr {max([string length $x], [string length $y])}]
        if {[string length $x] < $pad} { append x [string repeat \0 [expr {$pad - [string length $x]}]] }
        if {[string length $y] < $pad} { append y [string repeat \0 [expr {$pad - [string length $y]}]] }
        if {$x ne $y} { lappend out $i }
    }
    return [list $n $out]
}
# file with the pages in `persist` taken from B and all others from A (zeros where A has no such page);
# size: "B" = the final size was persisted (holes read as zeros); "hw" = only what was written
proc synth {a b P persist sizeMode} {
    set n [expr {(max([string length $a], [string length $b]) + $P - 1) / $P}]
    set pset [dict create] ; foreach i $persist { dict set pset $i 1 }
    set out "" ; set high 0
    for {set i 0} {$i < $n} {incr i} {
        set src [expr {[dict exists $pset $i] ? $b : $a}]
        set pg [pageOf $src $i $P]
        if {[dict exists $pset $i]} { set high [expr {max($high, $i * $P + [string length $pg])}] }
        if {[string length $pg] < $P && $i < $n - 1} { append pg [string repeat \0 [expr {$P - [string length $pg]}]] }
        append out $pg
    }
    set size [expr {$sizeMode eq "B" ? [string length $b] : max([string length $a], $high)}]
    if {[string length $out] > $size} { set out [string range $out 0 [expr {$size - 1}]] }
    while {[string length $out] < $size} { append out \0 }
    return $out
}
proc sample {list k} {
    # k distinct elements, in a random order
    set out {} ; while {[llength $out] < $k && [llength $list]} {
        set i [expr {int(rand() * [llength $list])}] ; lappend out [lindex $list $i] ; set list [lreplace $list $i $i]
    }
    return $out
}
proc subset {list p} { set o {} ; foreach x $list { if {rand() < $p} { lappend o $x } } ; return $o }

proc candidates {a b scale} {
    # -> list of {model description bytes}
    set out {}
    lassign [changedPages $a $b 4096] n changed
    set body [lsearch -all -inline -not $changed 0]
    set order $body ; if {[lsearch $changed 0] >= 0} { lappend order 0 }       ;# the header is written LAST
    set total [llength $order]
    # sanity
    lappend out [list SANITY "nothing persisted" $a]
    lappend out [list SANITY "everything persisted" $b]
    # ORDERED: the first k writes persisted
    set ks {}
    foreach f {0.1 0.25 0.5 0.75 0.9} { lappend ks [expr {int($total * $f)}] }
    lappend ks [expr {$total - 1}] [expr {$total - 2}] 1
    foreach k [lsort -unique -integer $ks] {
        if {$k > 0 && $k < $total} { lappend out [list ORDERED "first $k of $total page writes" [synth $a $b 4096 [lrange $order 0 [expr {$k - 1}]] hw]] }
    }
    # HEADER: the header (the pointer to the new data) persisted, the data did not (or only part of it)
    if {[lsearch $changed 0] >= 0} {
        lappend out [list HEADER "header only, size not persisted" [synth $a $b 4096 {0} hw]]
        lappend out [list HEADER "header + file size, no data" [synth $a $b 4096 {0} B]]
        for {set k 0} {$k < 6 * $scale} {incr k} {
            lappend out [list HEADER "header + a random third of the data" [synth $a $b 4096 [concat 0 [subset $body 0.33]] [expr {$k % 2 ? "B" : "hw"}]]]
        }
        lappend out [list HEADER "header + all data except the last page" [synth $a $b 4096 [concat 0 [lrange $body 0 end-1]] B]]
        lappend out [list HEADER "header + all data except the first data page" [synth $a $b 4096 [concat 0 [lrange $body 1 end]] B]]
    }
    # REORDER: any subset of the changed pages
    foreach p {0.1 0.3 0.5 0.7 0.9} {
        for {set k 0} {$k < 5 * $scale} {incr k} {
            lappend out [list REORDER "random pages, p=$p" [synth $a $b 4096 [subset $changed $p] [expr {$k % 2 ? "B" : "hw"}]]]
        }
    }
    # TORN: any subset of the changed 512-byte sectors
    lassign [changedPages $a $b 512] n2 changed2
    foreach p {0.3 0.5 0.8} {
        for {set k 0} {$k < 6 * $scale} {incr k} {
            lappend out [list TORN "random 512-byte sectors, p=$p" [synth $a $b 512 [subset $changed2 $p] [expr {$k % 2 ? "B" : "hw"}]]]
        }
    }
    # CONTROL: data that really is damaged must not look like A or B (shows the check can fail).  The damage goes into
    # a value of the LIVE copy of the data (the last occurrence: a commit appends a new copy after the old one).
    set at -1
    foreach key {"rewritten 300 " "label 300 "} { set at [string last $key $b] ; if {$at >= 0} break }
    if {$at < 0} { set at [expr {int([string length $b] * 0.4)}] }
    set dmg [string replace $b $at [expr {$at + 3}] "\xde\xad\xbe\xef"]
    lappend out [list CONTROL "4 bytes of live data overwritten" $dmg]
    lappend out [list CONTROL "file cut in half" [string range $b 0 [expr {[string length $b] / 2}]]]
    return [list $out [llength $changed] $n]
}

# ---- classify in a child process (Metakit may crash on a damaged file) ------------------------------------------------
proc classify {dir fileA fileB files mode} {
    global kit here
    set results [dict create]
    set pending $files ; set base 0
    while {[llength $pending]} {
        set lst $dir/list.txt ; set res $dir/result.txt
        file delete $res
        set h [open $lst w] ; puts $h [join $pending \n] ; close $h
        set pid [exec $kit $here/power_child.tcl $res $fileA $fileB $lst $mode &]
        set last -1 ; set stall [clock milliseconds] ; set done 0
        while {!$done} {
            after 50
            set lines {}
            if {[file exists $res]} { set h [open $res r] ; set lines [split [string trim [read $h]] \n] ; close $h }
            if {[llength $lines] != $last} { set last [llength $lines] ; set stall [clock milliseconds] }
            if {[lindex $lines end] eq "DONE"} { set done 1 ; break }
            # (liveness checks are slow on Windows; a dead child there is found by the stall timeout, reported as HANG)
            set alive [expr {$::tcl_platform(platform) eq "windows" ? 1 : [store::pidAlive $pid]}]
            if {!$alive || [clock milliseconds] - $stall > 6000} {
                if {$alive} { catch {exec kill -9 $pid} ; set why HANG } else { set why CRASH }
                if {$::tcl_platform(platform) eq "windows" && $alive} { catch {exec taskkill /F /PID $pid} }
                # the candidate whose START has no verdict is the culprit
                set cur ""
                foreach l $lines { if {[string match "START *" $l]} { set cur [lindex $l 1] } elseif {[string is integer -strict [lindex $l 0]]} { set cur "" } }
                lappend lines "X$why"
                break
            }
        }
        set started 0 ; set culprit ""
        set verdicts [dict create]
        set cur ""
        foreach l $lines {
            if {[string match "START *" $l]} { set cur [lindex $l 1] ; continue }
            if {$l eq "DONE"} continue
            if {[string match XCRASH $l] || [string match XHANG $l]} { if {$cur ne ""} { dict set verdicts $cur [string range $l 1 end] } ; set culprit $cur ; continue }
            set idx [lindex $l 0]
            dict set verdicts $idx [lrange $l 1 end] ; set cur ""
        }
        dict for {idx v} $verdicts { dict set results [expr {$base + $idx}] $v }
        if {$culprit eq ""} break                                   ;# everything was judged
        set pending [lrange $pending $culprit end] ; set base [expr {$base + $culprit}]
    }
    return $results
}

# ---- run every scenario -----------------------------------------------------------------------------------------------------
set work [tmp power_loss] ; file delete -force $work ; file mkdir $work
set totals [dict create]
set modes {raw truncate record}
set only [expr {[info exists ::env(MKS_POWER_SCENARIOS)] ? [split $::env(MKS_POWER_SCENARIOS) ,] : {}}]
foreach {name script} $scenarios {
    if {[llength $only] && $name ni $only} continue
    set dir $work/$name ; file mkdir $dir
    buildA $dir/A.mk
    file copy -force $dir/A.mk $dir/B.mk
    set t [store::openFile $dir/B.mk]
    eval $script
    store::commit $t ; store::closeFile $t
    set a [readbin $dir/A.mk] ; set b [readbin $dir/B.mk]
    lassign [candidates $a $b $scale] cands nchanged npages
    set files {} ; set meta {}
    set i 0
    foreach c $cands { lassign $c model desc bytes ; incr i ; writebin $dir/c$i.mk $bytes ; lappend files $dir/c$i.mk ; lappend meta [list $model $desc] }
    foreach mode $modes { set res($mode) [classify $dir $dir/A.mk $dir/B.mk $files $mode] }
    set tally [dict create]
    for {set k 0} {$k < [llength $files]} {incr k} {
        lassign [lindex $meta $k] model desc
        foreach mode $modes {
            set v [expr {[dict exists $res($mode) [expr {$k + 1}]] ? [dict get $res($mode) [expr {$k + 1}]] : "UNKNOWN"}]
            set cls [lindex $v 0]
            dict incr totals "$mode $model $cls"
            dict incr tally "$mode $model $cls"
            if {$mode eq "raw"} {
                if {$model eq "SANITY" && $desc eq "nothing persisted"} { check "$name: nothing persisted is exactly the old state" $cls OLD }
                if {$model eq "SANITY" && $desc eq "everything persisted"} { check "$name: everything persisted is exactly the new state" $cls NEW }
                if {$model eq "CONTROL"} { ok "$name: damaged file is not mistaken for a good state ($desc -> $cls)" [expr {$cls ni {OLD NEW}}] }
                if {$strict && $model in {HEADER REORDER TORN ORDERED}} { ok "$name: raw $model ($desc) -> $cls" [expr {$cls in {OLD NEW DETECTED}}] $v }
            } elseif {$model ne "CONTROL"} {
                # MK Studio's own handling.  With the commit record every state must come out as exactly the old
                # state (or the new one if all of it was persisted); without it (`truncate`) an unfinished append
                # must still be put right.
                if {$mode eq "record" || $model in {ORDERED SANITY}} {
                    ok "$name: $mode / $model ($desc) -> $cls" [expr {$cls in {OLD NEW}}] $v
                }
            }
        }
    }
    puts [format "  %-19s %2d of %3d pages changed" $name $nchanged $npages]
    foreach mode $modes {
        set line [format "      %-9s" $mode]
        foreach m {ORDERED HEADER REORDER TORN} {
            set parts {}
            foreach c {OLD NEW SILENT DETECTED CRASH HANG UNKNOWN} { if {[dict exists $tally "$mode $m $c"]} { lappend parts "[dict get $tally "$mode $m $c"] $c" } }
            append line [format " %s: %s;" $m [join $parts ", "]]
        }
        puts $line
    }
}
# ---- ground truth (Linux with strace): kill a REAL commit at every Nth write to the database file --------------------------
# The synthetic models above are only as good as their idea of the write order.  Here the process is really killed (strace
# fault injection) after its Nth write to the database file, for N through the whole commit, and the file it leaves is
# judged as it is (raw) and the way MK Studio opens it (with the commit record the real commit left behind).
set haveStrace [expr {$::tcl_platform(os) eq "Linux" && ![catch {exec strace -V}]}]
if {$haveStrace} {
    set dir $work/real ; file mkdir $dir
    buildA $dir/A.mk
    # B: the same commit, not interrupted
    file copy -force $dir/A.mk $dir/B.mk
    set env_real [expr {[info exists ::env(REAL_MK)] ? $::env(REAL_MK) : 1}]
    exec $kit $here/power_commit_child.tcl $dir/B.mk
    set files {} ; set ns {} ; set sizes {}
    set N 1
    while {$N < 400} {
        set f $dir/k$N.mk
        file copy -force $dir/A.mk $f ; file delete $f.lock $f.commit
        set rc [catch {exec strace -f -qq -P $f -e trace=write -e inject=write:signal=SIGKILL:when=$N -o /dev/null $kit $here/power_commit_child.tcl $f 2>/dev/null}]
        if {!$rc} { file delete $f ; break }                   ;# survived: the commit has fewer writes than N
        lappend files $f ; lappend ns $N
        incr N [expr {$N < 8 ? 1 : ($N < 40 ? 3 : 7)}]
    }
    if {[llength $files]} {
        foreach mode {raw own} { set rr($mode) [classify $dir $dir/A.mk $dir/B.mk $files $mode] }
        set rawc [dict create] ; set ownc [dict create]
        for {set k 0} {$k < [llength $files]} {incr k} {
            set n [lindex $ns $k]
            foreach mode {raw own} {
                set v [expr {[dict exists $rr($mode) [expr {$k + 1}]] ? [dict get $rr($mode) [expr {$k + 1}]] : "UNKNOWN"}]
                set cls [lindex $v 0]
                if {$mode eq "raw"} { dict incr rawc $cls } else {
                    dict incr ownc $cls
                    ok "real kill after write $n: MK Studio opens it as the old or the new state ($cls)" [expr {$cls in {OLD NEW}}] $v
                }
            }
        }
        set parts {} ; dict for {c n} $rawc { lappend parts "$n $c" }
        puts "  real kills at [llength $files] points of a real commit, Metakit alone: [join $parts {, }]"
        set parts {} ; dict for {c n} $ownc { lappend parts "$n $c" }
        puts "  ... opened by MK Studio (with the record the commit left): [join $parts {, }]"
    } else { puts "  (strace injection did not interrupt anything - real-kill section skipped)" }
} else { puts "  (no strace here - real-kill section skipped)" }

puts ""
puts "  totals over all scenarios (raw = Metakit alone; truncate = + cut back an unfinished append; record = + the commit record):"
foreach mode $modes {
    foreach m {ORDERED HEADER REORDER TORN} {
        set parts {} ; set n 0
        foreach c {OLD NEW SILENT DETECTED CRASH HANG UNKNOWN} { if {[dict exists $totals "$mode $m $c"]} { lappend parts "[dict get $totals "$mode $m $c"] $c" ; incr n [dict get $totals "$mode $m $c"] } }
        puts [format "    %-9s %-8s %4d states: %s" $mode $m $n [join $parts ", "]]
    }
}
puts "  (OLD/NEW = correct; DETECTED = refused to open; SILENT = opened with wrong content, e.g. an EMPTY database; CRASH = Metakit died)"
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
