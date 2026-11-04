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
    foreach mode {-readonly {}} {
        set tag [store::openFile $wide {*}$mode]
        ok "wide file reads ($mode)" [expr {[store::size $tag.t] == 3 && [store::rows $tag.t {name} 1 1] eq {two}}] [store::rows $tag.t {name} 0 9]
        store::closeFile $tag
    }
    set tag [store::openFile $wide]
    store::appendRow $tag.t {id name} {4 four}
    store::setCell $tag.t 0 name uno
    store::commit $tag
    store::closeFile $tag
    ok "wide file stays wide after a commit" [store::isWide $wide]
    ok "and ends in a valid wide frame" [store::footerOkAt $wide [file size $wide] 1]
    set tag [store::openFile $wide -readonly]
    ok "the commit is there" [expr {[store::size $tag.t] == 4 && [store::rows $tag.t {name} 0 1] eq {uno}}]
    store::closeFile $tag
    # an interrupted commit: junk after the last good tails + the record that says what to put back
    set good [slurp $wide] ; set info [store::headerInfo $wide]
    spit $wide $good[string repeat J 5000]
    spit [store::commitRecord $wide] "[dict get $info header] [dict get $info size]"
    set tag [store::openFile $wide]
    ok "interrupted commit on a wide file is put right" [expr {[slurp $wide] eq $good}] "[file size $wide] vs [string length $good]"
    ok "the repair is reported" [expr {[store::repairedNote $tag] ne ""}]
    ok "and the data is intact" [expr {[store::size $tag.t] == 4}]
    store::closeFile $tag
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
    # a program whose Mk4tcl cannot read wide files (MKS_WIDE=0, simulated in a new process) refuses it
    set out [lindex [split [string trim [exec [info nameofexecutable] $here/wide_child.tcl $wide 2>@1]] "\n"] end]
    ok "a program told MKS_WIDE=0 refuses the file" [string match "refused STORE WIDEFILE" $out] $out
    ok "and left it alone" [expr {[slurp $wide] eq $good}]
}

# ---- the column guard, with a small limit (it does not depend on the Metakit that is loaded) ----
set ::store::wideCap 1                      ;# switch the guard on whatever the library, for this part
set ::store::maxColumnBytes 20000 ; set ::store::guardSlack 0
set g $dir/guard.mk
set db [store::openFile $g -create]
store::createView $db t {k:I s:S b:B}
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
set rc [catch {store::setCell $db.t 0 s [string repeat y 999]} m2 opts2]
ok "setCell is checked" [expr {$rc && [lrange [dict get $opts2 -errorcode] 0 1] eq {STORE COLUMNFULL}}] $m2
ok "other columns are unaffected" [expr {![catch {store::setCell $db.t 0 b small}]}]
set rc [catch {store::updateRows $db.t [dict create 0 [list s [string repeat z 999]]]} m3 opts3]
ok "updateRows is checked" [expr {$rc && [lrange [dict get $opts3 -errorcode] 0 1] eq {STORE COLUMNFULL}}] $m3
store::commit $db
ok "still refused after a commit" [catch {store::appendRow $db.t {k s} [list 99 $blob]}]
store::rollback $db
store::closeFile $db
set ::store::maxColumnBytes 2147483647 ; set ::store::guardSlack 4194304
set ::store::wideCap $cap
# the guard costs nothing when the library is a stock one
if {!$cap} { ok "no guard bookkeeping with a stock Mk4tcl" [expr {[array size ::store::guardBase] == 0}] [array names ::store::guardBase] }

file delete -force $dir
puts "wide: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
