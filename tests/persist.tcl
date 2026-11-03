# Commit / rollback / close semantics on real files.   tclkit tests/persist.tcl
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <$got> want <$want>"} }
proc stock {t} { lindex [dict get [mkql::run {SELECT stock FROM products WHERE sku = 'MK-001'} $t] rows] 0 0 }
set f /tmp/persist.mk ; file delete $f
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
check not_metakit [catch {store::openFile /etc/hostname}] 1
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
