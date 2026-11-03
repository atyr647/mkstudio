# mock_mk4tcl.tcl -- TEST-ONLY pure-Tcl stand-in for the subset of Mk4tcl that
# MK Studio uses.  It follows the documented mk:: semantics (paths, cursors,
# layouts, -nocommit, "a single property comes back unwrapped") but stores data
# in a Tcl dict dump rather than a real Metakit file.  It is NOT shipped in the
# starpack; the real app talks to the real Mk4tcl built into tclkit.

namespace eval ::mkmock {
    variable vo   ;# id -> {layout L rows {rowdicts}}   (a "view object")
    variable db   ;# tag -> {path P views {name id ...}}
    variable next 0
    array set vo {} ; array set db {}
}

proc ::mkmock::_newvo {layout} {
    variable vo ; variable next
    set id v[incr next]
    set vo($id) [dict create layout $layout rows {}]
    return $id
}
proc ::mkmock::_defaults {layout} {
    set row {}
    foreach c $layout {
        lassign $c n t sub
        switch -- $t {
            V { dict set row $n [_newvo $sub] }
            I - L { dict set row $n 0 }
            F - D { dict set row $n 0.0 }
            default { dict set row $n "" }
        }
    }
    return $row
}
# resolve a path to a view-object id  ("tag.view!3.sub!1.subsub")
proc ::mkmock::_resolve {path} {
    variable vo ; variable db
    set parts [split $path .]
    set tag [lindex $parts 0]
    if {![info exists db($tag)]} { error "no such datafile: $tag" }
    lassign [split [lindex $parts 1] !] vname idx
    set views [dict get $db($tag) views]
    if {![dict exists $views $vname]} { error "no such view: $path" }
    set id [dict get $views $vname]
    set rest [lrange $parts 2 end]
    while {$idx ne ""} {
        set rows [dict get $vo($id) rows]
        if {$idx < 0 || $idx >= [llength $rows]} { error "row index $idx out of range" }
        if {[llength $rest] == 0} { return [list $id $idx] }
        lassign [split [lindex $rest 0] !] sname idx2
        set rest [lrange $rest 1 end]
        set id [dict get [lindex $rows $idx] $sname]
        set idx $idx2
    }
    return [list $id ""]
}
proc ::mkmock::_type {layout name} {
    foreach c $layout { if {[lindex $c 0] eq $name} { return [lindex $c 1] } }
    return ""
}

proc ::mkmock::cmd_file {cmd tag args} {
    variable db ; variable vo
    switch -- $cmd {
        open {
            set path [expr {[llength $args] && [string index [lindex $args 0] 0] ne "-" ? [lindex $args 0] : ""}]
            set db($tag) [dict create path $path views {} ro [expr {"-readonly" in $args}]]
            if {$path ne "" && [::file exists $path] && [::file size $path] > 0} {
                set f [::open $path r] ; fconfigure $f -translation lf -encoding utf-8 ; set data [read $f] ; close $f
                if {[string range $data 0 6] ne "MKMOCK1"} { unset db($tag) ; error "file format error" }
                _load $tag [string range $data 8 end]
            } elseif {$path ne ""} {
                set f [::open $path a] ; close $f
            }
            return $tag
        }
        close { unset -nocomplain db($tag) ; return }
        views { return [dict keys [dict get $db($tag) views]] }
        commit {
            set path [dict get $db($tag) path]
            if {[dict get $db($tag) ro]} { error "file is read-only" }
            set f [::open $path w] ; fconfigure $f -translation lf -encoding utf-8 ; puts -nonewline $f "MKMOCK1\n[_dump $tag]" ; close $f
            return
        }
        rollback {
            set path [dict get $db($tag) path] ; set ro [dict get $db($tag) ro]
            set db($tag) [dict create path $path views {} ro $ro]
            if {[::file size $path] > 0} {
                set f [::open $path r] ; fconfigure $f -translation lf -encoding utf-8 ; set data [read $f] ; close $f
                _load $tag [string range $data 8 end]
            }
            return
        }
    }
    error "unknown mk::file command $cmd"
}
proc ::mkmock::_dumpvo {id} {
    variable vo
    set rows {}
    foreach r [dict get $vo($id) rows] {
        set rd {}
        foreach {k v} $r { dict set rd $k [expr {[_type [dict get $vo($id) layout] $k] eq "V" ? [list sub [_dumpvo $v]] : [list val $v]}] }
        lappend rows $rd
    }
    return [list [dict get $vo($id) layout] $rows]
}
proc ::mkmock::_dump {tag} {
    variable vo
    variable db
    set out {}
    dict for {n id} [dict get $db($tag) views] {
        if {[dict get $vo($id) layout] ne ""} { dict set out $n [_dumpvo $id] }
    }
    return $out
}
proc ::mkmock::_loadvo {d} {
    lassign $d layout rows
    set id [_newvo $layout]
    variable vo
    foreach rd $rows {
        set r {}
        dict for {k tv} $rd {
            lassign $tv kind v
            # (if, not expr's ?: -- that would turn the text 07 into the number 7)
            if {$kind eq "sub"} { dict set r $k [_loadvo $v] } else { dict set r $k $v }
        }
        dict lappend vo($id) rows $r
    }
    return $id
}
proc ::mkmock::_load {tag data} {
    variable db
    dict for {n d} $data { dict set db($tag) views $n [_loadvo $d] }
}

proc ::mkmock::cmd_view {cmd path args} {
    variable vo ; variable db
    switch -- $cmd {
        layout {
            if {[llength $args] == 0} {
                # real Mk4tcl returns the TOP-LEVEL layout even for a subview path
                lassign [_resolve [lindex [split $path !] 0]] id idx
                return [::store::formatLayout [dict get $vo($id) layout]]
            }
            set new [::store::parseLayout [lindex $args 0]]
            if {![string match *!* $path] && [llength [split $path .]] == 2} {
                lassign [split $path .] tag vname
                if {![dict exists $db($tag) views $vname]} {
                    dict set db($tag) views $vname [_newvo $new]
                    return
                }
            }
            lassign [_resolve $path] id idx
            _restructure $id $new
            return
        }
        size {
            lassign [_resolve $path] id idx
            if {$idx ne ""} { error "size needs a view path" }
            if {[llength $args]} {
                # like real Mk4tcl: `mk::view size path N` truncates, or grows with blank rows
                set want [lindex $args 0]
                set rows [dict get $vo($id) rows]
                if {$want < [llength $rows]} { set rows [lrange $rows 0 [expr {$want - 1}]] }
                while {[llength $rows] < $want} { lappend rows [_defaults [dict get $vo($id) layout]] }
                dict set vo($id) rows $rows
            }
            return [llength [dict get $vo($id) rows]]
        }
        delete {
            lassign [split $path .] tag vname
            # like real Metakit: the view stays listed, emptied, until the next commit
            set id [dict get $db($tag) views $vname]
            dict set vo($id) layout {} ; dict set vo($id) rows {}
            return
        }
    }
    error "unknown mk::view command $cmd"
}
proc ::mkmock::_restructure {id new} {
    variable vo
    set old [dict get $vo($id) layout]
    set rows {}
    foreach r [dict get $vo($id) rows] {
        set nr [_defaults $new]
        foreach c $new {
            lassign $c n t sub
            if {[_type $old $n] eq $t && [dict exists $r $n]} {
                if {$t eq "V"} { _restructure [dict get $r $n] $sub }
                dict set nr $n [dict get $r $n]
            }
        }
        lappend rows $nr
    }
    dict set vo($id) layout $new
    dict set vo($id) rows $rows
}

proc ::mkmock::cmd_row {cmd path args} {
    variable vo
    switch -- $cmd {
        append {
            lassign [_resolve $path] id idx
            set layout [dict get $vo($id) layout]
            set r [_defaults $layout]
            foreach {k v} $args {
                set t [_type $layout $k]
                if {$t eq ""} { error "unknown property: $k" }
                if {$t eq "V"} { error "cannot set subview property directly" }
                if {(($t eq "I" && ![string is integer -strict $v]) || ($t eq "L" && ![string is wideinteger -strict $v]))} { error "expected integer but got \"$v\"" }
                if {($t eq "F" || $t eq "D") && ![string is double -strict $v]} { error "expected floating-point number but got \"$v\"" }
                dict set r $k $v
            }
            dict lappend vo($id) rows $r
            return $path![expr {[llength [dict get $vo($id) rows]] - 1}]
        }
        insert {
            # like real Mk4tcl: `mk::row insert cursor ?count?` inserts blank rows
            lassign [_resolve $path] id idx
            set count [expr {[llength $args] ? [lindex $args 0] : 1}]
            set rows [dict get $vo($id) rows]
            if {$idx > [llength $rows] - 0 || $idx >= [llength $rows]} { error "view index is too large" }
            for {set i 0} {$i < $count} {incr i} {
                set rows [linsert $rows $idx [_defaults [dict get $vo($id) layout]]]
            }
            dict set vo($id) rows $rows
            return $path
        }
        delete {
            lassign [_resolve $path] id idx
            set count [expr {[llength $args] ? [lindex $args 0] : 1}]
            dict set vo($id) rows [lreplace [dict get $vo($id) rows] $idx [expr {$idx + $count - 1}]]
            return
        }
    }
    error "unknown mk::row command $cmd"
}

proc ::mkmock::cmd_get {cursor args} {
    variable vo
    lassign [_resolve $cursor] id idx
    set row [lindex [dict get $vo($id) rows] $idx]
    set layout [dict get $vo($id) layout]
    if {[llength $args] == 0} {
        set out {}
        foreach c $layout { if {[lindex $c 1] ne "V"} { lappend out [lindex $c 0] [dict get $row [lindex $c 0]] } }
        return $out
    }
    set out {}
    foreach p $args {
        set t [_type $layout $p]
        if {$t eq ""} { error "no such property: $p" }
        if {$t eq "V"} { error "cannot get a subview property" }
        lappend out [dict get $row $p]
    }
    if {[llength $args] == 1} { return [lindex $out 0] }
    return $out
}
proc ::mkmock::cmd_set {cursor args} {
    variable vo
    lassign [_resolve $cursor] id idx
    set layout [dict get $vo($id) layout]
    set rows [dict get $vo($id) rows]
    set r [lindex $rows $idx]
    foreach {k v} $args {
        set t [_type $layout $k]
        if {$t eq ""} { error "no such property: $k" }
        if {(($t eq "I" && ![string is integer -strict $v]) || ($t eq "L" && ![string is wideinteger -strict $v]))} { error "expected integer but got \"$v\"" }
        if {($t eq "F" || $t eq "D") && ![string is double -strict $v]} { error "expected floating-point number but got \"$v\"" }
        dict set r $k $v
    }
    lset rows $idx $r
    dict set vo($id) rows $rows
    return
}
# mk::select <view> ?-exact p v? ?-min p v? ?-max p v? ?-sort p? ?-rsort p? ...
# Like real Mk4tcl: the criteria are ANDed, -min/-max are inclusive and typed by the property,
# bad numbers are errors, and -sort/-rsort are NOT stable (ties come out in a deliberately
# scrambled order here, so code that relies on stability gets caught).
proc ::mkmock::cmd_select {path args} {
    variable vo
    lassign [_resolve $path] id idx
    set layout [dict get $vo($id) layout]
    set rows [dict get $vo($id) rows]
    set crit {} ; set sorts {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        switch -- $a {
            -exact - -min - -max {
                set p [lindex $args [incr i]] ; set v [lindex $args [incr i]]
                set t [_type $layout $p]
                if {$t eq ""} { error "no such property: $p" }
                if {(($t eq "I" && ![string is integer -strict $v]) || ($t eq "L" && ![string is wideinteger -strict $v]))} { error "expected integer but got \"$v\"" }
                if {($t eq "F" || $t eq "D") && ![string is double -strict $v]} { error "expected floating-point number but got \"$v\"" }
                lappend crit [list $a $p $v $t]
            }
            -sort - -rsort { lappend sorts [list $a [lindex $args [incr i]]] }
            default { error "unsupported mk::select option $a" }
        }
    }
    set out {}
    set n 0
    foreach r $rows {
        set ok 1
        foreach c $crit {
            lassign $c op p v t
            set x [dict get $r $p]
            switch -- $op {
                -exact { set ok [expr {$t in {I L F D} ? $x == $v : $x eq $v}] }
                -min   { set ok [expr {$t in {I L F D} ? $x >= $v : [string compare $x $v] >= 0}] }
                -max   { set ok [expr {$t in {I L F D} ? $x <= $v : [string compare $x $v] <= 0}] }
            }
            if {!$ok} break
        }
        if {$ok} { lappend out $n }
        incr n
    }
    if {[llength $sorts]} {
        set out [lreverse $out]          ;# scramble ties
        foreach s [lreverse $sorts] {
            lassign $s dir p
            set t [_type $layout $p]
            set keys {}
            foreach i $out { lappend keys [dict get [lindex $rows $i] $p] }
            set mode [expr {$t in {I L} ? "-integer" : $t in {F D} ? "-real" : "-ascii"}]
            set order [expr {$dir eq "-rsort" ? "-decreasing" : "-increasing"}]
            set o2 {}
            foreach j [lsort $mode $order -indices $keys] { lappend o2 [lindex $out $j] }
            set out $o2
        }
    }
    return $out
}
# public mk:: commands are thin wrappers so the implementation can freely use
# Tcl's own set/file/etc. inside its namespace
namespace eval ::mk {}
foreach c {file view row get set select} {
    proc ::mk::$c {args} "::mkmock::cmd_$c {*}\$args"
}
package provide Mk4tcl 2.4.9.7
