# power_child.tcl -- opens candidate "after power loss" files one by one and classifies what it finds.
#   tclkit tests/power_child.tcl <result-file> <fileA> <fileB> <list-file> ?raw|truncate|record|own?
# fileA / fileB are the committed states before / after the interrupted commit; <list-file> has one candidate path
# per line.  Mode raw opens each candidate read-only exactly as it is (what Metakit alone makes of it); truncate and
# record open a COPY for writing, the way MK Studio does (which repairs an interrupted commit), the latter with the
# <file>.commit record that a commit leaves behind until it has been forced to disk.  Mode own uses the record that
# really sits next to the candidate (left by a real commit that was killed).  For each candidate a line is appended to <result-file>:
#   START <n>                       (written BEFORE the open, so a crash of Metakit itself can be attributed)
#   <n> OLD | NEW                   the file opens and holds exactly state A / state B
#   <n> SILENT <what differs>       it opens, but holds neither (silent corruption)
#   <n> DETECTED <message>          it does not open: Metakit or the store noticed
package require Mk4tcl
set here [file dirname [file normalize [info script]]]
source $here/../mkstudio.vfs/lib/app-mkstudio/store.tcl
lassign $argv result fileA fileB listfile mode
if {$mode eq ""} { set mode raw }
proc say {line} { global result ; set h [open $result a] ; fconfigure $h -translation lf ; puts $h $line ; close $h }
# the complete logical content of a view: its layout and every row (subviews included), read in bulk
proc dumpview {path} {
    set name [lindex [split $path .] end]
    set layout [store::layout $path]
    set props {} ; set subs {}
    foreach c $layout { if {[lindex $c 1] eq "V"} { lappend subs $c } else { lappend props [lindex $c 0] } }
    set n [store::size $path]
    set rows [store::fetch $path $props 0 $n]
    set out {} ; set i 0
    foreach r $rows {
        set row [list $r]
        foreach sc $subs { lappend row [dumpview $path!$i.[lindex $sc 0]] }
        lappend out $row ; incr i
    }
    return [list $name $layout $out]
}
# the complete logical content of a database
proc dumpdb {path {how raw} {record ""}} {
    if {$how ne "raw"} {
        # a scratch copy: opening for writing repairs it
        set scratch $path.work
        foreach x [glob -nocomplain $scratch*] { file delete $x }
        file copy -force $path $scratch
        if {$how eq "record"} { set h [open $scratch.commit w] ; puts -nonewline $h $record ; close $h }
        if {$how eq "own" && [file exists $path.commit]} { file copy -force $path.commit $scratch.commit }
        set t [store::openFile $scratch]
    } else {
        set t [store::openFile $path -readonly]
    }
    set out {}
    foreach v [lsort [store::views $t]] { lappend out [dumpview $t.$v] }
    store::closeFile $t
    if {$how ne "raw"} { foreach x [glob -nocomplain $scratch*] { file delete $x } }
    return $out
}
set dumpA [dumpdb $fileA] ; set dumpB [dumpdb $fileB]
# what a commit from A would have recorded before it began
set record ""
if {$mode eq "record"} { set info [store::headerInfo $fileA] ; set record "[dict get $info header] [dict get $info size]" }
set h [open $listfile r] ; set files [split [string trim [read $h]] \n] ; close $h
set n 0
foreach f $files {
    incr n
    say "START $n"
    if {[catch {dumpdb $f $mode $record} d]} {
        say "$n DETECTED [string map {\n { }} [string range $d 0 120]]"
    } elseif {$d eq $dumpA} { say "$n OLD" } elseif {$d eq $dumpB} { say "$n NEW" } else {
        # say roughly what is wrong
        set why "differs from both"
        if {[llength $d] != [llength $dumpA]} { set why "view count [llength $d]" } else {
            foreach x $d y $dumpA z $dumpB {
                if {[lindex $x 1] ne [lindex $y 1] && [lindex $x 1] ne [lindex $z 1]} { set why "layout of [lindex $x 0]" ; break }
                if {[llength [lindex $x 2]] ne [llength [lindex $y 2]] && [llength [lindex $x 2]] ne [llength [lindex $z 2]]} { set why "row count of [lindex $x 0]: [llength [lindex $x 2]]" ; break }
                if {[lindex $x 2] ne [lindex $y 2] && [lindex $x 2] ne [lindex $z 2]} { set why "row values of [lindex $x 0]" ; break }
            }
        }
        say "$n SILENT $why"
    }
}
say "DONE"
exit 0
