# icons.tcl -- all icons are drawn procedurally into Tk photo images, so the
# starpack needs no binary assets.  Colours are mid-tones that read well on
# both the dark and the light theme.
#
#   ::icons::get name   ->  image name ("ic_<name>") ready to use as -image

namespace eval ::icons {
    variable buf
    variable made {}
    variable col
    array set col {
        blue #5b9dff  dblue #3a6fc4  lblue #a9c9ff  teal #35c2b0  green #3fb97a  dgreen #2c8f5d
        amber #f0b240 damber #b9811f  lamber #f7d283  red #ee5f5f  orange #f0883e
        purple #b07cff  dpurple #7d4fd6  white #e8ecf4  gray #8892a6  dgray #5b6475
        pale #dfe6f2  ink #2a3140
    }
}

# ---- tiny rasteriser ---------------------------------------------------------
proc ::icons::px {x y c} {
    variable buf ; variable col
    if {$x < 0 || $y < 0 || $x > 15 || $y > 15} return
    set buf($x,$y) [expr {[info exists col($c)] ? $col($c) : $c}]
}
proc ::icons::rect {x1 y1 x2 y2 c} {
    for {set y $y1} {$y <= $y2} {incr y} { for {set x $x1} {$x <= $x2} {incr x} { px $x $y $c } }
}
proc ::icons::frame {x1 y1 x2 y2 c} {
    for {set x $x1} {$x <= $x2} {incr x} { px $x $y1 $c ; px $x $y2 $c }
    for {set y $y1} {$y <= $y2} {incr y} { px $x1 $y $c ; px $x2 $y $c }
}
proc ::icons::ell {cx cy rx ry c} {
    for {set y [expr {int($cy - $ry - 1)}]} {$y <= $cy + $ry + 1} {incr y} {
        for {set x [expr {int($cx - $rx - 1)}]} {$x <= $cx + $rx + 1} {incr x} {
            set dx [expr {($x - $cx) / double($rx)}] ; set dy [expr {($y - $cy) / double($ry)}]
            if {$dx*$dx + $dy*$dy <= 1.0} { px $x $y $c }
        }
    }
}
proc ::icons::line {x0 y0 x1 y1 c} {
    set dx [expr {abs($x1 - $x0)}] ; set dy [expr {-abs($y1 - $y0)}]
    set sx [expr {$x0 < $x1 ? 1 : -1}] ; set sy [expr {$y0 < $y1 ? 1 : -1}]
    set err [expr {$dx + $dy}]
    while {1} {
        px $x0 $y0 $c
        if {$x0 == $x1 && $y0 == $y1} break
        set e2 [expr {2 * $err}]
        if {$e2 >= $dy} { incr err $dy ; incr x0 $sx }
        if {$e2 <= $dx} { incr err $dx ; incr y0 $sy }
    }
}
proc ::icons::thick {x0 y0 x1 y1 c} {
    line $x0 $y0 $x1 $y1 $c ; line [expr {$x0+1}] $y0 [expr {$x1+1}] $y1 $c
}
proc ::icons::tri {x1 y1 x2 y2 x3 y3 c} {
    set minx [expr {min($x1,$x2,$x3)}] ; set maxx [expr {max($x1,$x2,$x3)}]
    set miny [expr {min($y1,$y2,$y3)}] ; set maxy [expr {max($y1,$y2,$y3)}]
    set d [expr {double(($y2-$y3)*($x1-$x3) + ($x3-$x2)*($y1-$y3))}]
    for {set y $miny} {$y <= $maxy} {incr y} {
        for {set x $minx} {$x <= $maxx} {incr x} {
            set a [expr {(($y2-$y3)*($x-$x3) + ($x3-$x2)*($y-$y3)) / $d}]
            set b [expr {(($y3-$y1)*($x-$x3) + ($x1-$x3)*($y-$y3)) / $d}]
            if {$a >= -0.01 && $b >= -0.01 && $a + $b <= 1.01} { px $x $y $c }
        }
    }
}
# ring segment; angles in degrees, 0 = up, clockwise
proc ::icons::arc {cx cy r t a0 a1 c} {
    set pi 3.14159265
    for {set y 0} {$y < 16} {incr y} {
        for {set x 0} {$x < 16} {incr x} {
            set dx [expr {$x + 0.0 - $cx}] ; set dy [expr {$y + 0.0 - $cy}]
            set d [expr {sqrt($dx*$dx + $dy*$dy)}]
            if {abs($d - $r) > $t / 2.0} continue
            set a [expr {atan2($dx, -$dy) * 180.0 / $pi}]
            if {$a < 0} { set a [expr {$a + 360}] }
            if {$a >= $a0 && $a <= $a1} { px $x $y $c }
        }
    }
}

# ---- icon definitions --------------------------------------------------------
proc ::icons::draw {name} {
    switch -- $name {
        db {
            ell 7.5 11 6 3 dblue ; rect 2 4 13 11 blue
            ell 7.5 4 6 3 lblue ; ell 7.5 4 4.4 1.7 blue
            line 3 8 3 8 dblue ; arc 7.5 3 6.5 1.4 100 260 dblue
        }
        dbnew { draw db ; rect 9 9 15 15 ink ; rect 11 10 13 14 green ; rect 10 11 14 13 green }
        server {
            rect 1 2 14 6 dgray ; rect 2 3 13 5 gray ; px 3 4 green ; px 5 4 amber
            rect 1 9 14 13 dgray ; rect 2 10 13 12 gray ; px 3 11 green ; px 5 11 amber
            rect 7 6 8 9 dgray
        }
        table {
            rect 1 2 14 13 gray ; rect 2 3 13 12 pale ; rect 2 3 13 5 teal
            line 2 8 13 8 gray ; line 2 11 13 11 gray ; line 6 5 6 12 gray ; line 10 5 10 12 gray
        }
        subview {
            rect 1 1 11 10 dpurple ; rect 2 2 10 9 pale ; rect 2 2 10 4 purple
            line 2 6 10 6 gray ; line 6 4 6 9 gray
            rect 6 7 14 14 dgray ; rect 7 8 13 13 pale ; rect 7 8 13 9 teal ; line 10 9 10 13 gray ; line 7 11 13 11 gray
        }
        folder {
            rect 1 3 6 5 damber ; rect 1 4 14 13 amber ; rect 1 4 14 5 lamber ; frame 1 4 14 13 damber
        }
        folderopen {
            rect 1 3 6 5 damber ; rect 1 4 12 6 damber ; rect 3 6 14 13 amber ; rect 1 7 12 13 lamber
            line 1 13 3 7 damber ; line 12 13 14 7 damber
        }
        play { tri 4 2 4 13 12 7 green ; tri 5 4 5 11 10 7 dgreen ; tri 4 2 4 13 12 7 green }
        stop { rect 3 3 12 12 red ; frame 3 3 12 12 orange }
        check { thick 2 8 5 12 green ; thick 5 12 12 3 green ; thick 6 12 13 3 green }
        commit { draw db ; rect 8 8 15 15 ink ; thick 9 12 11 14 green ; thick 11 14 14 9 green }
        rollback {
            arc 8 9 5 2.4 40 330 orange ; tri 1 6 8 6 4 1 orange
        }
        refresh {
            arc 8 8 5 2.2 20 300 blue ; tri 10 0 15 5 9 6 blue ; tri 9 1 14 3 11 6 blue
        }
        doc {
            rect 3 1 12 14 gray ; rect 4 2 11 13 pale ; tri 8 1 12 1 12 5 gray ; tri 8 1 8 5 12 5 white
            line 5 7 10 7 blue ; line 5 9 10 9 blue ; line 5 11 8 11 blue
        }
        docnew { draw doc ; rect 9 9 15 15 ink ; rect 11 10 13 14 green ; rect 10 11 14 13 green }
        open { draw folderopen }
        closex { line 3 3 12 12 gray ; line 12 3 3 12 gray ; line 4 3 12 11 gray ; line 11 3 3 11 gray }
        closexh { line 3 3 12 12 red ; line 12 3 3 12 red ; line 4 3 12 11 red ; line 11 3 3 11 red }
        save {
            rect 2 2 13 13 blue ; rect 4 2 11 6 pale ; rect 4 9 11 13 pale ; rect 9 3 10 5 blue
            line 5 10 10 10 gray ; line 5 12 10 12 gray
        }
        panel_l { frame 1 2 14 13 gray ; rect 2 3 5 12 blue ; line 6 3 6 12 gray }
        panel_r { frame 1 2 14 13 gray ; rect 10 3 13 12 blue ; line 9 3 9 12 gray }
        panel_b { frame 1 2 14 13 gray ; rect 2 9 13 12 blue ; line 2 8 13 8 gray }
        theme {
            for {set y 0} {$y < 16} {incr y} { for {set x 0} {$x < 16} {incr x} {
                set d [expr {hypot($x - 7.5, $y - 7.5)}]
                if {$d <= 6.5} { px $x $y [expr {$d > 5.4 ? "gray" : ($x < 8 ? "white" : "ink")}] }
            } }
        }
        plus { rect 7 3 8 12 green ; rect 3 7 12 8 green }
        minus { rect 3 7 12 8 red }
        key {
            ell 5 5 3.5 3.5 amber ; ell 5 5 1.5 1.5 ink ; line 7 7 13 13 amber ; line 8 7 14 13 amber
            line 11 11 13 9 amber ; px 13 12 amber
        }
        design {
            rect 1 2 14 13 gray ; rect 2 3 13 12 pale ; rect 2 3 13 5 blue
            line 2 8 13 8 gray ; line 6 5 6 12 gray
            thick 8 13 13 8 amber ; px 7 14 ink ; px 8 14 ink
        }
        edit {
            rect 1 2 14 13 gray ; rect 2 3 13 12 pale ; rect 2 3 13 5 teal ; line 2 8 13 8 gray ; line 6 5 6 12 gray
            rect 8 9 12 10 blue
        }
        trash {
            rect 3 4 12 5 gray ; rect 6 2 9 3 gray ; rect 4 6 11 14 gray ; rect 5 7 10 13 pale
            line 6 8 6 12 gray ; line 9 8 9 12 gray
        }
        help { ell 7.5 7.5 6.5 6.5 blue ; ell 7.5 7.5 5.5 5.5 dblue ; arc 7.5 6 2 2 0 220 white ; px 7 9 white ; px 7 11 white ; px 8 9 white ; px 8 11 white ; px 7 8 white ; px 8 8 white }
        csv { rect 2 1 13 14 gray ; rect 3 2 12 13 pale ; rect 3 3 12 4 green ; line 3 7 12 7 gray ; line 3 10 12 10 gray ; line 7 4 7 13 gray }
        col_S { colicon amber }
        col_I { colicon blue }
        col_L { colicon purple }
        col_F { colicon teal }
        col_D { colicon teal }
        col_B { colicon gray }
        col_V { draw subview }
    }
}
proc ::icons::colicon {tint} {
    rect 4 1 11 14 $tint
    rect 5 2 10 4 white
    rect 5 6 10 7 white ; rect 5 9 10 10 white ; rect 5 12 10 13 white
}

proc ::icons::get {name} {
    variable buf ; variable made
    set img ic_$name
    if {[lsearch -exact $made $name] >= 0} { return $img }
    array unset buf
    array set buf {}
    draw $name
    image create photo ${img}_1 -width 16 -height 16
    foreach k [array names buf] {
        lassign [split $k ,] x y
        if {$buf($k) eq ""} continue
        ${img}_1 put $buf($k) -to $x $y [expr {$x+1}] [expr {$y+1}]
    }
    set z [expr {int(round([tk scaling] / 1.3333))}]
    if {$z > 1} {
        image create photo $img
        $img copy ${img}_1 -zoom $z $z
        image delete ${img}_1
    } else {
        image create photo $img
        $img copy ${img}_1
        image delete ${img}_1
    }
    lappend made $name
    return $img
}

# The application logo, drawn large for the welcome page (3x the base icon).
proc ::icons::logo {} {
    set img [get db]
    image create photo ic_logo
    ic_logo copy $img -zoom 4 4
    return ic_logo
}
