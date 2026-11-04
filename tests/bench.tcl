# Scale benchmark on real Metakit:  tclkit tests/bench.tcl ?rows?        (MKS_ENGINE=mkql: the built-in dialect; default: mkit-sql)
# Statements go through whichever engine the program would start with.
package require Mk4tcl
set root [file dirname [file normalize [info script]]]/../mkstudio.vfs/lib
foreach f {store engine mkql} { source $root/app-mkstudio/$f.tcl }
set useMkql [expr {[info exists ::env(MKS_ENGINE)] && $::env(MKS_ENGINE) eq "mkql"}]
if {!$useMkql} { source $root/mkitsql/mkitsql.tcl ; source $root/mkitsql/engine_studio.tcl }
puts "engine: $::engine::name  (Tcl [info patchlevel])"
proc q {sql t} { if {$::useMkql} { return [mkql::run $sql $t] } ; return [::mkitsql::run $sql $t] }
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
puts "SELECT LIMIT 100:        [ms {q {SELECT * FROM big LIMIT 100} $t}]"
puts "SELECT WHERE (full scan):[ms {set r [q {SELECT id, name FROM big WHERE dept = 7 AND salary > 60000 LIMIT 100000} $t] ; puts "   -> [llength [dict get $r rows]] rows"}]"
puts "SELECT WHERE dept=7 (pushdown): [ms {set r [q {SELECT id, name FROM big WHERE dept = 7 AND salary > 60000} $t] ; puts "   -> [llength [dict get $r rows]] rows"}]"
puts "SELECT WHERE name LIKE (scan): [ms {set r [q {SELECT id FROM big WHERE name LIKE 'person 4999%'} $t] ; puts "   -> [llength [dict get $r rows]] rows"}]"
puts "COUNT(*):                [ms {q {SELECT COUNT(*) FROM big} $t}]"
puts "COUNT(*) WHERE salary>:  [ms {q {SELECT COUNT(*) FROM big WHERE salary >= 100000 AND dept IN (1,2,3)} $t}]"
puts "SUM/MIN/MAX no filter:   [ms {q {SELECT SUM(salary), MIN(salary), MAX(dept) FROM big} $t}]"
puts "COUNT(*) GROUP BY:       [ms {q {SELECT dept, COUNT(*), AVG(salary) FROM big GROUP BY dept} $t}]"
puts "ORDER BY salary LIMIT 50:[ms {q {SELECT id, salary FROM big ORDER BY salary DESC LIMIT 50} $t}]"
puts "ORDER BY name LIMIT 50: [ms {q {SELECT id, name FROM big ORDER BY name LIMIT 50} $t}]"
puts "DELETE 10k scattered rows (rollback): [ms {q {DELETE FROM big WHERE dept = 49} $t ; store::rollback $t}]"
puts "UPDATE 10k scattered rows (rollback): [ms {q {UPDATE big SET note = 'y' WHERE dept = 3} $t ; store::rollback $t}]"
puts "SELECT * (500k rows, lazy):    [ms {set r [q {SELECT * FROM big} $t] ; puts "   -> lazy=[dict exists $r provider] rows=[expr {[dict exists $r provider] ? [{*}[dict get $r provider] count] : [llength [dict get $r rows]]}]"}]"
puts "SELECT ... ORDER BY salary (all 500k, lazy): [ms {q {SELECT id, salary FROM big ORDER BY salary DESC} $t}]"
puts "  ... again (sorted column cached):          [ms {q {SELECT id, salary FROM big ORDER BY salary ASC} $t}]"
puts "ORDER BY salary LIMIT 50, cached column:     [ms {q {SELECT id, salary FROM big ORDER BY salary DESC LIMIT 50} $t}]"
puts "UPDATE 10k rows (contiguous, rollback): [ms {q {UPDATE big SET note = 'x' WHERE id < 10000} $t ; store::rollback $t}]"
exit
