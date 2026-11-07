# Commit / rollback / close semantics on real files.   tclkit tests/persist.tcl
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <$got> want <$want>"} }
proc stock {t} { lindex [dict get [mkql::run {SELECT stock FROM products WHERE sku = 'MK-001'} $t] rows] 0 0 }
set f [tmp persist.mk] ; file delete $f
set t [store::createSample $f]
check created [store::views $t] {departments employees orders products}
check sub_layout [store::layout $t.orders!0.lines] {{sku S {}} {qty I {}} {unit D {}}}
mkql::run "UPDATE products SET stock = 999 WHERE sku = 'MK-001'" $t
check dirty_count [expr {[store::dirty $t] > 0}] 1
store::closeFile $t                         ;# closing must NOT commit
set t [store::openFile $f]
check uncommitted_discarded [stock $t] 140
mkql::run "UPDATE products SET stock = 999 WHERE sku = 'MK-001'" $t
store::commit $t ; store::closeFile $t
set t [store::openFile $f]
check committed_kept [stock $t] 999
mkql::run "UPDATE products SET stock = 5 WHERE sku = 'MK-001'" $t
store::rollback $t
check rollback [stock $t] 999
check same_file_twice [catch {store::openFile $f}] 1
store::closeFile $t
set ro [store::openFile $f -readonly]
check readonly_flag [store::readonly $ro] 1
check readonly_write_blocked [catch {mkql::run "DELETE FROM orders" $ro}] 1
check subviews_survive [dict get [mkql::run {SELECT COUNT(*) FROM orders[0].lines} $ro] rows] {2}
check missing_file [catch {store::openFile /nonexistent/x.mk}] 1
set txt [tmp not_metakit.txt] ; foreach x [glob -nocomplain $txt.*] { file delete $x }
set h [open $txt w] ; puts $h "just some text" ; close $h ; set sz [file size $txt] ; set mt [file mtime $txt] ; set ntags [llength [store::tags]]
check not_metakit [catch {store::openFile $txt} m] 1
check not_metakit_msg [string match "*isn't a Metakit database*" $m] 1
check not_metakit_untouched [list [file size $txt] [file mtime $txt]] [list $sz $mt]
# refused before anything is written next to it: no checksum, lock, commit record or backup is left behind (a .sum used to be)
check not_metakit_nothing_beside [glob -nocomplain -tails -directory [file dirname $txt] [file tail $txt].*] {}
check not_metakit_readonly [catch {store::openFile $txt -readonly}] 1
check not_metakit_readonly_nothing_beside [glob -nocomplain -tails -directory [file dirname $txt] [file tail $txt].*] {}
check not_metakit_not_listed [llength [store::tags]] $ntags
# ---- an interrupted commit is put right when the database is next opened for writing --------------------------------
# (the byte-level evidence for this is tests/test_power_loss.tcl; this checks the behaviour of the store itself)
set g [tmp interrupted.mk] ; foreach x [glob -nocomplain $g*] { file delete $x }
set t [store::createSample $g] ; store::commit $t ; store::closeFile $t
check commit_leaves_no_record [file exists $g.commit] 0
set sizeA [file size $g] ; set hdrA [dict get [store::headerInfo $g] header]
check header_offset_is_file_size [dict get [store::headerInfo $g] offset] $sizeA
set t [store::openFile $g]
store::setCell $t.products 0 stock 4242 ; store::commit $t ; store::closeFile $t
set sizeB [file size $g]
check commit_grew_the_file [expr {$sizeB > $sizeA}] 1
# simulate: killed after the new data was appended but before the header was rewritten
file copy -force $g $g.done
set h [open $g r+b] ; seek $h 0 start ; puts -nonewline $h [binary format H* $hdrA] ; close $h      ;# old header, longer file
set ro [store::openFile $g -readonly]
# (what Metakit makes of such a file depends on the commit: an empty database for a big append, the old state for a small one)
store::closeFile $ro
check readonly_open_does_not_repair [file size $g] $sizeB
set t [store::openFile $g]
check repaired_to_old_size [file size $g] $sizeA
check repaired_data_is_the_old_state [stock $t] [lindex [dict get [mkql::run {SELECT stock FROM products WHERE sku = 'MK-001'} $t] rows] 0 0]
check repair_is_reported [expr {[store::repairedNote $t] ne ""}] 1
check old_views_back [store::views $t] {departments employees orders products}
store::closeFile $t
check repair_note_gone_after_close [store::repairedNote $t] ""
# the commit record: found at open => the header and size are put back, even if the file was fully written
file copy -force $g.done $g
set h [open $g.commit w] ; puts -nonewline $h "$hdrA $sizeA" ; close $h
set t [store::openFile $g]
check record_rolls_back_to_before_the_commit [file size $g] $sizeA
check record_removed [file exists $g.commit] 0
store::closeFile $t
# a record for a commit that never wrote anything is just removed
set h [open $g.commit w] ; puts -nonewline $h "$hdrA $sizeA" ; close $h
set t [store::openFile $g] ; check record_for_untouched_file_removed [list [file exists $g.commit] [file size $g]] [list 0 $sizeA] ; store::closeFile $t
# a file shorter than the record says cannot be repaired: it is left alone and the user is warned
set sh [tmp interrupted_short.mk] ; foreach x [glob -nocomplain $sh*] { file delete $x }
file copy -force $g $sh ; set hh [open $sh r+b] ; chan truncate $hh [expr {$sizeA - 100}] ; close $hh
set h [open $sh.commit w] ; puts -nonewline $h "$hdrA $sizeA" ; close $h
catch {set t [store::openFile $sh] ; set note [store::repairedNote $t] ; store::closeFile $t}
check short_file_warned [string match "Warning*" $note] 1
# a normal commit still works and leaves nothing behind
set t [store::openFile $g]
store::setCell $t.products 0 stock 7 ; store::commit $t
check normal_commit_after_repair [list [stock $t] [file exists $g.commit]] [list 7 0]
store::closeFile $t
set t [store::openFile $g] ; check commit_survived_reopen [stock $t] 7 ; store::closeFile $t
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
