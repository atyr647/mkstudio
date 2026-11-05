# Files over 2 GiB and the Metakit that can hold them (https://github.com/atyr647/metakit, the 64-bit file positions):   tclkit tests/test_wide.tcl
# Works with ANY Mk4tcl and with small files: a "wide" file is made from an ordinary one the way that Metakit writes it past 2 GiB (three 24-byte
# tails, header flag 0x40; ::store::wideConvert), so
#   * with a stock Mk4tcl the store must refuse such a file (it would look empty) and touch nothing,
#   * with the 64-bit Mk4tcl it must read, change, repair after an interrupted commit, and keep the column limit.
# EXPECT_WIDE=1|0 makes the test insist on which Mk4tcl it found (CI does).  tests/test_widebig.tcl does it for real, past 2 GiB.
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
set ::store::durable 0
set pass 0 ; set fail 0
proc ok {name cond {info ""}} { global pass fail ; if {$cond} { incr pass } else { incr fail ; puts "FAIL $name $info" } }
proc check {n got want} { ok $n [expr {$got eq $want}] "got <[string range $got 0 150]> want <$want>" }
# run a child script that writes its answer to a file (a Windows GUI program has no stdout to read); the last line of the answer, or ""
proc childOut {script args} {
    global here
    set out [tmp mks_childout_[pid]_[incr ::childN].txt] ; file delete $out
    catch {exec [info nameofexecutable] $script {*}$args $out 2>@1}
    set d "" ; catch {set h [open $out r] ; set d [string trim [read $h]] ; close $h} ; file delete $out
    return [lindex [split $d "\n"] end]
}
set childN 0
proc step {what} { puts "  .. $what" ; flush stdout }
proc slurp {f} { set h [open $f rb] ; set d [read $h] ; close $h ; return $d }
proc spit {f d} { set h [open $f wb] ; puts -nonewline $h $d ; close $h }
set dir [tmp mks_wide_[pid]] ; file delete -force $dir ; file mkdir $dir
set std $dir/std.mk ; set wide $dir/wide.mk

set t [store::openFile $std -create]
store::createView $t t {id:I name:S}
foreach i {1 2 3} { store::appendRow $t.t {id name} [list $i [lindex {one two three} [expr {$i - 1}]]] }
store::commit $t ; store::closeFile $t
set data [slurp $std]
ok "standard file is not wide" [expr {![store::isWide $std]}]
check "standard headerInfo says wide 0" [dict get [store::headerInfo $std] wide] 0
ok "standard frame is recognised" [store::footerOkAt $std [file size $std]]
spit $wide [store::wideConvert $data]
ok "converted file is wide" [store::isWide $wide]
ok "wide frame is recognised" [store::footerOkAt $wide [file size $wide] 1]
ok "wide frame is not a standard frame" [expr {![store::footerOkAt $wide [file size $wide] 0]}]
ok "headerInfo of a wide file" [expr {[dict get [store::headerInfo $wide] wide] && [dict get [store::headerInfo $wide] offset] == [file size $wide]}]
ok "wideHex" [store::wideHex [dict get [store::headerInfo $wide] header]]
ok "a standard header is not wideHex" [expr {![store::wideHex [dict get [store::headerInfo $std] header]]}]
# a damaged wide frame is not taken for a good one (cut, wrong tail types)
foreach cut {1 9 24} {
    spit $dir/c.mk [string range [slurp $wide] 0 end-$cut]
    ok "wide file cut by $cut bytes is not an intact frame" [expr {![store::footerOkAt $dir/c.mk [file size $dir/c.mk] 1]}]
}
set w [slurp $wide] ; set n [string length $w]
spit $dir/c.mk [string range $w 0 [expr {$n-25}]]\x01[string range $w [expr {$n-23}] end]
ok "wrong skip tail type" [expr {![store::footerOkAt $dir/c.mk $n 1]}]
spit $dir/c.mk [string range $w 0 [expr {$n-9}]]\x00[string range $w [expr {$n-7}] end]
ok "wrong commit tail type" [expr {![store::footerOkAt $dir/c.mk $n 1]}]
file delete $dir/c.mk

set cap [store::wideCapable]
if {[info exists ::env(EXPECT_WIDE)]} { ok "the Mk4tcl is of the expected kind (EXPECT_WIDE=$::env(EXPECT_WIDE))" [expr {$cap == $::env(EXPECT_WIDE)}] "wideCapable = $cap" }
puts "  wideCapable = $cap  (Mk4tcl [expr {[catch {package present Mk4tcl} v] ? {?} : $v}] [expr {[llength [info loaded]] ? {loaded from a library} : {built into the runtime}}])"
ok "wideCapable is cached and stable" [expr {[store::wideCapable] eq $cap}]
ok "the probe leaves no file behind" [expr {[glob -nocomplain -directory [tmpdir] mkstudio-probe-*] eq ""}]

proc refused {file} {
    # a wide file the library cannot read: refused in every mode, and nothing is touched
    set before [slurp $file]
    foreach mode {{} -readonly} {
        set rc [catch {store::openFile $file {*}$mode} m opts]
        ok "refused ($mode)" [expr {$rc && [lrange [dict get $opts -errorcode] 0 1] eq {STORE WIDEFILE}}] "$rc $m"
        ok "message says what to do ($mode)" [string match "*atyr647/metakit*" $m]
    }
    ok "file untouched" [expr {[slurp $file] eq $before}]
    ok "no lock file left" [expr {![file exists $file.lock]}]
    ok "no commit record left" [expr {![file exists $file.commit]}]
    ok "no sum file made" [expr {![file exists $file.sum]}]
    ok "no backup made" [expr {![file exists $file.bak]}]
}
if {!$cap} {
    refused $wide
} else {
    # ---- the 64-bit Metakit: read, change, commit, repair ----
    step "reading the wide file"
    foreach mode {-readonly {}} {
        step "opening the wide file ($mode)"
        set tag [store::openFile $wide {*}$mode]
        step "opened; reading"
        ok "wide file reads ($mode)" [expr {[store::size $tag.t] == 3 && [store::rows $tag.t {name} 1 1] eq {two}}] [store::rows $tag.t {name} 0 9]
        store::closeFile $tag
    }
    step "opening it for writing, appending a row and changing a cell"
    set tag [store::openFile $wide]
    step "opened for writing"
    store::appendRow $tag.t {id name} {4 four}
    store::setCell $tag.t 0 name uno
    step "committing"
    store::commit $tag
    step "committed; closing"
    store::closeFile $tag
    ok "wide file stays wide after a commit" [store::isWide $wide]
    ok "and ends in a valid wide frame" [store::footerOkAt $wide [file size $wide] 1]
    set tag [store::openFile $wide -readonly]
    ok "the commit is there" [expr {[store::size $tag.t] == 4 && [store::rows $tag.t {name} 0 1] eq {uno}}]
    store::closeFile $tag
    step "interrupted commit"
    # an interrupted commit: junk after the last good tails + the record that says what to put back
    set good [slurp $wide] ; set info [store::headerInfo $wide]
    spit $wide $good[string repeat J 5000]
    spit [store::commitRecord $wide] "[dict get $info header] [dict get $info size]"
    set tag [store::openFile $wide]
    ok "interrupted commit on a wide file is put right" [expr {[slurp $wide] eq $good}] "[file size $wide] vs [string length $good]"
    ok "the repair is reported" [expr {[store::repairedNote $tag] ne ""}]
    ok "and the data is intact" [expr {[store::size $tag.t] == 4}]
    store::closeFile $tag
    step "junk without a record"
    # junk after the tails and NO record: a wide file is never cut by the header's offset (it keeps none) - nothing is thrown away
    spit $wide $good[string repeat J 100]
    set tag [store::openFile $wide -readonly] ; store::closeFile $tag
    set tag [store::openFile $wide] ; set note [store::repairedNote $tag] ; store::closeFile $tag
    ok "without a record nothing is cut from a wide file" [expr {[file size $wide] == [string length $good] + 100}] [file size $wide]
    spit $wide $good
    # a record whose state does not end in a valid wide frame: refuse to guess
    spit [store::commitRecord $wide] "[dict get $info header] [expr {[dict get $info size] - 3}]"
    set tag [store::openFile $wide]
    ok "a record pointing into the middle of a frame changes nothing" [expr {[slurp $wide] eq $good}]
    ok "and says so" [string match "Warning*" [store::repairedNote $tag]] [store::repairedNote $tag]
    store::closeFile $tag
    file delete [store::commitRecord $wide]
    step "a child told MKS_WIDE=0"
    # a program whose Mk4tcl cannot read wide files (MKS_WIDE=0, simulated in a new process) refuses it
    set out [childOut $here/wide_child.tcl $wide]
    ok "a program told MKS_WIDE=0 refuses the file" [string match "refused STORE WIDEFILE" $out] $out
    ok "and left it alone" [expr {[slurp $wide] eq $good}]
}

step "the column guard"
# ---- the column guard, with a small limit (it does not depend on the Metakit that is loaded) ----
set ::store::wideCap 1                      ;# switch the guard on whatever the library, for this part
set ::store::maxColumnBytes 20000 ; set ::store::guardSlack 0
set g $dir/guard.mk
step "guard: creating the file"
set db [store::openFile $g -create]
step "guard: creating the table"
store::createView $db t {k:I s:S b:B}
step "guard: appending rows until refused"
set blob [string repeat x 999]
set n 0 ; set code ""
for {set i 0} {$i < 40} {incr i} {
    if {[catch {store::appendRow $db.t {k s} [list $i $blob]} m opts]} { set code [dict get $opts -errorcode] ; break }
    incr n
}
ok "a column past its limit is refused with COLUMNFULL" [expr {[lrange $code 0 1] eq {STORE COLUMNFULL}}] "code=$code after $n rows"
ok "the refusal comes near the limit" [expr {$n >= 19 && $n <= 20}] $n
ok "the refused row was not added" [expr {[store::size $db.t] == $n}]
ok "the message names the column" [string match "*Column s*" $m] $m
step "guard: setCell"
set rc [catch {store::setCell $db.t 0 s [string repeat y 999]} m2 opts2]
ok "setCell is checked" [expr {$rc && [lrange [dict get $opts2 -errorcode] 0 1] eq {STORE COLUMNFULL}}] $m2
ok "other columns are unaffected" [expr {![catch {store::setCell $db.t 0 b small}]}]
step "guard: updateRows"
set rc [catch {store::updateRows $db.t [dict create 0 [list s [string repeat z 999]]]} m3 opts3]
ok "updateRows is checked" [expr {$rc && [lrange [dict get $opts3 -errorcode] 0 1] eq {STORE COLUMNFULL}}] $m3
step "guard: commit"
store::commit $db
# what was committed still counts: the 19-20 small values are in the column, so at most a row or two more fit
set more 0 ; set cc ""
for {set i 0} {$i < 5} {incr i} { if {[catch {store::appendRow $db.t {k s} [list 99 $blob]} m5 o5]} { set cc [dict get $o5 -errorcode] ; break } ; incr more }
ok "still refused after a commit (after $more more rows)" [expr {[lrange $cc 0 1] eq {STORE COLUMNFULL} && $more <= 2}] "$cc / $more"
step "guard: rollback"
store::rollback $db
step "guard: closing"
store::closeFile $db
set ::store::maxColumnBytes 2147483647 ; set ::store::guardSlack 4194304
set ::store::wideCap $cap
# the guard costs nothing when the library is a stock one
if {!$cap} { ok "no guard bookkeeping with a stock Mk4tcl" [expr {[array size ::store::guardBase] == 0}] [array names ::store::guardBase] }

# ---- the error the fork gives for a column past its limit (its "size errors", 2e2e482): translated, the storage can only be rolled back ----
# (a stand-in for mk::row / mk::set that fails the way Mk4tcl does, so this part runs with any Mk4tcl; tests/test_widebig.tcl gets the real error from the real library)
step "the size error of the fork"
set sizeMsg "a column would grow to 2147483700 bytes, more than the limit of 2147483647 bytes for a column: nothing can be committed until mk::file rollback has discarded the changes made since the last commit"
set g2 $dir/fault.mk
set db [store::openFile $g2 -create]
store::createView $db t {k:I s:S}
store::appendRow $db.t {k s} {1 one}
store::commit $db
set before [slurp $g2]
store::appendRow $db.t {k s} {2 two}                 ;# a pending change made before the refused one
set sizeOps {}
foreach {what call} [list appendRow [list store::appendRow $db.t {k s} {3 three}] setCell [list store::setCell $db.t 0 s x] updateRows [list store::updateRows $db.t [dict create 0 {s y}]]] {
    # the stand-in fails once, for the command that the store proc runs
    if {$what eq "appendRow"} { rename ::mk::row ::mk::row_real ; proc ::mk::row args "error {$sizeMsg}" } else { rename ::mk::set ::mk::set_real ; proc ::mk::set args "error {$sizeMsg}" }
    set rc [catch $call m opts]
    if {$what eq "appendRow"} { rename ::mk::row {} ; rename ::mk::row_real ::mk::row } else { rename ::mk::set {} ; rename ::mk::set_real ::mk::set }
    ok "$what: the size error is a COLUMNFULL error" [expr {$rc && [lrange [dict get $opts -errorcode] 0 1] eq {STORE COLUMNFULL}}] "$rc $m"
    ok "$what: the message says what to do" [string match "*Roll Back*" $m] $m
    ok "$what: the message does not talk of Mk4tcl commands" [expr {![string match "*mk::file*" $m]}] $m
    set rc [catch {store::commit $db} m2 opts2]
    ok "$what: a commit is refused at once (STORE TAINTED)" [expr {$rc && [dict get $opts2 -errorcode] eq {STORE TAINTED}}] "$rc $m2"
    ok "$what: ... and says Roll Back" [string match "*Roll Back*" $m2] $m2
    ok "$what: ... without touching the file, writing a commit record or removing the checksum" [expr {[slurp $g2] eq $before && ![file exists $g2.commit]}]
}
# an error that is not a size error comes through unchanged and taints nothing
store::rollback $db
rename ::mk::set ::mk::set_real ; proc ::mk::set args {error "some other failure"}
set rc [catch {store::setCell $db.t 0 s x} m opts]
rename ::mk::set {} ; rename ::mk::set_real ::mk::set
ok "another error is passed on as it is" [expr {$rc && $m eq "some other failure" && [dict get $opts -errorcode] eq "NONE"}] "$m / [dict get $opts -errorcode]"
store::appendRow $db.t {k s} {2 two}
ok "...and does not stop a commit" [expr {![catch {store::commit $db} m]}] $m
# a rollback lifts the mark
rename ::mk::row ::mk::row_real ; proc ::mk::row args "error {$sizeMsg}"
catch {store::appendRow $db.t {k s} {9 nine}}
rename ::mk::row {} ; rename ::mk::row_real ::mk::row
ok "tainted again" [catch {store::commit $db}]
store::rollback $db
ok "after Roll Back the file saves again" [expr {![catch {store::appendRow $db.t {k s} {3 three}} m] && ![catch {store::commit $db} m2]}] "$m $m2"
ok "...with exactly the rows that were committed" [expr {[store::size $db.t] == 3}] [store::size $db.t]
store::closeFile $db
file delete $g2 $g2.commit $g2.sum $g2.lock $g2.bak

step "deleting the folder"
file delete -force $dir
puts "wide: $pass passed, $fail failed" ; flush stdout
exit [expr {$fail ? 1 : 0}]
