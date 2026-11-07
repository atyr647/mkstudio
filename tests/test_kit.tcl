# Ribbon kits in MK Studio (needs a display and real Metakit):   REAL_MK=1 xvfb-run -a tclkit tests/run.tcl tests/test_kit.tcl
#
#   - Metakit data after a header (a starkit, a kit) is recognised from the end of the file, and opened read-only;
#     files that are not Metakit stay refused, also when they end like one or begin with "JL"
#   - bytes cells: the grid and the bytes viewer read the size and the first bytes only, never the whole value
#   - the Kit tab: manifest, file tree, preview, verify in a separate process (progress, results, a damaged kit), extract,
#     the embedded image of a system kit; nothing is ever written next to a kit
# The kits are Ribbon's golden kits (tests/kits, synced with tools/sync-kitfmt.sh).
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
set ::mkstudio_root [file join $here .. mkstudio.vfs]
if {![info exists ::env(REAL_MK)]} { puts "test_kit needs REAL_MK=1 (real Metakit)" ; exit 2 }
package require Mk4tcl
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) [tmp mks_home_kit] ; file mkdir $::env(HOME)
::app::main {}
update
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 300]> want <$want>"} }
proc slurp {f} { set h [open $f rb] ; set d [read $h] ; close $h ; return $d }
proc spit {f d} { set h [open $f wb] ; puts -nonewline $h $d ; close $h }
set dir [tmp mks_kit_[pid]] ; file delete -force $dir ; file mkdir $dir
foreach k {app app-header system bad-chunk} { file copy $here/kits/$k.kit $dir/$k.kit }

# ---- 1. finding Metakit data after a header ------------------------------------------------------------------------------
check frame_kit [dict get [::store::metakitFrame $dir/app-header.kit] start] 4176
set sample [tmp mks_kit_sample.mk]
file delete $sample ; set t [::store::createSample $sample] ; ::store::closeFile $t
check frame_plain [dict get [::store::metakitFrame $sample] start] 0
check sig_kit [::store::hasMetakitSignature $dir/app-header.kit] 1
# a starkit made the classic way: a script, then an ordinary datafile appended (sdx wrap does exactly this)
spit $dir/starkit.kit "#!/bin/sh\n# a starkit header\nexec tclkit \"\$0\" \"\$@\"\n[slurp $sample]"
check sig_starkit [::store::hasMetakitSignature $dir/starkit.kit] 1
set st [::store::openFile $dir/starkit.kit]
check starkit_readonly [::store::readonly $st] 1
check starkit_header [::store::headerBytes $st] [expr {[file size $dir/starkit.kit] - [file size $sample]}]
check starkit_views [expr {[llength [::store::views $st]] > 0}] 1
::store::closeFile $st
# never weaker for files that are not Metakit
spit $dir/text.txt [string repeat "plain text, not a database\n" 50]
check sig_text [::store::hasMetakitSignature $dir/text.txt] 0
check open_text [catch {::store::openFile $dir/text.txt -readonly} m] 1
check open_text_msg [string match "*isn't a Metakit database*" $m] 1
# the right tails at the end but no Metakit header where they point
set fake [string repeat x 200][binary format cccc 0x80 0 0 0][binary format I 50][binary format cccc 0x80 0 0 1][binary format I 10]
spit $dir/fake.bin $fake
check sig_fake_tails [::store::hasMetakitSignature $dir/fake.bin] 0
check open_fake [catch {::store::openFile $dir/fake.bin -readonly}] 1
# a truncated kit: no tails at the end any more
spit $dir/cut.kit [string range [slurp $dir/app.kit] 0 [expr {[file size $dir/app.kit] * 7 / 10}]]
check frame_cut [::store::metakitFrame $dir/cut.kit] ""
check sig_cut [::store::hasMetakitSignature $dir/cut.kit] 0
check no_side_files [lsort [glob -tails -directory $dir *]] {app-header.kit app.kit bad-chunk.kit cut.kit fake.bin starkit.kit system.kit text.txt}

# ---- 2. big bytes cells: size and first bytes only ------------------------------------------------------------------
set bf [tmp mks_kit_big.mk] ; file delete $bf
set bt [::store::openFile $bf -create]
::store::createView $bt img {{name S {}} {data B {}}}
set big [string repeat [binary format c* {1 2 3 4 5 6 7 8 9 10 11 12}] 400000]
::store::appendRow $bt.img {name data} [list big $big]
::store::appendRow $bt.img {name data} [list small abc]
::store::commit $bt
set ::fullReads 0
rename ::mk::get ::mk::get_real
proc ::mk::get {cursor args} {
    if {[lindex $args 0] ne "-size" && [lsearch -exact $args data] >= 0} { incr ::fullReads }
    return [::mk::get_real $cursor {*}$args]
}
check cell_size [::store::cellSize $bt.img 0 data] [string length $big]
check cell_range [::store::cellRange $bt.img 0 data 10 4] [string range $big 10 13]
set id [::app::openData $bt.img img]
update
set g [::app::docFrame $id].g
set label [lindex [::grid::mksrc $g rows 0 1] 0 1]
check grid_label $label "<[string length $big] bytes>  01 02 03 04 05 06 07 08 09 0a ..."
check grid_small [lindex [::grid::mksrc $g rows 1 1] 0 1] "<3 bytes>  61 62 63"
set out [tmp mks_kit_export.bin]
set ch [open $out wb] ; ::store::cellCopy $bt.img 0 data $ch ; close $ch
check export_bytes [expr {[slurp $out] eq $big}] 1
check grid_never_read_whole $::fullReads 0
file delete $out
rename ::mk::get {} ; rename ::mk::get_real ::mk::get
::app::closeDB $bt 1

# ---- 3. the Kit tab -------------------------------------------------------------------------------------------------------
set before [slurp $dir/app.kit]
set tag [::app::openOne $dir/app.kit]
update
check kit_readonly [::store::readonly $tag] 1
set kid ""
foreach d [::app::docs] { if {[::app::docType $d] eq "kit"} { set kid $d } }
check kit_tab_opened [expr {$kid ne ""}] 1
set f [::app::docFrame $kid]
check kit_title [$f.head.title cget -text] "org.ribbon.golden.app  1.2.0"
check kit_summary [string match "App kit*15 entries*" [$f.head.sub cget -text]] 1
check kit_seal [string match "*Signed by key CF096CB575EDBA78*content matches the seal*" [$f.head.seal cget -text]] 1
set t $::kitdoc::K($kid,ftree)
check tree_top [$t children {}] {bin docs empty lib main.tcl share}
check tree_big [$t item lib/big.txt -values] {{45.3 KB} 3 deflate {6.5 KB}}
# preview: text, image, hex
$t selection set lib/big.txt ; update
check preview_text [string match "line 1 of the golden kit*" [$f.body.files.pv.t get 1.0 end]] 1
$t selection set share/icons/hello.png ; update
# (Tk 8.5 has no PNG: the preview is then the hex dump)
check preview_image [expr {$::kitdoc::K($kid,img) ne "" && [image width $::kitdoc::K($kid,img)] == 16}] [package vsatisfies [package present Tk] 8.6]
$t selection set lib/noise.bin ; update
check preview_hex [string match "00000000  *" [$f.body.files.pv.t get 1.0 end]] 1
$t selection set lib/hello-link ; update
check preview_link [string trim [$f.body.files.pv.t get 1.0 end]] "\u2192 ../bin/hello"
# manifest page
set mt $f.body.manifest.t
set names {} ; foreach s [$mt children {}] { lappend names [$mt item $s -text] }
check manifest_sections $names {IDENTITY {NEEDS (2)} {PROVIDES (1)} {PERMISSION REQUESTS (4)} {ENTRY POINTS (2)} {EFFECTS (2)} SEAL}
# verify, in a separate process
proc waitVerify {kid} {
    for {set i 0} {$i < 600 && $::kitdoc::K($kid,busy)} {incr i} { after 100 ; update }
}
::kitdoc::verify $kid
check verify_busy $::kitdoc::K($kid,busy) 1
waitVerify $kid
check verify_done [dict get $::kitdoc::K($kid,verified) ok] 1
check verify_status [string match "Verified: every chunk matches*" [$f.info.l cget -text]] 1
set vt $::kitdoc::K($kid,vtree)
set first {} ; foreach i [$vt children {}] { lappend first [$vt item $i -text] [lindex [$vt item $i -values] 0] }
check verify_rows [lrange $first 0 5] {Header ok {Root hash} ok Signature unchecked}
# extract a folder and a file
set xd [tmp mks_kit_x_[pid]] ; file delete -force $xd ; file mkdir $xd
check extract_share [::kitdoc::extract $kid share $xd] 2
check extract_file [::kitdoc::extract $kid lib/big.txt $xd] 1
check extract_content [expr {[slurp $xd/big.txt] eq [kitfmt read $::kitdoc::K($kid,h) lib/big.txt]}] 1
check extract_tree [lsort [glob -tails -directory $xd/share *]] {applications icons}
file delete -force $xd
# the SQL engine sees the same kit through kit.* tables
set r [::mkitsql::query "SELECT path, chunks FROM kit.files WHERE type = 'file' AND chunks > 1" $tag]
check sql_kit_files [dict get $r rows] {{lib/big.txt 3}}
::app::closeDB $tag
check kit_tab_closed [llength [array names ::kitdoc::K $kid,*]] 0
check kit_untouched [expr {[slurp $dir/app.kit] eq $before}] 1

# a damaged kit: the tab opens, verify names the chunk
set tag [::app::openOne $dir/bad-chunk.kit]
update
foreach d [::app::docs] { if {[::app::docType $d] eq "kit"} { set kid $d } }
::kitdoc::verify $kid ; waitVerify $kid
check damaged_not_ok [dict get $::kitdoc::K($kid,verified) ok] 0
check damaged_names_chunk [lrange [lindex [dict get $::kitdoc::K($kid,verified) bad] 0] 0 1] {lib/big.txt 1}
check damaged_status [string match "DAMAGED: 1 problem*" [[::app::docFrame $kid].info.l cget -text]] 1
# a preview of the damaged chunk is an error message, never wrong bytes
set t $::kitdoc::K($kid,ftree)
$t selection set lib/big.txt ; update
check damaged_preview [string match "This file cannot be read:*does not match its hash*" [[::app::docFrame $kid].body.files.pv.t get 1.0 end]] 1
# Cancel stops the verifier process
::kitdoc::verify $kid
set pids [pid $::kitdoc::K($kid,chan)]
::kitdoc::cancel $kid
check cancel_done [list $::kitdoc::K($kid,busy) [dict get $::kitdoc::K($kid,verified) cancelled]] {0 1}
::app::closeDB $tag

# a system kit: the Image page
set tag [::app::openOne $dir/system.kit]
update
foreach d [::app::docs] { if {[::app::docType $d] eq "kit"} { set kid $d } }
set it [::app::docFrame $kid].body.image.t
set rows {} ; foreach i [$it children {}] { lappend rows [$it item $i -text] [lindex [$it item $i -values] 0] }
check image_fs [lrange $rows 0 3] {Filesystem erofs {File offset} {8192 (4 KiB aligned: yes)}}
check image_tab [::tabs::exists [::app::docFrame $kid].tabs image] 1
::kitdoc::verify $kid ; waitVerify $kid
check system_verify [list [dict get $::kitdoc::K($kid,verified) ok] [dict get $::kitdoc::K($kid,verified) image]] {1 ok}
::app::closeDB $tag

check nothing_written [lsort [glob -tails -directory $dir *]] {app-header.kit app.kit bad-chunk.kit cut.kit fake.bin starkit.kit system.kit text.txt}
file delete -force $dir $sample $bf
puts "test_kit: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
