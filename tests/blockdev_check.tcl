# blockdev_check.tcl -- what one simulated power cut left behind: open the database the way MK Studio would and say which commit's state it holds.
#   tclkit tests/blockdev_check.tcl <db-file> <expected-file> <lowest-allowed> <highest-allowed>
# Exit status 0 and "STATE <k>" (k = 0: no file, an empty one, or a database with no tables - nothing was ever saved) when the state is one of the allowed ones; 1 and "FAIL ..." otherwise.
#   lowest  = the last commit that had been ACKNOWLEDGED when the power went (it must still be there)
#   highest = the last commit that had BEGUN (a commit in flight may or may not have landed; nothing newer can exist)
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv db expected lo hi
proc digest {t} {
    set d ""
    foreach r [store::rows $t.items {id gen label} 0 [store::size $t.items]] { append d [join $r ,] \n }
    return [zlib crc32 $d]
}
array set want {}
set h [open $expected r] ; foreach l [split [string trim [read $h]] \n] { set want([lindex $l 0]) [lindex $l 1] } ; close $h
proc fail {why} { puts "FAIL $why" ; exit 1 }
if {![file exists $db] || [file size $db] == 0} {
    set state 0 ; set note [expr {[file exists $db] ? "empty file" : "no file"}]
} else {
    if {[catch {store::openFile $db} t opts]} { fail "the database does not open: $t" }
    set note "opened"
    if {[store::repairedNote $t] ne ""} { append note "; repaired: [string map [list \n { }] [store::repairedNote $t]]" }
    set verdict [store::integrityState $t]
    if {$verdict eq "damaged"} { fail "the checksum calls the file damaged after an ordinary power cut ($note)" }
    if {![store::hasView $t items]} {
        # an interrupted FIRST save was undone: the database is empty again (the commit record said "empty") - state 0, nothing was ever saved
        store::closeFile $t
        set state 0
    } else {
        if {[catch {digest $t} dg]} { fail "the rows cannot be read: $dg" }
        store::closeFile $t
        set state -1
        for {set k 1} {$k <= $hi} {incr k} { if {[info exists want($k)] && $want($k) eq $dg} { set state $k } }
        if {$state < 0} { fail "the table is none of the states 1..$hi (digest $dg; $note)" }
    }
}
if {$state < $lo} { fail "an acknowledged commit is lost: the database holds state $state, commit $lo had been acknowledged ($note)" }
if {$state > $hi} { fail "state $state is newer than any commit that had begun ($hi)" }
puts "STATE $state ($note)"
exit 0
