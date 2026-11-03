# Bulk-mutation benchmark: MK Studio's tail rebuild (store.tcl) against mkit-sql's scratch-view rebuild,
# on identical files and identical statements; the resulting tables must be identical.
#   MKITSQL_DIR=/path/to/mkit-sql  tclkit tests/bench_mutation.tcl ?rows?
# (Without MKITSQL_DIR only MK Studio's engine is measured.)
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set haveSql [info exists ::env(MKITSQL_DIR)]
set differ 0
if {$haveSql} { source $::env(MKITSQL_DIR)/mkitsql/mkitsql.tcl }
set N [expr {[llength $argv] ? [lindex $argv 0] : 200000}]
proc ms {script} { set t [clock microseconds] ; uplevel 1 $script ; return [expr {([clock microseconds]-$t)/1000.0}] }
set base [tmp bench_mut_base.mk] ; file delete $base $base.lock
if {![file exists $base] || [file size $base] < 100000} {
    set t [store::openFile $base -create]
    store::createView $t t {{id I {}} {grp I {}} {name S {}} {val D {}} {kids V {{k S {}}}}}
    for {set i 0} {$i < $N} {incr i} {
        set r [store::appendRow $t.t {id grp name val} [list $i [expr {$i % 7}] "name number $i" [expr {$i / 4.0}]]]
        if {$i % 10 == 0} { store::appendRow $t.t!$r.kids {k} [list kid$i] }
    }
    store::commit $t ; store::closeFile $t
}
proc dump {t} {
    set out {}
    for {set k 0} {$k < [store::size $t.t]} {incr k} { lappend out [store::captureRow $t.t $k] }
    return $out
}
set work [tmp bench_mut_work.mk]
set loads {
    {DELETE FROM t WHERE id % 2 = 1}
    {DELETE FROM t WHERE id % 50 = 0}
    {DELETE FROM t WHERE id > 190000}
    {UPDATE t SET name = name || 'xx'}
    {UPDATE t SET name = 'x' WHERE id % 20 = 0}
    {UPDATE t SET val = val + 1}
}
puts [format "%-46s %12s %12s %14s   %s" "statement ($N rows, scattered unless noted)" "MK Studio" "mkit-sql" "mkit-sql@1000" "same result?"]
foreach sql $loads {
    set res {} ; set dumps {}
    foreach eng [expr {$haveSql ? {studio sql sql1000} : {studio}}] {
        file copy -force $base $work ; file delete $work.lock
        set t [store::openFile $work]
        if {$eng eq "studio"} { set cmd [list mkql::run $sql $t] } else { set ::mkitsql::bulkMin [expr {$eng eq "sql1000" ? 1000 : 20000}] ; set cmd [list mkitsql::run $sql $t] }
        if {[catch {set time [ms {eval $cmd}]} err]} { lappend res "ERROR" ; lappend dumps $err } else {
            lappend res "[format %.1f [expr {$time / 1000.0}]] s"
            lappend dumps [dump $t]
        }
        store::rollback $t ; store::closeFile $t
    }
    set same identical
    foreach d [lrange $dumps 1 end] { if {$d ne [lindex $dumps 0]} { set same DIFFERENT } }
    if {[llength $dumps] < 2} { set same - }
    if {$same eq "DIFFERENT"} { set ::differ 1 }
    puts [format "%-46s %12s %12s %14s   %s" $sql [lindex $res 0] [expr {[llength $res] > 1 ? [lindex $res 1] : "-"}] [expr {[llength $res] > 2 ? [lindex $res 2] : "-"}] $same]
}
exit [expr {$::differ ? 1 : 0}]
