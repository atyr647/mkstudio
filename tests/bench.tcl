# Scale benchmark on real Metakit:  tclkit tests/bench.tcl ?rows?
package require Mk4tcl
foreach f {store engine mkql} { source [file dirname [file normalize [info script]]]/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set N [expr {[llength $argv] ? [lindex $argv 0] : 500000}]
set f /tmp/big.mk
proc ms {script} { set t [clock milliseconds] ; set r [uplevel 1 $script] ; return [list [expr {[clock milliseconds]-$t}] ms] }
if {![file exists $f] || [file size $f] < 1000000} {
    file delete $f
    set t [store::openFile $f -create]
    store::createView $t big {{id I {}} {name S {}} {dept I {}} {salary D {}} {note S {}} {tags V {{tag S {}}}}}
    puts "build $N rows: [ms {
        for {set i 0} {$i < $N} {incr i} {
            set r [store::appendRow $t.big {id name dept salary note} [list $i "person $i" [expr {$i % 50}] [expr {30000 + ($i * 37) % 90000}] "some note text number $i"]]
            if {$i % 10 == 0} { store::appendRow $t.big!$r.tags {tag} [list t$i] }
        }
        store::commit $t
    }]  size=[expr {[file size $f]/1048576}]MB"
    store::closeFile $t
}
puts "open:                    [ms {set t [store::openFile $f]}]"
puts "views+layout+size:       [ms {store::views $t ; store::layout $t.big ; store::size $t.big}]"
puts "rows 0..20000 (6 cols):  [ms {store::rows $t.big {id name dept salary note} 0 20000}]"
puts "rows 20000 + subsizes:   [ms {for {set i 0} {$i < 20000} {incr i} {store::subSize $t.big $i tags}}]"
puts "SELECT LIMIT 100:        [ms {mkql::run {SELECT * FROM big LIMIT 100} $t}]"
puts "SELECT WHERE (full scan):[ms {set r [mkql::run {SELECT id, name FROM big WHERE dept = 7 AND salary > 60000 LIMIT 100000} $t] ; puts "   -> [llength [dict get $r rows]] rows"}]"
puts "COUNT(*) GROUP BY:       [ms {mkql::run {SELECT dept, COUNT(*), AVG(salary) FROM big GROUP BY dept} $t}]"
puts "ORDER BY salary LIMIT 50:[ms {mkql::run {SELECT id, salary FROM big ORDER BY salary DESC LIMIT 50} $t}]"
puts "UPDATE 10k rows:         [ms {mkql::run {UPDATE big SET note = 'x' WHERE id < 10000} $t}]"
exit
