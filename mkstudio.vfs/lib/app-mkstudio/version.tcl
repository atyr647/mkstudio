# version.tcl -- the version number, in ONE place, and how versions compare (semantic versioning).
#
# A release is built from the git tag vX.Y.Z[-pre]; CI refuses to publish when the tag and this file disagree.
namespace eval ::version {
    variable current 1.0.0-rc.3
    variable repo    atyr647/mkstudio
}

# "v1.2.3-rc.1+build" -> {1 2 3 {rc 1}}   (the pre-release part is a list of identifiers, empty for a release)
proc ::version::parse {v} {
    set v [string trim $v]
    regsub {^[vV]} $v {} v
    regsub {\+.*$} $v {} v
    set pre {}
    set i [string first - $v]
    if {$i >= 0} { set pre [split [string range $v [expr {$i + 1}] end] .] ; set v [string range $v 0 [expr {$i - 1}]] }
    set nums [split $v .]
    if {[llength $nums] < 1 || [llength $nums] > 3} { error "not a version number: $v" }
    while {[llength $nums] < 3} { lappend nums 0 }
    foreach n $nums { if {![regexp {^[0-9]+$} $n]} { error "not a version number: $v" } }
    return [list {*}[lmap_int $nums] $pre]
}
proc ::version::lmap_int {l} { set o {} ; foreach x $l { lappend o [scan $x %d] } ; return $o }

# -1, 0, 1.  A pre-release is older than its release; pre-release identifiers compare one by one (numbers as numbers,
# numbers before words), a shorter list that is a prefix is older.
proc ::version::compare {a b} {
    lassign [parse $a] a1 a2 a3 ap
    lassign [parse $b] b1 b2 b3 bp
    foreach {x y} [list $a1 $b1 $a2 $b2 $a3 $b3] {
        if {$x < $y} { return -1 } elseif {$x > $y} { return 1 }
    }
    if {![llength $ap] && ![llength $bp]} { return 0 }
    if {![llength $ap]} { return 1 }
    if {![llength $bp]} { return -1 }
    set n [expr {min([llength $ap], [llength $bp])}]
    for {set i 0} {$i < $n} {incr i} {
        set x [lindex $ap $i] ; set y [lindex $bp $i]
        set xn [string is integer -strict $x] ; set yn [string is integer -strict $y]
        if {$xn && $yn} {
            if {$x < $y} { return -1 } elseif {$x > $y} { return 1 }
        } elseif {$xn} { return -1 } elseif {$yn} { return 1 } else {
            set c [string compare $x $y] ; if {$c != 0} { return $c }
        }
    }
    return [expr {[llength $ap] < [llength $bp] ? -1 : ([llength $ap] > [llength $bp] ? 1 : 0)}]
}
proc ::version::isPrerelease {v} { expr {[llength [lindex [parse $v] 3]] > 0} }
