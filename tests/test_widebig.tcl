# A database file past 2 GiB, through MK Studio's store, on the Metakit with 64-bit file positions (https://github.com/atyr647/metakit).
# Needs about 5 GB of free disk, 2 GB of memory and a few minutes; skipped (exit 0) with a Mk4tcl that cannot hold such a file.
#   TCLLIBPATH=<dir with Mk4tcl/pkgIndex.tcl> tclsh tests/test_widebig.tcl
# What it shows: commits cross 2 GiB (the first wide commit rewrites the header; every later one appends its tails), the file stays readable and
# writable, every value is still the one written, ONE blob column holds more than 2 GiB (Metakit moves each big value out of the shared column
# when it is committed), about 2 GiB of values written without a commit in one column are refused cleanly (by the column guard first; with the guard
# off Metakit's own error is turned into the same refusal and the storage can then only be rolled back), a
# process killed in the middle of a commit leaves a file that opens as one commit or the other (the commit record puts it right), and a program
# whose Mk4tcl cannot read wide files refuses it.
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set pass 0 ; set fail 0
# run a child script that writes its answer to a file (a Windows GUI program has no stdout to read); the last line of the answer, or ""
proc childOut {script args} {
    global here
    set out [tmp mks_childout_[pid]_[incr ::childN].txt] ; file delete $out
    catch {exec [info nameofexecutable] $script {*}$args $out 2>@1}
    set d "" ; catch {set h [open $out r] ; set d [string trim [read $h]] ; close $h} ; file delete $out
    return [lindex [split $d "\n"] end]
}
set childN 0
proc ok {name cond {info ""}} { global pass fail ; if {$cond} { incr pass } else { incr fail ; puts "FAIL $name $info" } }
if {![store::wideCapable]} { puts "widebig: this Mk4tcl cannot hold files over 2 GiB; skipped" ; exit 0 }
set f [tmp mks_widebig_[pid].mk] ; file delete $f
set GiB 1073741824
set db [store::openFile $f -create]
store::createView $db t {k:I b1:B b2:B b3:B}
set pad [string repeat x 1048568]
set store::durable 0                       ;# the fill phase need not force gigabytes to disk 30 times
set n 0
while {$n < 1500} {
    for {set j 0} {$j < 50} {incr j} { store::appendRow $db.t {k b1 b2} [list $n [format %08d $n]$pad [format %08d $n]$pad] ; incr n }
    store::commit $db
}
set store::durable 1
set size [file size $f]
puts "file: $size bytes ([format %.2f [expr {$size / double($GiB)}]] GiB)"
ok "the file is over 2 GiB" [expr {$size > 2 * $GiB}]
ok "it uses the wide format" [store::isWide $f]
ok "its frame is valid" [store::footerOkAt $f $size 1]
ok "all rows are there" [expr {[store::size $db.t] == 1500}]
ok "no checksum or backup of a file that size (the limit is $store::sumLimit MB)" [expr {![file exists $f.sum] && ![file exists $f.bak]}]
ok "no commit record left behind" [expr {![file exists $f.commit]}]
set bad 0
for {set i 0} {$i < 1500} {incr i} {
    foreach c {b1 b2} {
        set v [mk::get $db.t!$i $c]
        if {[string range $v 0 7] ne [format %08d $i] || [string length $v] != 1048576} { incr bad }
    }
}
ok "every blob is intact" [expr {$bad == 0}] $bad
store::setCell $db.t 1499 k 101499
store::commit $db
ok "an edit past 2 GiB commits" [expr {[lindex [store::rows $db.t {k} 1499 1] 0] == 101499}]
store::closeFile $db
set out [childOut $here/widebig_count_child.tcl $f]
ok "a new process opens it and counts" [string match "1500 rows 101499" $out] $out
set out [childOut $here/wide_child.tcl $f]
ok "MKS_WIDE=0 refuses the file" [string match "refused STORE WIDEFILE" $out] $out

# ---- ONE blob column holds more than 2 GiB: at every commit Metakit moves each big value into a column of its own, so only what was written
# ---- since the last commit has to fit into the shared column.  b1 has 1500 MiB; 600 more, committed every 50 rows, take it past 2^31 bytes.
set db [store::openFile $f]
set store::durable 0
set refused 0 ; set code ""
for {set i 0} {$i < 600} {incr i} {
    if {[catch {store::appendRow $db.t {k b1} [list [expr {200000 + $i}] [format %08d [expr {200000 + $i}]]$pad]} m opts]} { incr refused ; set code [dict get $opts -errorcode] ; break }
    if {($i + 1) % 50 == 0} { store::commit $db }
}
store::commit $db
ok "one blob column takes more than 2 GiB when it is committed now and then (refused after $i MiB: $code)" [expr {!$refused}] $code
set rows [store::size $db.t]
ok "its rows are all there ($rows)" [expr {$rows == 2100 + 0}] $rows
set b1bytes [expr {($rows - 0) * 1048576}]
ok "b1 holds more than 2^31 bytes ($b1bytes)" [expr {$b1bytes > 2147483647}]
set bad 0
foreach i {0 700 1499 1500 1501 1799 2099} {
    set v [mk::get $db.t!$i b1] ; set want [expr {$i < 1500 ? $i : 200000 + $i - 1500}]
    if {[string range $v 0 7] ne [format %08d $want] || [string length $v] != 1048576} { incr bad ; puts "row $i: [string range $v 0 7] [string length $v]" }
}
ok "rows on both sides of the 2 GiB mark are intact" [expr {$bad == 0}] $bad

# ---- what has NOT been committed all lives in the shared column, so about 2 GiB of uncommitted values in one column are refused (by the guard,
# ---- before anything is changed); the other columns are not affected
set pending 0 ; set code ""
for {set i 0} {$i < 2100} {incr i} {
    if {[catch {store::appendRow $db.t {k b3} [list [expr {400000 + $i}] [format %08d [expr {400000 + $i}]]$pad]} m opts]} { set code [dict get $opts -errorcode] ; break }
    incr pending
}
ok "the column guard refuses about 2 GiB of uncommitted values in one column (COLUMNFULL after $pending MiB)" [expr {[lrange $code 0 1] eq {STORE COLUMNFULL}}] $code
ok "...near 2 GiB ($pending MiB)" [expr {$pending > 2030 && $pending < 2048}] $pending
ok "...with a message that says to save" [string match "*SAVE (commit)*" $m] [string range $m 0 200]
ok "the other column is fine" [expr {![catch {store::appendRow $db.t {k b2} [list 1 small]}]}]
# the real error: with the guard switched off Metakit itself refuses the edit that would pass the limit (since 2e2e482 with an error, not by
# ending the program); the storage can then only be rolled back
set saveSlack $::store::guardSlack ; set ::store::guardSlack -2000000000
set mkcode "" ; set mkmsg "" ; set more 0
for {set i 0} {$i < 12} {incr i} {
    if {[catch {store::appendRow $db.t {k b3} [list [expr {500000 + $i}] [format %08d [expr {500000 + $i}]]$pad]} mkmsg opts]} { set mkcode [dict get $opts -errorcode] ; break }
    incr more
}
set ::store::guardSlack $saveSlack
ok "Metakit's own refusal (after $more more MiB) is a COLUMNFULL error" [expr {[lrange $mkcode 0 1] eq {STORE COLUMNFULL}}] "$mkcode / [string range $mkmsg 0 80]"
ok "...and the program is still alive to say so" 1
set rc [catch {store::commit $db} m opts]
ok "a commit is refused until the changes are rolled back" [expr {$rc && [dict get $opts -errorcode] eq {STORE TAINTED}}] "$rc $m"
ok "the file was not touched by that commit" [expr {![file exists $f.commit]}]
store::rollback $db
ok "after Roll Back the table is as it was committed" [expr {[store::size $db.t] == $rows}] "[store::size $db.t] vs $rows"
ok "...and a commit with new rows works again" [expr {![catch {store::appendRow $db.t {k b2} [list 2 again]}] && ![catch {store::commit $db} m]}] $m
set rows [store::size $db.t]
store::closeFile $db
set db [store::openFile $f -readonly]
ok "after all that the file reopens with every row" [expr {[store::size $db.t] == $rows}] "[store::size $db.t] vs $rows"
store::closeFile $db

# ---- a process killed in the middle of a commit (Unix only) ----
if {$::tcl_platform(platform) eq "unix"} {
    set base 500000 ; set undone 0 ; set kept 0
    for {set round 0} {$round < 6} {incr round} {
        set db [store::openFile $f -readonly] ; set before [store::size $db.t] ; store::closeFile $db
        set ch [open [list | [info nameofexecutable] $here/widebig_child.tcl $f 120 $base 2>@1] r]
        set reached 0 ; set said ""
        while {[gets $ch line] >= 0} { if {$line eq "COMMITTING"} { set reached 1 ; break } ; append said $line " " }
        ok "kill round $round: the child got as far as its commit" $reached $said
        set delay [expr {int(rand() * 2500)}] ; after $delay
        catch {exec kill -9 [pid $ch]} ; catch {close $ch}
        incr base 1000
        set d [store::openFile $f]                       ;# for writing: puts right an interrupted commit
        set after [store::size $d.t]
        if {$after == $before} { incr undone } else { incr kept }
        set note [store::repairedNote $d]
        puts "kill round $round: killed [format %4d $delay] ms after the commit began: $before -> $after rows[expr {$note ne "" ? ", $note" : ""}]"
        ok "kill round $round: the file holds one commit or the other ($before -> $after)" [expr {$after == $before || $after == $before + 120}]
        ok "kill round $round: the frame is valid" [store::footerOkAt $f [file size $f] 1] "size [file size $f]"
        store::appendRow $d.t {k b2} [list $round after]
        store::commit $d
        ok "kill round $round: later commits work" [expr {[store::size $d.t] == $after + 1}]
        store::closeFile $d
    }
    puts "killed commits: $undone left the file at the previous commit, $kept had finished"
}
file delete $f $f.commit $f.sum $f.lock $f.bak

# ---- a process killed in the commit that CROSSES 2 GiB (Unix only): that commit rewrites the header (the wide flag) and appends the wide tails; ----
# ---- the record must put the standard file back, whenever the kill falls                                                                       ----
if {$::tcl_platform(platform) eq "unix"} {
    set base [tmp mks_widebase_[pid].mk] ; set w [tmp mks_widecross_[pid].mk] ; file delete $base
    set db [store::openFile $base -create]
    store::createView $db t {k:I b1:B b2:B b3:B}
    set store::durable 0
    set n 0
    while {[file size $base] < 1.89 * $GiB} {
        for {set j 0} {$j < 50} {incr j} { store::appendRow $db.t [list k [lindex {b1 b2 b3} [expr {$n % 3}]]] [list $n "[format %08d $n]$pad"] ; incr n }   
        store::commit $db
    }
    store::closeFile $db
    set bsize [file size $base]
    puts "crossing test: a standard file of [format %.2f [expr {$bsize / double($GiB)}]] GiB, $n rows; 120 more MiB take it past 2 GiB"
    ok "the base is a standard file below 2 GiB" [expr {![store::isWide $base] && $bsize < 2 * $GiB}]
    set undone 0 ; set kept 0
    for {set round 0} {$round < 5} {incr round} {
        file delete $w $w.commit $w.sum $w.lock $w.bak
        file copy $base $w
        set ch [open [list | [info nameofexecutable] $here/widebig_child.tcl $w 120 900000 2>@1] r]
        set reached 0 ; set said ""
        while {[gets $ch line] >= 0} { if {$line eq "COMMITTING"} { set reached 1 ; break } ; append said $line " " }
        ok "crossing round $round: the child got as far as its commit" $reached $said
        set delay [expr {int(rand() * 3500)}] ; after $delay
        catch {exec kill -9 [pid $ch]} ; catch {close $ch}
        set d [store::openFile $w]
        set after [store::size $d.t] ; set note [store::repairedNote $d]
        set wide [store::isWide $w]
        if {$after == $n} { incr undone } else { incr kept }
        puts "crossing round $round: killed [format %4d $delay] ms after the commit began: $n -> $after rows, [expr {$wide ? {wide} : {standard}}] file, [file size $w] bytes[expr {$note ne "" ? ", $note" : ""}]"
        ok "crossing round $round: the file holds one commit or the other ($n -> $after)" [expr {$after == $n || $after == $n + 120}]
        ok "crossing round $round: the frame is valid" [store::footerOkAt $w [file size $w] $wide] "size [file size $w] wide $wide"
        ok "crossing round $round: a file that was put back is standard again" [expr {$after != $n || (!$wide && [file size $w] == $bsize)}] "wide $wide size [file size $w] base $bsize"
        store::appendRow $d.t {k b2} [list $round after]
        store::commit $d
        ok "crossing round $round: later commits work" [expr {[store::size $d.t] == $after + 1}]
        store::closeFile $d
    }
    puts "killed crossing commits: $undone put back to the standard file, $kept had finished"
    file delete $base $base.commit $base.sum $base.lock $base.bak $w $w.commit $w.sum $w.lock $w.bak
}
puts "widebig: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
