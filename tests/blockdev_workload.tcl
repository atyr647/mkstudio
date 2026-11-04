# blockdev_workload.tcl -- the workload of the block-level crash test (tests/blockdev_crash.sh): a series of real commits through MK Studio's
# store (with its commit record, backup, checksum and the durable flushes) on a file system that sits on a dm-log-writes device.
#   tclkit tests/blockdev_workload.tcl <folder-on-that-file-system> <commits> <expected-file> <dm-device-name>
# After every step it puts a MARK into the device's log (dmsetup message ... mark ...):  begin-<k> before commit k, ack-<k> after commit k returned
# (so the test can tell which commits were acknowledged when the power "failed"), and writes the digest of the table after each commit to
# <expected-file> (which lives OUTSIDE the device).
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv dir n expected dev
proc mark {name} { global dev ; exec dmsetup message $dev 0 mark $name }
proc digest {t} {
    set d ""
    foreach r [store::rows $t.items {id gen label} 0 [store::size $t.items]] { append d [join $r ,] \n }
    return [zlib crc32 $d]
}
proc record {k t} { global expected ; set h [open $expected a] ; puts $h "$k [digest $t]" ; close $h }
set db $dir/crash.mk
file delete $expected
puts "flush method: [store::flushMethod]"
# commit 1: the first commit of a new database (the commit record says "empty")
set t [store::openFile $db -create]
store::createView $t items {id:I gen:I label:S}
for {set i 1} {$i <= 300} {incr i} { store::appendRow $t.items {id gen label} [list $i 1 "row $i"] }
mark begin-1
store::commit $t
mark ack-1
record 1 $t
# commits 2..n: edit a cell, add rows (the file grows, the header at offset 0 is rewritten)
for {set k 2} {$k <= $n} {incr k} {
    set size [store::size $t.items]
    store::setCell $t.items [expr {($k * 7) % $size}] gen $k
    store::setCell $t.items [expr {($k * 11) % $size}] label "edited in commit $k"
    for {set i 0} {$i < 50} {incr i} { store::appendRow $t.items {id gen label} [list [expr {$size + $i + 1}] $k "added in $k"] }
    mark begin-$k
    store::commit $t
    mark ack-$k
    record $k $t
    # halfway: close and open again - a second editing session, which takes the lock afresh, checks the checksum of what the first one
    # left and makes the backup of the file before its first commit
    if {$k == $n / 2} { store::closeFile $t ; mark reopened ; set t [store::openFile $db] }
}
store::closeFile $t
mark closed
puts "workload done: $n commits"
