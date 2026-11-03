# menus.tcl -- themed popup menus and the menubar.
#
# Menus are still *described* with ordinary Tk menu widgets (add command,
# add separator, add cascade, add checkbutton, add radiobutton, entryconfigure,
# -postcommand), but they are never shown by Tk: ::menus::post renders them as
# themed popups, so every menu in the app looks and behaves the same on every
# platform.
#
#   ::menus::post m X Y               context menu at screen coordinates
#   ::menus::barItem bar key label m  a menubar title that opens menu m
#
# Keyboard: Up/Down, Right/Left (submenus and neighbouring menubar menus),
# Return/Space to activate, Escape to close, letters jump to items.

namespace eval ::menus {
    variable stack {}        ;# open popups, root first
    variable P               ;# per-popup state: P($top,menu) P($top,active) P($top,items)
    array set P {}
    variable seq 0
    variable subAfter ""
    variable bar {}          ;# ordered list of menubar title widgets
    variable barMenu         ;# title widget -> menu
    array set barMenu {}
    variable barOpen ""      ;# title widget whose menu is open
    variable prevFocus ""
}

# ---- menubar -----------------------------------------------------------------
proc ::menus::barItem {parent key label m} {
    variable bar ; variable barMenu
    set w $parent.$key
    label $w -text $label -font MkUI -padx 10 -pady 5 -borderwidth 0
    set barMenu($w) $m
    lappend bar $w
    ::theme::reg $w {::menus::paintBar}
    bind $w <ButtonPress-1> [list ::menus::openBar $w]
    bind $w <Enter> [list ::menus::paintBar $w]
    bind $w <Leave> [list ::menus::paintBar]
    return $w
}
proc ::menus::paintBar {{hover ""}} {
    variable bar ; variable barOpen
    foreach w $bar {
        if {![winfo exists $w]} continue
        set bg [expr {$w eq $barOpen || $w eq $hover ? $::theme::c(hover) : $::theme::c(bg)}]
        $w configure -background $bg -foreground $::theme::c(fg)
    }
}
proc ::menus::openBar {w {selectFirst 0}} {
    variable barMenu ; variable barOpen
    if {$barOpen eq $w} { closeAll ; return }
    closeAll
    set barOpen $w
    paintBar
    post $barMenu($w) [winfo rootx $w] [expr {[winfo rooty $w] + [winfo height $w]}] 1
    if {$selectFirst} { key Down }
}
proc ::menus::barStep {dir} {
    variable bar ; variable barOpen
    set i [lsearch -exact $bar $barOpen]
    if {$i < 0} return
    openBar [lindex $bar [expr {($i + $dir) % [llength $bar]}]] 1
}

# ---- building a popup ----------------------------------------------------------
proc ::menus::entryLabel {m i} {
    set l [$m entrycget $i -label]
    return $l
}

proc ::menus::build {m parent} {
    variable P ; variable seq
    set pc [$m cget -postcommand]
    if {$pc ne ""} { uplevel #0 $pc }
    set top [expr {$parent eq "" ? ".mpop[incr seq]" : "$parent.sub[incr seq]"}]
    toplevel $top -background $::theme::c(border) -borderwidth 0 -highlightthickness 0
    wm withdraw $top
    wm overrideredirect $top 1
    catch {wm attributes $top -topmost 1}
    frame $top.f -background $::theme::c(raised) -borderwidth 0 -highlightthickness 0
    pack $top.f -padx 1 -pady 1

    set last [$m index end]
    if {$last eq "none"} { set last -1 }
    # measure
    set lw 0 ; set aw 0
    for {set i 0} {$i <= $last} {incr i} {
        if {[$m type $i] in {separator tearoff}} continue
        set lw [expr {max($lw, [font measure MkUI [entryLabel $m $i]])}]
        catch {set aw [expr {max($aw, [font measure MkUI [$m entrycget $i -accelerator]])}]}
    }
    set rowh [expr {[font metrics MkUI -linespace] + 12}]
    set width [expr {max(220, 28 + $lw + ($aw ? $aw + 40 : 0) + 34)}]

    set items {}
    frame $top.f.pad0 -height 4 -background $::theme::c(raised)
    pack $top.f.pad0 -fill x
    for {set i 0} {$i <= $last} {incr i} {
        set type [$m type $i]
        if {$type eq "tearoff"} continue
        if {$type eq "separator"} {
            frame $top.f.s$i -height 9 -width $width -background $::theme::c(raised)
            frame $top.f.s$i.l -height 1 -background $::theme::c(border)
            place $top.f.s$i.l -x 10 -relwidth 1 -width -20 -rely 0.5
            pack $top.f.s$i -fill x
            continue
        }
        set r $top.f.r$i
        frame $r -height $rowh -width $width -borderwidth 0 -highlightthickness 0
        pack propagate $r 0
        label $r.m -width 2 -font MkUI -borderwidth 0 -anchor center
        label $r.l -text [entryLabel $m $i] -font MkUI -borderwidth 0 -anchor w
        label $r.c -text [expr {$type eq "cascade" ? "›" : ""}] -font MkUI -borderwidth 0 -width 2
        set acc "" ; catch {set acc [$m entrycget $i -accelerator]}
        label $r.a -text $acc -font MkUI -borderwidth 0 -anchor e
        pack $r.m -side left -padx {6 2}
        pack $r.l -side left
        pack $r.c -side right -padx {0 6}
        pack $r.a -side right -padx {24 0}
        # check / radio marks
        if {$type eq "checkbutton"} {
            set var [$m entrycget $i -variable] ; set on [$m entrycget $i -onvalue]
            if {[info exists ::$var] && [set ::$var] eq $on} { $r.m configure -text "✓" }
        } elseif {$type eq "radiobutton"} {
            set var [$m entrycget $i -variable] ; set val [$m entrycget $i -value]
            if {[info exists ::$var] && [set ::$var] eq $val} { $r.m configure -text "•" }
        }
        pack $r -fill x
        lappend items $i
    }
    frame $top.f.pad1 -height 4 -background $::theme::c(raised)
    pack $top.f.pad1 -fill x

    set P($top,menu) $m ; set P($top,active) -1 ; set P($top,items) $items
    set P($top,parent) $parent
    foreach ev {<Motion> <ButtonPress> <ButtonRelease>} proc {motion press release} {
        bind $top $ev [list ::menus::$proc %X %Y]
    }
    bind $top <Key> [list ::menus::key %K %A]
    paint $top
    return $top
}

proc ::menus::enabled {top i} {
    variable P
    set m $P($top,menu)
    expr {[$m entrycget $i -state] ne "disabled"}
}

proc ::menus::paint {top} {
    variable P
    if {![winfo exists $top]} return
    foreach i $P($top,items) {
        set r $top.f.r$i
        set on [expr {$i == $P($top,active) && [enabled $top $i]}]
        set bg [expr {$on ? $::theme::c(sel) : $::theme::c(raised)}]
        set fg [expr {![enabled $top $i] ? $::theme::c(faint) : ($on ? $::theme::c(selFg) : $::theme::c(fg))}]
        set dim [expr {![enabled $top $i] ? $::theme::c(faint) : ($on ? $::theme::c(selFg) : $::theme::c(dim))}]
        foreach p [list $r $r.m $r.l $r.c $r.a] { $p configure -background $bg }
        foreach p [list $r.m $r.l $r.c] { $p configure -foreground $fg }
        $r.a configure -foreground $dim
    }
}

proc ::menus::position {top X Y {alignRight ""}} {
    update idletasks
    set w [winfo reqwidth $top] ; set h [winfo reqheight $top]
    set sw [winfo screenwidth $top] ; set sh [winfo screenheight $top]
    if {$X + $w > $sw} { set X [expr {$alignRight ne "" ? $alignRight - $w : $sw - $w - 2}] }
    if {$Y + $h > $sh} { set Y [expr {max(0, $sh - $h - 2)}] }
    wm geometry $top +[expr {max(0,$X)}]+$Y
    wm deiconify $top
    raise $top
}

# ---- posting / closing -----------------------------------------------------------
proc ::menus::post {m X Y {fromBar 0}} {
    variable stack ; variable prevFocus ; variable barOpen
    if {!$fromBar} { closeAll }
    if {$prevFocus eq ""} { set prevFocus [focus] }
    ::tip::hide
    set top [build $m ""]
    position $top $X $Y
    set stack [list $top]
    update idletasks
    if {[catch {grab -global $top}]} { catch {grab $top} }
    focus -force $top
}

proc ::menus::closeAll {} {
    variable stack ; variable barOpen ; variable prevFocus ; variable subAfter ; variable P
    if {$subAfter ne ""} { after cancel $subAfter ; set subAfter "" }
    if {[llength $stack]} {
        set root [lindex $stack 0]
        catch {grab release $root}
        foreach k [array names P $root*] { unset P($k) }
        catch {destroy $root}
    }
    set stack {}
    set barOpen ""
    paintBar
    if {$prevFocus ne "" && [winfo exists $prevFocus]} { catch {focus $prevFocus} }
    set prevFocus ""
}

# close popups deeper than $top
proc ::menus::closeAfter {top} {
    variable stack ; variable P
    set i [lsearch -exact $stack $top]
    if {$i < 0} return
    foreach t [lrange $stack [expr {$i + 1}] end] {
        foreach k [array names P $t,*] { unset P($k) }
        catch {destroy $t}
    }
    set stack [lrange $stack 0 $i]
}

proc ::menus::current {} { variable stack ; return [lindex $stack end] }

# find {top index} for a widget inside a menu row
proc ::menus::rowAt {w} {
    variable P
    while {$w ne "" && $w ne "."} {
        if {[regexp {^(.*)\.f\.r(\d+)$} $w -> top i] && [info exists P($top,menu)]} { return [list $top $i] }
        set w [winfo parent $w]
    }
    return ""
}
proc ::menus::inPopup {w} {
    variable stack
    foreach t $stack { if {$w eq $t || [string match $t.* $w]} { return 1 } }
    return 0
}

# ---- interaction -------------------------------------------------------------------
proc ::menus::activate {top i} {
    variable P ; variable subAfter ; variable stack
    if {$P($top,active) == $i} return
    set P($top,active) $i
    paint $top
    # leaving a cascade closes its submenu
    closeAfter $top
    if {$subAfter ne ""} { after cancel $subAfter ; set subAfter "" }
    if {$i >= 0 && [$P($top,menu) type $i] eq "cascade" && [enabled $top $i]} {
        set subAfter [after 180 [list ::menus::openSub $top $i 0]]
    }
}

proc ::menus::openSub {top i focusFirst} {
    variable P ; variable stack ; variable subAfter
    set subAfter ""
    if {![winfo exists $top]} return
    closeAfter $top
    set sm [$P($top,menu) entrycget $i -menu]
    if {$sm eq "" || ![winfo exists $sm]} return
    set sub [build $sm $top]
    set r $top.f.r$i
    position $sub [expr {[winfo rootx $r] + [winfo width $r] - 2}] [expr {[winfo rooty $r] - 5}] [winfo rootx $top]
    lappend stack $sub
    if {$focusFirst} { move $sub 1 }
}

proc ::menus::motion {X Y} {
    variable barOpen ; variable bar
    set w [winfo containing $X $Y]
    if {$barOpen ne "" && [lsearch -exact $bar $w] >= 0 && $w ne $barOpen} { openBar $w ; return }
    set hit [rowAt $w]
    if {$hit eq ""} return
    activate {*}$hit
}
proc ::menus::press {X Y} {
    variable bar ; variable barOpen
    set w [winfo containing $X $Y]
    if {$w ne "" && [inPopup $w]} return
    if {[lsearch -exact $bar $w] >= 0} {
        if {$w eq $barOpen} { closeAll } else { openBar $w }
        return
    }
    closeAll
}
proc ::menus::release {X Y} {
    set w [winfo containing $X $Y]
    set hit [rowAt $w]
    if {$hit eq ""} return
    invoke {*}$hit
}

proc ::menus::invoke {top i} {
    variable P
    if {![info exists P($top,menu)] || ![enabled $top $i]} return
    set m $P($top,menu)
    set type [$m type $i]
    if {$type eq "cascade"} { openSub $top $i 1 ; return }
    set cmd [$m entrycget $i -command]
    set pre ""
    switch -- $type {
        checkbutton {
            set var [$m entrycget $i -variable]
            set on [$m entrycget $i -onvalue] ; set off [$m entrycget $i -offvalue]
            set pre [list set ::$var [expr {[info exists ::$var] && [set ::$var] eq $on ? $off : $on}]]
        }
        radiobutton {
            set pre [list set ::[$m entrycget $i -variable] [$m entrycget $i -value]]
        }
    }
    closeAll
    # run after the popup is gone so dialogs opened by the command get the grab
    after idle [list ::menus::run $pre $cmd]
}
proc ::menus::run {pre cmd} {
    if {$pre ne ""} { uplevel #0 $pre }
    if {$cmd ne ""} { uplevel #0 $cmd }
}

# move the active row by dir among enabled entries
proc ::menus::move {top dir} {
    variable P
    set items {}
    foreach i $P($top,items) { if {[enabled $top $i]} { lappend items $i } }
    if {![llength $items]} return
    set k [lsearch -exact $items $P($top,active)]
    if {$k < 0} { set k [expr {$dir > 0 ? 0 : [llength $items] - 1}] } else {
        set k [expr {($k + $dir) % [llength $items]}]
    }
    activate $top [lindex $items $k]
}

proc ::menus::key {k ch} {
    variable P ; variable stack ; variable barOpen
    set top [current]
    if {$top eq ""} return
    switch -- $k {
        Down  { move $top 1 }
        Up    { move $top -1 }
        Right {
            set i $P($top,active)
            if {$i >= 0 && [$P($top,menu) type $i] eq "cascade"} { openSub $top $i 1 } elseif {$barOpen ne ""} { barStep 1 }
        }
        Left {
            if {[llength $stack] > 1} {
                set parent $P($top,parent)
                closeAfter $parent
            } elseif {$barOpen ne ""} { barStep -1 }
        }
        Return - KP_Enter - space {
            if {$P($top,active) >= 0} { invoke $top $P($top,active) }
        }
        Escape {
            if {[llength $stack] > 1} { closeAfter $P($top,parent) } else { closeAll }
        }
        default {
            if {$ch eq "" || ![string is print $ch]} return
            # jump to the next item starting with that letter
            set items $P($top,items)
            set start [expr {[lsearch -exact $items $P($top,active)] + 1}]
            set n [llength $items]
            for {set j 0} {$j < $n} {incr j} {
                set i [lindex $items [expr {($start + $j) % $n}]]
                if {[enabled $top $i] && [string equal -nocase [string index [entryLabel $P($top,menu) $i] 0] $ch]} {
                    activate $top $i ; break
                }
            }
        }
    }
}
