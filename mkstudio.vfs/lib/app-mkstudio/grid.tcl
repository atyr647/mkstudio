# grid.tcl -- the result / data grid (a ttk::treeview dressed up as a grid).
#
#   ::grid::create w ?-editable 1? ?-commit cmd? ?-drill cmd? ?-changed cmd?
#   ::grid::load w result           result is the dict produced by ::mkql
#
#   -commit  {rowid column value}   called when a cell edit is accepted; raise an
#                                   error to reject it (the message is shown)
#   -drill   {rowid subviewName}    called when a subview cell is double-clicked
#   -changed {}                     called after the grid contents changed

namespace eval ::grid {
    variable G
    array set G {}
    variable maxDisplay 20000
}

proc ::grid::create {w args} {
    variable G
    array set o {-editable 0 -commit {} -drill {} -changed {}}
    array set o $args
    foreach k [array names o] { set G($w,$k) $o($k) }
    set G($w,cols) {} ; set G($w,types) {} ; set G($w,rows) {} ; set G($w,rowids) {}
    set G($w,drill) {} ; set G($w,sortcol) -1 ; set G($w,sortdir) asc ; set G($w,lastcol) 0
    set G($w,order) {} ; set G($w,total) 0 ; set G($w,source) ""

    ttk::frame $w -style Surface.TFrame
    # the row-number "#" is an ordinary right-aligned column (the tree column's anchor
    # is ignored by some Tk versions, which made it left-aligned under a right-aligned header)
    ttk::treeview $w.t -style Grid.Treeview -show headings -selectmode extended \
        -columns {rn} -yscrollcommand [list $w.v set] -xscrollcommand [list $w.h set]
    ttk::scrollbar $w.v -orient vertical -command [list $w.t yview]
    ttk::scrollbar $w.h -orient horizontal -command [list $w.t xview]
    grid $w.t -row 0 -column 0 -sticky nsew
    grid $w.v -row 0 -column 1 -sticky ns
    grid $w.h -row 1 -column 0 -sticky ew
    grid rowconfigure $w 0 -weight 1 ; grid columnconfigure $w 0 -weight 1

    $w.t column rn -width [::theme::px 54] -stretch 0 -anchor e
    $w.t heading rn -text "#" -anchor e
    ::ui::hoverTree $w.t
    ::theme::reg $w.t [list ::grid::recolor %w]
    ttk::label $w.t.empty -text "No rows" -style SurfaceDim.TLabel
    bind $w.t <Motion> [list +::grid::motion $w %x %y]

    bind $w.t <Double-1>  [list ::grid::doubleClick $w %x %y]
    bind $w.t <Button-1>  [list ::grid::noteColumn $w %x %y]
    bind $w.t <<TreeviewSelect>> [list ::grid::selChanged $w]
    ::ui::bindMod $w.t c "[list ::grid::copy $w 0] ; break"
    ::ui::bindMod $w.t C "[list ::grid::copy $w 1] ; break"
    ::ui::bindMod $w.t a "$w.t selection set \[$w.t children {}\] ; break"
    bind $w.t <F2>        [list ::grid::editCurrent $w]
    bind $w.t <Return>    "[list ::grid::editCurrent $w] ; break"
    bind $w.t <KP_Enter>  "[list ::grid::editCurrent $w] ; break"
    bind $w.t <Key-Menu>  "[list ::grid::keyMenu $w] ; break"
    bind $w.t <Shift-F10> "[list ::grid::keyMenu $w] ; break"
    bind $w.t <Left>      "[list ::grid::moveCol $w -1] ; break"
    bind $w.t <Right>     "[list ::grid::moveCol $w 1] ; break"
    bind $w.t <Button-3>  [list ::grid::popupMenu $w %x %y %X %Y]
    bind $w.t <Button-2>  [list ::grid::popupMenu $w %x %y %X %Y]
    bind $w.t <Control-Button-1> [list ::grid::popupMenu $w %x %y %X %Y]
    bind $w <Destroy> [list ::grid::forget $w]
    return $w
}
proc ::grid::forget {w} {
    variable G
    foreach k [array names G $w,*] { unset G($k) }
}
proc ::grid::recolor {t} {
    $t tag configure odd -background $::theme::c(stripe)
    $t tag configure even -background $::theme::c(surface)
}

proc ::grid::clear {w} {
    variable G
    $w.t delete [$w.t children {}]
    set G($w,rows) {} ; set G($w,rowids) {} ; set G($w,order) {}
}

# ---- loading ------------------------------------------------------------------
proc ::grid::load {w result} {
    variable G ; variable maxDisplay
    set t $w.t
    $t delete [$t children {}]
    set cols [dict get $result cols]
    set G($w,cols) $cols
    set G($w,types) [dict get $result types]
    set G($w,rows) [summariseBytes [dict get $result rows] $G($w,types)]
    set G($w,rowids) [dict get $result rowids]
    set G($w,drill) [dict get $result drill]
    set G($w,source) [dict get $result source]
    set G($w,rowbase) [expr {[dict exists $result rowbase] ? [dict get $result rowbase] : 0}]
    set G($w,total) [llength $G($w,rows)]
    set G($w,sortcol) -1
    set ids {}
    for {set i 0} {$i < [llength $cols]} {incr i} { lappend ids c$i }
    $t configure -columns [concat rn $ids] -displaycolumns [concat rn $ids]
    # (re)configuring -columns resets per-column options, so set the "#" column here
    $t column rn -width [::theme::px 54] -minwidth [::theme::px 40] -stretch 0 -anchor e
    $t heading rn -text "#" -anchor e
    set i 0
    foreach c $cols type $G($w,types) {
        set anchor [expr {$type in {I L F D N} ? "e" : "w"}]
        $t heading c$i -text $c -anchor $anchor -command [list ::grid::sortBy $w $i]
        $t column c$i -anchor $anchor -stretch 0 -minwidth [::theme::px 50] -width [measure $w $i]
        incr i
    }
    set G($w,order) {}
    set n [expr {min($G($w,total), $maxDisplay)}]
    for {set p 0} {$p < $n} {incr p} { lappend G($w,order) $p }
    fill $w
    return $G($w,total)
}

# Binary columns never go into a cell as raw bytes: show size plus a short hex preview.
proc ::grid::bytesLabel {v} {
    set n [string length $v]
    if {$n == 0} { return "" }
    binary scan [string range $v 0 9] H* hx
    regsub -all {..} $hx {& } hx
    return "<$n byte[expr {$n == 1 ? {} : {s}}]>  [string trim $hx][expr {$n > 10 ? { ...} : {}}]"
}
proc ::grid::summariseBytes {rows types} {
    set cols {}
    set i 0
    foreach t $types { if {$t eq "B"} { lappend cols $i } ; incr i }
    if {![llength $cols]} { return $rows }
    set out {}
    foreach r $rows {
        foreach c $cols { lset r $c [bytesLabel [lindex $r $c]] }
        lappend out $r
    }
    return $out
}

proc ::grid::display {v} {
    if {[string first "\n" $v] >= 0} { set v [string map [list "\r\n" "\u21B5" "\n" "\u21B5" "\r" ""] $v] }
    return $v
}

proc ::grid::fill {w} {
    variable G
    set t $w.t
    $t delete [$t children {}]
    recolor $t
    set k 0
    foreach p $G($w,order) {
        set vals {}
        foreach v [lindex $G($w,rows) $p] { lappend vals [display $v] }
        $t insert {} end -id r$p -values [linsert $vals 0 [expr {$G($w,rowbase) + $k + 1}]] -tags [expr {$k % 2 ? "odd" : "even"}]
        incr k
    }
    if {$G($w,total) == 0 && [llength $G($w,cols)]} {
        place $w.t.empty -relx 0.5 -y 70 -anchor n
    } else { place forget $w.t.empty }
    if {$G($w,-changed) ne ""} { uplevel #0 $G($w,-changed) }
}

proc ::grid::measure {w i} {
    variable G
    set best [font measure MkSmall [lindex $G($w,cols) $i]]
    incr best 28
    set n 0
    foreach r $G($w,rows) {
        set v [lindex $r $i]
        if {[string length $v] > 60} { set v [string range $v 0 60] }
        set m [font measure MkUI [display $v]]
        if {$m > $best - 20} { set best [expr {$m + 20}] }
        if {[incr n] >= 200} break
    }
    return [expr {min(max($best, 70), 440)}]
}

# ---- sorting ------------------------------------------------------------------
proc ::grid::sortKey {type v} {
    if {$type eq "V" && [regexp {(\d+) row} $v -> n]} { return $n }
    return $v
}
proc ::grid::sortBy {w i} {
    variable G
    if {$G($w,sortcol) == $i} {
        set G($w,sortdir) [expr {$G($w,sortdir) eq "asc" ? "desc" : "asc"}]
    } else { set G($w,sortcol) $i ; set G($w,sortdir) asc }
    set type [lindex $G($w,types) $i]
    set keyed {}
    for {set p 0} {$p < $G($w,total)} {incr p} {
        lappend keyed [list $p [sortKey $type [lindex $G($w,rows) $p $i]]]
    }
    set sorted [lsort -command [list ::grid::cmpKeyed] $keyed]
    if {$G($w,sortdir) eq "desc"} { set sorted [lreverse $sorted] }
    variable maxDisplay
    set G($w,order) {}
    foreach k [lrange $sorted 0 [expr {$maxDisplay - 1}]] { lappend G($w,order) [lindex $k 0] }
    # heading arrows
    for {set j 0} {$j < [llength $G($w,cols)]} {incr j} {
        set txt [lindex $G($w,cols) $j]
        if {$j == $i} { append txt [expr {$G($w,sortdir) eq "asc" ? "  \u25B2" : "  \u25BC"}] }
        $w.t heading c$j -text $txt
    }
    fill $w
}
# SQL-ish three-way compare for the sort-by-header feature (numbers numerically)
proc ::grid::compare {a b} {
    if {[string is double -strict $a] && [string is double -strict $b]} {
        return [expr {$a < $b ? -1 : $a > $b ? 1 : 0}]
    }
    set c [string compare -nocase $a $b]
    if {$c == 0} { set c [string compare $a $b] }
    return $c
}
proc ::grid::cmpKeyed {a b} { ::grid::compare [lindex $a 1] [lindex $b 1] }

# ---- selection / copy -----------------------------------------------------------
proc ::grid::selChanged {w} {
    variable G
    event generate $w <<GridSelect>>
}
proc ::grid::selectedPositions {w} {
    set out {}
    foreach item [$w.t selection] { lappend out [string range $item 1 end] }
    return $out
}
# store row ids of the selection (editable grids over a view)
proc ::grid::selectedRowids {w} {
    variable G
    set out {}
    foreach p [selectedPositions $w] {
        if {[llength $G($w,rowids)]} { lappend out [lindex $G($w,rowids) $p] }
    }
    return $out
}
proc ::grid::count {w} { variable G ; return $G($w,total) }
proc ::grid::hasData {w} { variable G ; expr {[info exists G($w,cols)] && [llength $G($w,cols)] > 0} }

proc ::grid::tsv {w headers {onlySelected 1}} {
    variable G
    set lines {}
    if {$headers} { lappend lines [join $G($w,cols) \t] }
    if {$onlySelected && [llength [$w.t selection]]} {
        set positions [lsort -integer [selectedPositions $w]]
    } else {
        set positions $G($w,order)
    }
    foreach p $positions {
        set cells {}
        foreach v [lindex $G($w,rows) $p] { lappend cells [string map [list \t " " \n " " \r ""] $v] }
        lappend lines [join $cells \t]
    }
    return [join $lines \n]
}
proc ::grid::copy {w headers} {
    clipboard clear
    clipboard append [tsv $w $headers 1]
}
proc ::grid::copyCell {w} {
    variable G
    set sel [$w.t selection]
    if {![llength $sel]} return
    set p [string range [lindex $sel 0] 1 end]
    clipboard clear
    clipboard append [lindex $G($w,rows) $p $G($w,lastcol)]
}

proc ::grid::csvEscape {v} {
    if {[regexp {[",\n\r]} $v]} { return "\"[string map {\" \"\"} $v]\"" }
    return $v
}
proc ::grid::exportCsv {w} {
    variable G
    if {![hasData $w]} return
    set f [tk_getSaveFile -title "Export results as CSV" -defaultextension .csv \
        -filetypes {{{CSV files} .csv} {{All files} *}}]
    if {$f eq ""} return
    set out [open $f w]
    fconfigure $out -encoding utf-8
    puts $out [join [lmap_csv $G($w,cols)] ,]
    foreach p $G($w,order) { puts $out [join [lmap_csv [lindex $G($w,rows) $p]] ,] }
    close $out
    return $f
}
proc ::grid::lmap_csv {l} { set r {} ; foreach v $l { lappend r [csvEscape $v] } ; return $r }

proc ::grid::popupMenu {w x y X Y} {
    variable G
    set item [$w.t identify row $x $y]
    if {$item ne "" && [lsearch -exact [$w.t selection] $item] < 0} { $w.t selection set $item }
    noteColumn $w $x $y
    set m $w.menu
    catch {destroy $m}
    menu $m -tearoff 0
    ::theme::menu $m
    $m add command -label "Copy" -accelerator Ctrl+C -command [list ::grid::copy $w 0]
    $m add command -label "Copy with Headers" -accelerator Ctrl+Shift+C -command [list ::grid::copy $w 1]
    $m add command -label "Copy Cell" -command [list ::grid::copyCell $w]
    $m add separator
    $m add command -label "Select All" -accelerator Ctrl+A -command [list $w.t selection set [$w.t children {}]]
    $m add command -label "Export as CSV\u2026" -command [list ::grid::exportCsv $w]
    if {$G($w,-editable)} {
        $m add separator
        $m add command -label "Edit Cell" -accelerator F2 -command [list ::grid::editCurrent $w]
        $m add command -label "Delete Row(s)" -accelerator Del -command [list event generate $w <<GridDelete>>]
    }
    ::menus::post $m $X $Y
}

# hand cursor over subview cells, which open on double-click
proc ::grid::motion {w x y} {
    variable G
    set cursor ""
    if {[$w.t identify region $x $y] eq "cell" && [regexp {^#(\d+)$} [$w.t identify column $x $y] -> n] && $n > 1} {
        if {[dict exists $G($w,drill) [expr {$n - 2}]]} { set cursor hand2 }
    }
    if {[$w.t cget -cursor] ne $cursor} { $w.t configure -cursor $cursor }
}

# keyboard cell cursor: Left/Right choose the column that F2 / Enter will edit
proc ::grid::moveCol {w d} {
    variable G
    set n [llength $G($w,cols)]
    if {!$n} return
    set G($w,lastcol) [expr {max(0, min($n - 1, $G($w,lastcol) + $d))}]
    set col [lindex $G($w,cols) $G($w,lastcol)]
    event generate $w <<GridColumn>> -data $col
}
proc ::grid::keyMenu {w} {
    set item [$w.t focus]
    if {$item eq ""} return
    lassign [$w.t bbox $item] x y cw ch
    popupMenu $w $x $y [expr {[winfo rootx $w.t] + $x + 24}] [expr {[winfo rooty $w.t] + $y + $ch}]
}

proc ::grid::noteColumn {w x y} {
    variable G
    set col [$w.t identify column $x $y]
    if {[regexp {^#(\d+)$} $col -> n] && $n > 1} { set G($w,lastcol) [expr {$n - 2}] }
}

# ---- editing / drill-down ---------------------------------------------------------
proc ::grid::doubleClick {w x y} {
    variable G
    if {[$w.t identify region $x $y] ne "cell"} return
    set item [$w.t identify row $x $y]
    set col [$w.t identify column $x $y]
    if {![regexp {^#(\d+)$} $col -> n] || $n < 2} return
    set ci [expr {$n - 2}]
    set p [string range $item 1 end]
    if {[dict exists $G($w,drill) $ci]} {
        if {$G($w,-drill) ne "" && [llength $G($w,rowids)]} {
            uplevel #0 [list {*}$G($w,-drill) [lindex $G($w,rowids) $p] [dict get $G($w,drill) $ci]]
        }
        return
    }
    if {$G($w,-editable)} { edit $w $item $ci }
}
proc ::grid::editCurrent {w} {
    variable G
    if {!$G($w,-editable)} return
    set sel [$w.t selection]
    if {![llength $sel]} return
    edit $w [lindex $sel 0] $G($w,lastcol)
}

proc ::grid::edit {w item ci} {
    variable G
    set t $w.t
    $t see $item
    update idletasks
    set bb [$t bbox $item c$ci]
    if {$bb eq ""} return
    lassign $bb x y cw ch
    catch {destroy $t.edit}
    set p [string range $item 1 end]
    set G($w,editval) [lindex $G($w,rows) $p $ci]
    set G($w,editing) [list $item $ci]
    ttk::entry $t.edit -textvariable ::grid::G($w,editval) -font MkUI
    place $t.edit -x $x -y $y -width $cw -height $ch
    $t.edit selection range 0 end
    focus $t.edit
    $t.edit icursor end
    bind $t.edit <Return>    [list ::grid::editDone $w 1 down]
    bind $t.edit <KP_Enter>  [list ::grid::editDone $w 1 down]
    bind $t.edit <Tab>       "[list ::grid::editDone $w 1 right] ; break"
    ::ui::bindSafe $t.edit <ISO_Left_Tab> "[list ::grid::editDone $w 1 left] ; break"
    bind $t.edit <Escape>    [list ::grid::editDone $w 0 none]
    bind $t.edit <FocusOut>  [list ::grid::editDone $w 1 none]
}

proc ::grid::editDone {w accept move} {
    variable G
    set t $w.t
    if {![info exists G($w,editing)] || $G($w,editing) eq ""} return
    lassign $G($w,editing) item ci
    set new $G($w,editval)
    set p [string range $item 1 end]
    set old [lindex $G($w,rows) $p $ci]
    set G($w,editing) ""
    bind $t.edit <FocusOut> {}
    set ok 1
    if {$accept && $new ne $old} {
        set rowid [lindex $G($w,rowids) $p]
        set col [lindex $G($w,cols) $ci]
        if {[catch {uplevel #0 [list {*}$G($w,-commit) $rowid $col $new]} err]} {
            set ok 0
            event generate $w <<GridError>> -data $err
            set G($w,lasterror) $err
        } else {
            lset G($w,rows) $p $ci $new
            $t set $item c$ci [display $new]
        }
    }
    destroy $t.edit
    if {!$ok} { focus $t ; return }
    focus $t
    set children [$t children {}]
    set idx [lsearch -exact $children $item]
    switch -- $move {
        down  { if {$idx + 1 < [llength $children]} { set n [lindex $children [expr {$idx+1}]] ; $t selection set $n ; edit $w $n $ci } }
        right { if {$ci + 1 < [llength $G($w,cols)]} { edit $w $item [expr {$ci+1}] } }
        left  { if {$ci > 0} { edit $w $item [expr {$ci-1}] } }
    }
}

# Scroll to and select the last row, optionally opening the first editable cell.
proc ::grid::selectLast {w} {
    set last [lindex [$w.t children {}] end]
    if {$last eq ""} return
    $w.t selection set $last
    $w.t see $last
    $w.t focus $last
}
