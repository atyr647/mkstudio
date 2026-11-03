package require Mk4tcl
set here [file dirname [file normalize [info script]]]
foreach f {store mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set f /tmp/persist.mk ; file delete $f
set t [store::createSample $f]
puts "created: [store::views $t] employees=[store::size $t.employees] size=[file size $f]b"
mkql::run "UPDATE products SET stock = 999 WHERE sku = 'MK-001'" $t
store::closeFile $t                      ;# NOT committed
set t [store::openFile $f]
puts "uncommitted lost : [mkql::run {SELECT stock FROM products WHERE sku = 'MK-001'} $t] -> expect 140"
mkql::run "UPDATE products SET stock = 999 WHERE sku = 'MK-001'" $t
store::commit $t ; store::closeFile $t
set t [store::openFile $f]
puts "committed kept   : [dict get [mkql::run {SELECT stock FROM products WHERE sku = 'MK-001'} $t] rows] -> expect 999"
puts "subviews survive : [dict get [mkql::run {SELECT COUNT(*) FROM orders[0].lines} $t] rows]"
set ro [store::openFile /tmp/persist.mk -readonly] 2>/dev/null
exit
