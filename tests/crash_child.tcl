# crash_child.tcl -- the process that gets killed by test_crash_safety.tcl.
#   tclkit tests/crash_child.tcl <mode> <db> <progress-prefix>
# Progress is reported through small files (<prefix>.started / .committed / .ready) because
# the Windows tclkit has no console for pipes.
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
foreach f {store} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
lassign $argv mode dbfile prog
# a 1.5 KB payload that depends on the generation, so a commit writes megabytes and is a real window
proc stamp {g i} { return "[format {g%07d-r%05d} $g $i][string repeat [format %c [expr {97 + ($g + 1000) % 26}]] 1500]" }
proc note {name val} { global prog ; set h [open $prog.$name w] ; puts -nonewline $h $val ; close $h }
set t [store::openFile $dbfile]
set n [store::size $t.items]
switch -- $mode {
    commitloop {
        # rewrite every row to generation g, then commit; forever.  chk = g*100000 + id
        for {set g 1} {$g < 1000000} {incr g} {
            # fixed-width label: rewriting it never shifts the rest of the string column
            for {set i 0} {$i < $n} {incr i} {
                mk::set $t.items!$i gen $g chk [expr {$g * 100000 + $i}] label [stamp $g $i]
            }
            store::touch $t
            note started $g
            set t0 [clock microseconds]
            store::commit $t
            note dur [expr {[clock microseconds] - $t0}]
            note committed $g
        }
    }
    structloop {
        # alternately add and drop a column (a structural commit), forever
        for {set g 1} {$g < 1000000} {incr g} {
            set layout [store::layout $t.items]
            if {[store::findCol $layout extra] eq ""} {
                store::restructure $t.items [concat $layout [list {extra I {}}]]
                for {set i 0} {$i < $n} {incr i} { store::setCell $t.items $i extra $g }
            } else {
                set new {}
                foreach c $layout { if {[lindex $c 0] ne "extra"} { lappend new $c } }
                store::restructure $t.items $new
            }
            note started $g
            set t0 [clock microseconds]
            store::commit $t
            note dur [expr {[clock microseconds] - $t0}]
            note committed $g
        }
    }
    holdlock {
        note ready 1
        after 600000 {set forever 1}
        vwait forever
    }
    editkill {
        # lots of UNcommitted edits (cells, adds, deletes, a restructure), then wait to be killed
        for {set i 0} {$i < $n} {incr i} { mk::set $t.items!$i label [stamp -1 $i] }
        for {set i 0} {$i < 500} {incr i} { store::appendRow $t.items {id gen chk label} [list [expr {$n + $i}] -1 -1 added] }
        store::deleteRows $t.items {0 1 2 3 4 5}
        store::restructure $t.items [concat [store::layout $t.items] [list {scratch D {}}]]
        note ready 1
        after 600000 {set forever 1}
        vwait forever
    }
}
exit 0
