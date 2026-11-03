# grid.tcl -- the result / data grid: a virtualised ttk::treeview dressed up as a spreadsheet.
#
#   ::grid::create w ?-editable 1? ?-commit cmd? ?-drill cmd? ?-changed cmd?
#   ::grid::load w result            in-memory rows (the dict produced by the query engine)
#   ::grid::loadStore w mk ?keep?    every row of a Metakit view, read lazily as you scroll
#
#   -commit  {rowid column value}    called when a cell edit is accepted; raise an
#                                    error to reject it (the message is shown)
#   -drill   {rowid subviewName}     called when a subview cell is double-clicked
#   -changed {}                      called after the grid contents changed
#
# Virtualisation.  The treeview only ever holds as many rows ("slots" s0, s1, ...) as fit in
# the window.  The grid owns the scrollbar, the mouse wheel, the keyboard cursor and the
# selection (a list of row ranges, so "select all" of 500,000 rows costs nothing); scrolling
# just re-labels the slots.  Rows come from a data source ("provider"):
#
#   ::grid::memsrc w ...    rows held in a Tcl list (query results)
#   ::grid::mksrc  w ...    rows read from Metakit on demand, with a small cache
#
# A provider answers:  count | rows first n | rowid p | cell p ci | put p ci value | sort ci dir
# where p is a position in the current display order.

namespace eval ::grid {
    variable G
    array set G {}
    variable MS ;# memory provider state
    array set MS {}
    variable KS ;# Metakit provider state
    array set KS {}
    variable cacheMax 4000
}

proc ::grid::create {w args} {
    variable G
    array set o {-editable 0 -commit {} -drill {} -changed {}}
    array set o $args
    foreach k [array names o] { set G($w,$k) $o($k) }
    set G($w,cols) {} ; set G($w,types) {} ; set G($w,drill) {} ; set G($w,source) ""
    set G($w,src) {} ; set G($w,total) 0 ; set G($w,top) 0 ; set G($w,attached) 0 ; set G($w,nslots) 0
    set G($w,sel) {} ; set G($w,anchor) -1 ; set G($w,cur) -1 ; set G($w,lastcol) 0
    set G($w,sortcol) -1 ; set G($w,sortdir) asc ; set G($w,editing) "" ; set G($w,editval) ""
    set G($w,lasterror) "" ; set G($w,hov) "" ; set G($w,rh) 0 ; set G($w,hh) 0 ; set G($w,drag) 0
    set G($w,relayout) ""

    ttk::frame $w -style Surface.TFrame
    # the row-number "#" is an ordinary right-aligned column (the tree column's anchor
    # is ignored by some Tk versions, which made it left-aligned under a right-aligned header)
    ttk::treeview $w.t -style Grid.Treeview -show headings -selectmode none \
        -columns {rn} -xscrollcommand [list $w.h set]
    ttk::scrollbar $w.v -orient vertical -command [list ::grid::vscroll $w]
    ttk::scrollbar $w.h -orient horizontal -command [list $w.t xview]
    grid $w.t -row 0 -column 0 -sticky nsew
    grid $w.v -row 0 -column 1 -sticky ns
    grid $w.h -row 1 -column 0 -sticky ew
    grid rowconfigure $w 0 -weight 1 ; grid columnconfigure $w 0 -weight 1

    $w.t column rn -width [::theme::px 54] -stretch 0 -anchor e
    $w.t heading rn -text "#" -anchor e
    # tag order matters: in Tk 8.6 the EARLIEST configured tag wins when several set an option
    $w.t tag configure hover -background $::theme::c(hover)
    $w.t tag configure sel
    recolor $w.t
    ::theme::reg $w.t [list ::grid::recolor %w]
    ttk::label $w.t.empty -text "No rows" -style SurfaceDim.TLabel
    ttk::label $w.stale -style SurfaceDim.TLabel -padding {10 4} \
        -text "These results are out of date - the data changed after the query ran. Run the query again."

    set t $w.t
    bind $t <Motion>  [list ::grid::motion $w %x %y]
    bind $t <Leave>   [list ::grid::hoverTo $w ""]
    bind $t <Configure> [list ::grid::scheduleLayout $w]
    bind $t <Button-1>        [list ::grid::click $w %x %y %s]
    bind $t <B1-Motion>       [list ::grid::dragTo $w %x %y]
    bind $t <ButtonRelease-1> [list ::grid::dragEnd $w]
    bind $t <Double-1>  [list ::grid::doubleClick $w %x %y]
    bind $t <MouseWheel> [list ::grid::wheel $w %D %s]
    bind $t <Button-4>   [list ::grid::wheelStep $w -3]
    bind $t <Button-5>   [list ::grid::wheelStep $w 3]
    bind $t <Shift-Button-4> [list $t xview scroll -3 units]
    bind $t <Shift-Button-5> [list $t xview scroll 3 units]
    bind $w.v <MouseWheel> [list ::grid::wheel $w %D %s]
    bind $w.v <Button-4>   [list ::grid::wheelStep $w -3]
    bind $w.v <Button-5>   [list ::grid::wheelStep $w 3]

    foreach {key delta} {Up -1 Down 1 Prior -PAGE Next PAGE} {
        bind $t <$key>       "[list ::grid::key $w $delta 0] ; break"
        bind $t <Shift-$key> "[list ::grid::key $w $delta 1] ; break"
    }
    bind $t <Home>          "[list ::grid::key $w HOME 0] ; break"
    bind $t <End>           "[list ::grid::key $w END 0] ; break"
    bind $t <Shift-Home>    "[list ::grid::key $w HOME 1] ; break"
    bind $t <Shift-End>     "[list ::grid::key $w END 1] ; break"
    bind $t <Control-Home>  "[list ::grid::key $w HOME 0] ; break"
    bind $t <Control-End>   "[list ::grid::key $w END 0] ; break"
    ::ui::bindMod $t c "[list ::grid::copy $w 0] ; break"
    ::ui::bindMod $t C "[list ::grid::copy $w 1] ; break"
    ::ui::bindMod $t a "[list ::grid::selectAll $w] ; break"
    bind $t <F2>        [list ::grid::editCurrent $w]
    bind $t <Return>    "[list ::grid::editCurrent $w] ; break"
    bind $t <KP_Enter>  "[list ::grid::editCurrent $w] ; break"
    bind $t <Key-Menu>  "[list ::grid::keyMenu $w] ; break"
    bind $t <Shift-F10> "[list ::grid::keyMenu $w] ; break"
    bind $t <Left>      "[list ::grid::moveCol $w -1] ; break"
    bind $t <Right>     "[list ::grid::moveCol $w 1] ; break"
    bind $t <Button-3>  [list ::grid::popupMenu $w %x %y %X %Y]
    bind $t <Button-2>  [list ::grid::popupMenu $w %x %y %X %Y]
    if {[tk windowingsystem] eq "aqua"} { bind $t <Control-Button-1> "[list ::grid::popupMenu $w %x %y %X %Y] ; break" }
    bind $w <Destroy> [list ::grid::forget $w]
    return $w
}
# a provider supplied by the engine may hold resources (compiled code); tell it we are done
proc ::grid::destroyProvider {w} {
    variable G
    if {[info exists G($w,src)] && [lindex $G($w,src) 0] ni {::grid::memsrc ::grid::mksrc} && [llength $G($w,src)]} {
        catch {{*}$G($w,src) destroy}
    }
}
proc ::grid::forget {w} {
    variable G ; variable MS ; variable KS
    destroyProvider $w
    foreach k [array names G $w,*] { unset G($k) }
    foreach k [array names MS $w,*] { unset MS($k) }
    foreach k [array names KS $w,*] { unset KS($k) }
}
proc ::grid::recolor {t} {
    $t tag configure hover -background $::theme::c(hover)
    $t tag configure sel -background $::theme::c(sel) -foreground $::theme::c(selFg)
    $t tag configure odd -background $::theme::c(stripe)
    $t tag configure even -background $::theme::c(surface)
}

# ============================================================================
#  Providers
# ============================================================================
# ---- rows in memory ----------------------------------------------------------------------
proc ::grid::memLoad {w rows rowids} {
    variable MS
    set MS($w,rows) $rows ; set MS($w,rowids) $rowids ; set MS($w,order) {}
}
proc ::grid::memsrc {w method args} {
    variable MS
    switch -- $method {
        count { return [llength $MS($w,rows)] }
        rows {
            lassign $args first n
            set out {}
            set last [expr {$first + $n - 1}]
            if {![llength $MS($w,order)]} { return [lrange $MS($w,rows) $first $last] }
            foreach p [lrange $MS($w,order) $first $last] { lappend out [lindex $MS($w,rows) $p] }
            return $out
        }
        rowid {
            set p [lindex $args 0]
            if {![llength $MS($w,rowids)]} { return "" }
            if {[llength $MS($w,order)]} { set p [lindex $MS($w,order) $p] }
            return [lindex $MS($w,rowids) $p]
        }
        cell {
            lassign $args p ci
            if {[llength $MS($w,order)]} { set p [lindex $MS($w,order) $p] }
            return [lindex $MS($w,rows) $p $ci]
        }
        put {
            lassign $args p ci v
            if {[llength $MS($w,order)]} { set p [lindex $MS($w,order) $p] }
            lset MS($w,rows) $p $ci $v
        }
        sort {
            lassign $args ci dir type
            set kc {}
            foreach r $MS($w,rows) { lappend kc [sortKey $type [lindex $r $ci]] }
            set n [llength $kc]
            set perm {}
            for {set i 0} {$i < $n} {incr i} { lappend perm $i }
            set MS($w,order) [sortPerm $perm $kc [expr {$dir eq "desc"}]]
        }
    }
}

# ---- rows read from Metakit on demand -------------------------------------------------------
proc ::grid::ksLoad {w mk layout} {
    variable KS
    set KS($w,mk) $mk ; set KS($w,layout) $layout ; set KS($w,order) {}
    set props {}
    foreach c $layout { if {[lindex $c 1] ne "V"} { lappend props [lindex $c 0] } }
    set KS($w,props) $props
    set KS($w,cache) [dict create]
    set KS($w,total) [::store::size $mk]
}
proc ::grid::ksRow {w idx vals} {
    variable KS
    set out {} ; set k 0
    foreach c $KS($w,layout) {
        lassign $c name t
        if {$t eq "V"} {
            set cnt [::store::subSize $KS($w,mk) $idx $name]
            lappend out "\u25B8 $cnt row[expr {$cnt == 1 ? {} : {s}}]"
        } else {
            set v [lindex $vals $k] ; incr k
            # (an if, not expr's ?: -- that would turn text such as 07 into the number 7)
            if {$t eq "B"} { lappend out [bytesLabel $v] } else { lappend out $v }
        }
    }
    return $out
}
proc ::grid::mksrc {w method args} {
    variable KS ; variable cacheMax
    switch -- $method {
        count { return $KS($w,total) }
        rows {
            lassign $args first n
            set last [expr {min($KS($w,total), $first + $n) - 1}]
            if {$last < $first} { return {} }
            if {[llength $KS($w,order)]} {
                set ids [lrange $KS($w,order) $first $last]
            } else {
                set ids {}
                for {set i $first} {$i <= $last} {incr i} { lappend ids $i }
            }
            set missing {}
            foreach i $ids { if {![dict exists $KS($w,cache) $i]} { lappend missing $i } }
            if {[llength $missing]} {
                # over budget: start afresh (and then everything asked for is missing)
                if {[dict size $KS($w,cache)] + [llength $missing] > $cacheMax} {
                    set KS($w,cache) [dict create]
                    set missing $ids
                }
                set fetched [::store::fetchAt $KS($w,mk) $KS($w,props) $missing]
                foreach i $missing v $fetched { dict set KS($w,cache) $i [ksRow $w $i $v] }
            }
            set out {}
            foreach i $ids { lappend out [dict get $KS($w,cache) $i] }
            return $out
        }
        rowid {
            set p [lindex $args 0]
            if {[llength $KS($w,order)]} { return [lindex $KS($w,order) $p] }
            return $p
        }
        cell {
            lassign $args p ci
            return [lindex [lindex [mksrc $w rows $p 1] 0] $ci]
        }
        put {
            lassign $args p ci v
            set i [mksrc $w rowid $p]
            if {[dict exists $KS($w,cache) $i]} {
                dict set KS($w,cache) $i [lreplace [dict get $KS($w,cache) $i] $ci $ci $v]
            }
        }
        sort {
            lassign $args ci dir type
            set name [lindex [lindex $KS($w,layout) $ci] 0]
            set mk $KS($w,mk)
            set tag [lindex [split $mk .!] 0]
            set ckey [list order $mk $name $dir]
            set hit [::store::cacheGet $tag $ckey]
            if {[llength $hit]} { set KS($w,order) [lindex $hit 0] ; return }
            set n $KS($w,total)
            if {$type eq "V"} {
                set kc {}
                for {set i 0} {$i < $n} {incr i} { lappend kc [::store::subSize $mk $i $name] }
            } elseif {$type eq "B"} {
                set kc {}
                foreach v [::store::column $mk $name] { lappend kc [string length $v] }
            } else {
                set kc [::store::column $mk $name]
            }
            set perm {}
            for {set i 0} {$i < $n} {incr i} { lappend perm $i }
            set KS($w,order) [sortPerm $perm $kc [expr {$dir eq "desc"}]]
            ::store::cachePut $tag $ckey $n $KS($w,order)
        }
    }
}

# ---- sorting helpers (shared by both providers) -------------------------------------------
proc ::grid::numeric {v} { return [string is double -strict $v] }
proc ::grid::sortKey {type v} {
    if {$type eq "V" && [regexp {(\d+) row} $v -> n]} { return $n }
    return $v
}
# Reorder `perm` (record indices) by keys `kc` (indexed by record index); stable.  Numbers sort
# numerically, text case-insensitively; a column mixing both uses a comparator.
proc ::grid::sortPerm {perm kc desc} {
    set allnum 1 ; set alltext 1
    foreach v $kc {
        if {[numeric $v]} { set alltext 0 } else { set allnum 0 }
        if {!$allnum && !$alltext} break
    }
    set dir [expr {$desc ? "-decreasing" : "-increasing"}]
    if {$allnum} {
        set idx [lsort -real -indices $dir $kc]
    } elseif {$alltext} {
        set idx [lsort -ascii -nocase -indices $dir $kc]
    } else {
        set pairs {}
        foreach i $perm { lappend pairs [list $i [lindex $kc $i]] }
        set sorted [lsort -command ::grid::cmpKeyed $pairs]
        if {$desc} { set sorted [lreverse $sorted] }
        set out {}
        foreach p $sorted { lappend out [lindex $p 0] }
        return $out
    }
    return $idx
}
# SQL-ish three-way compare (numbers numerically, then text)
proc ::grid::compare {a b} {
    if {[numeric $a] && [numeric $b]} { return [expr {$a < $b ? -1 : $a > $b ? 1 : 0}] }
    set c [string compare -nocase $a $b]
    if {$c == 0} { set c [string compare $a $b] }
    return $c
}
proc ::grid::cmpKeyed {a b} { ::grid::compare [lindex $a 1] [lindex $b 1] }

# ============================================================================
#  Loading
# ============================================================================
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

# Query results.  Returns the number of rows.
proc ::grid::load {w result} {
    variable G
    if {[dict exists $result provider]} {
        # the engine streams the rows itself (see engine.tcl): nothing is held here
        destroyProvider $w
        set G($w,src) [dict get $result provider]
        install $w [dict get $result cols] [dict get $result types] [dict get $result drill] [dict get $result source] 0
        return $G($w,total)
    }
    destroyProvider $w
    set types [dict get $result types]
    set rows [summariseBytes [dict get $result rows] $types]
    memLoad $w $rows [dict get $result rowids]
    set G($w,src) [list ::grid::memsrc $w]
    install $w [dict get $result cols] $types [dict get $result drill] [dict get $result source] 0
    return $G($w,total)
}

# Every row of a Metakit view (or subview), fetched lazily.  keep=1 keeps scroll position and
# selection (clamped), as after an edit or an undo.
proc ::grid::loadStore {w mk {keep 0}} {
    variable G
    set layout [::store::layout $mk]
    set cols {} ; set types {} ; set drill [dict create]
    set i 0
    foreach c $layout {
        lassign $c n t
        lappend cols $n ; lappend types $t
        if {$t eq "V"} { dict set drill $i $n }
        if {$t eq "B"} { dict set drill $i @$n }
        incr i
    }
    destroyProvider $w
    ksLoad $w $mk $layout
    set G($w,src) [list ::grid::mksrc $w]
    install $w $cols $types $drill $mk $keep
    return $G($w,total)
}
# The number of rows may change underneath us (rows added / deleted elsewhere).
proc ::grid::refreshCount {w} {
    variable G ; variable KS
    if {![info exists KS($w,mk)]} return
    set KS($w,total) [::store::size $KS($w,mk)]
    set KS($w,cache) [dict create]
    set KS($w,order) {}
}

proc ::grid::install {w cols types drill source keep} {
    variable G
    set t $w.t
    set oldTop $G($w,top) ; set oldSel $G($w,sel) ; set oldCur $G($w,cur)
    editAbort $w
    set G($w,cols) $cols ; set G($w,types) $types ; set G($w,drill) $drill ; set G($w,source) $source
    set G($w,total) [{*}$G($w,src) count]
    set G($w,sortcol) -1
    set ids {}
    for {set i 0} {$i < [llength $cols]} {incr i} { lappend ids c$i }
    $t configure -columns [concat rn $ids] -displaycolumns [concat rn $ids]
    # (re)configuring -columns resets per-column options, so set the "#" column here
    # wide enough for the largest row number (500,000 rows need six digits)
    set rnw [expr {max([::theme::px 54], [font measure MkUI [string repeat 8 [string length $G($w,total)]]] + [::theme::px 24])}]
    $t column rn -width $rnw -minwidth [::theme::px 40] -stretch 0 -anchor e
    $t heading rn -text "#" -anchor e
    set i 0
    foreach c $cols type $types {
        set anchor [expr {$type in {I L F D N} ? "e" : "w"}]
        $t heading c$i -text $c -anchor $anchor -command [list ::grid::sortBy $w $i]
        $t column c$i -anchor $anchor -stretch 0 -minwidth [::theme::px 50] -width [measure $w $i]
        incr i
    }
    if {$keep} {
        set G($w,top) $oldTop
        set G($w,sel) [clipRanges $oldSel $G($w,total)]
        set G($w,cur) [expr {$oldCur < $G($w,total) ? $oldCur : -1}]
    } else {
        set G($w,top) 0 ; set G($w,sel) {} ; set G($w,anchor) -1 ; set G($w,cur) -1
    }
    if {$G($w,lastcol) >= [llength $cols]} { set G($w,lastcol) 0 }
    layoutSlots $w
    changed $w
}
proc ::grid::changed {w} {
    variable G
    if {$G($w,total) == 0 && [llength $G($w,cols)]} {
        place $w.t.empty -relx 0.5 -y 70 -anchor n
    } else { place forget $w.t.empty }
    if {$G($w,-changed) ne ""} { uplevel #0 $G($w,-changed) }
}

proc ::grid::measure {w i} {
    variable G
    set best [font measure MkSmall [lindex $G($w,cols) $i]]
    incr best 28
    # sample the start, the middle and the end (later rows are often longer, e.g. "person 250000")
    set total $G($w,total)
    foreach from [list 0 [expr {$total / 2}] [expr {max(0, $total - 70)}]] {
        set n [expr {min(70, $total - $from)}]
        if {$n <= 0} continue
        foreach r [fetchRows $w $from $n] {
            set v [lindex $r $i]
            if {[string length $v] > 60} { set v [string range $v 0 60] }
            set m [font measure MkUI [display $v]]
            if {$m > $best - 20} { set best [expr {$m + 20}] }
        }
    }
    return [expr {min(max($best, 70), 440)}]
}

# ============================================================================
#  Slots: the handful of real treeview rows, and painting them
# ============================================================================
proc ::grid::scheduleLayout {w} {
    variable G
    if {$G($w,relayout) ne ""} return
    set G($w,relayout) [after idle [list ::grid::layoutSlots $w]]
}

# Measure the widget: header height, row height, how many rows are fully visible.
proc ::grid::metrics {w} {
    variable G
    set t $w.t
    if {$G($w,rh) == 0 && $G($w,attached) > 0} {
        if {![catch {$t bbox s0} bb] && [llength $bb] == 4 && [lindex $bb 3] > 0} {
            set G($w,rh) [lindex $bb 3] ; set G($w,hh) [lindex $bb 1]
        }
    }
    set rh $G($w,rh)
    if {$rh == 0} { set rh [expr {max(16, [ttk::style lookup Grid.Treeview -rowheight])}] }
    set hh $G($w,hh)
    if {$hh == 0} { set hh $rh }
    return [list $hh $rh]
}
proc ::grid::visRows {w} {
    lassign [metrics $w] hh rh
    set h [winfo height $w.t]
    if {$h <= 1} { set h 400 }
    return [expr {max(1, ($h - $hh) / $rh)}]
}

# Make sure there are enough slots for the window, then repaint.
proc ::grid::layoutSlots {w} {
    variable G
    if {![winfo exists $w.t]} return
    set G($w,relayout) ""
    set t $w.t
    set want [expr {[visRows $w] + 2}]
    while {$G($w,nslots) < $want} {
        $t insert {} end -id s$G($w,nslots)
        $t detach s$G($w,nslots)                ;# paint attaches the slots that have data
        incr G($w,nslots)
    }
    clampTop $w
    paint $w
}
proc ::grid::maxTop {w} {
    variable G
    return [expr {max(0, $G($w,total) - [visRows $w])}]
}
proc ::grid::clampTop {w} {
    variable G
    set m [maxTop $w]
    if {$G($w,top) > $m} { set G($w,top) $m }
    if {$G($w,top) < 0} { set G($w,top) 0 }
}

# Re-label every slot for the current top row, and update the scrollbar.
proc ::grid::paint {w} {
    variable G
    set t $w.t
    set top $G($w,top)
    set n [expr {max(0, min($G($w,nslots), $G($w,total) - $top))}]
    set rows {}
    if {$n > 0} { set rows [fetchRows $w $top $n] }
    set G($w,hov) ""
    for {set k 0} {$k < $n} {incr k} {
        set p [expr {$top + $k}]
        set vals {}
        foreach v [lindex $rows $k] { lappend vals [display $v] }
        $t item s$k -values [linsert $vals 0 [expr {$p + 1}]] -tags [rowTags $w $p]
    }
    # attach / detach so that exactly the rows that have data are in the tree
    if {$n > $G($w,attached)} {
        for {set k $G($w,attached)} {$k < $n} {incr k} { $t move s$k {} $k }
    } elseif {$n < $G($w,attached)} {
        for {set k $n} {$k < $G($w,attached)} {incr k} { $t detach s$k }
    }
    set G($w,attached) $n
    scrollbarSync $w
    rehover $w
    staleCheck $w
}
# a streaming result reads live data; if the data changed since the query ran, say so
proc ::grid::staleCheck {w} {
    variable G
    set stale 0
    if {[lindex $G($w,src) 0] ni {::grid::memsrc ::grid::mksrc} && [llength $G($w,src)]} {
        if {![catch {{*}$G($w,src) stale} v]} { set stale $v }
    }
    if {$stale} { grid $w.stale -row 2 -column 0 -columnspan 2 -sticky ew } else { grid remove $w.stale }
}
proc ::grid::rowTags {w p} {
    return [list [expr {[selContains $w $p] ? "sel" : ($p % 2 ? "odd" : "even")}]]
}
proc ::grid::scrollbarSync {w} {
    variable G
    set total $G($w,total) ; set vis [visRows $w]
    if {$total <= $vis} { $w.v set 0.0 1.0 ; return }
    $w.v set [expr {double($G($w,top)) / $total}] [expr {double($G($w,top) + $vis) / $total}]
}
# repaint only the selection colouring (cheap)
proc ::grid::paintSel {w} {
    variable G
    set t $w.t
    for {set k 0} {$k < $G($w,attached)} {incr k} {
        set p [expr {$G($w,top) + $k}]
        $t item s$k -tags [rowTags $w $p]
    }
    set G($w,hov) ""
    rehover $w
    event generate $w <<GridSelect>>
}

# ---- scrolling -------------------------------------------------------------------------------
proc ::grid::scrollTo {w top} {
    variable G
    if {$G($w,editing) ne ""} { editDone $w 1 none }
    set old $G($w,top)
    set G($w,top) $top
    clampTop $w
    if {$G($w,top) != $old} { paint $w }
}
proc ::grid::vscroll {w args} {
    variable G
    switch -- [lindex $args 0] {
        moveto { scrollTo $w [expr {int(round([lindex $args 1] * $G($w,total)))}] }
        scroll {
            lassign [lrange $args 1 end] n what
            set step [expr {$what eq "pages" ? max(1, [visRows $w] - 1) : 1}]
            scrollTo $w [expr {$G($w,top) + $n * $step}]
        }
    }
}
proc ::grid::wheelStep {w rows} { variable G ; scrollTo $w [expr {$G($w,top) + $rows}] }
proc ::grid::wheel {w delta state} {
    # Windows reports multiples of 120, macOS small integers
    set rows [expr {[tk windowingsystem] eq "aqua" ? -$delta : -($delta / 120) * 3}]
    if {$rows == 0} { set rows [expr {$delta > 0 ? -1 : 1}] }
    if {$state & 1} { $w.t xview scroll [expr {$rows > 0 ? 3 : -3}] units ; return }
    wheelStep $w $rows
}
proc ::grid::ensureVisible {w p} {
    variable G
    set vis [visRows $w]
    if {$p < $G($w,top)} { scrollTo $w $p } elseif {$p >= $G($w,top) + $vis} { scrollTo $w [expr {$p - $vis + 1}] }
}

# ============================================================================
#  Selection: a sorted list of disjoint {lo hi} ranges of row positions
# ============================================================================
proc ::grid::normRanges {ranges} {
    set sorted [lsort -integer -index 0 $ranges]
    set out {}
    foreach r $sorted {
        lassign $r lo hi
        if {[llength $out]} {
            lassign [lindex $out end] plo phi
            if {$lo <= $phi + 1} {
                if {$hi > $phi} { lset out end [list $plo $hi] }
                continue
            }
        }
        lappend out [list $lo $hi]
    }
    return $out
}
proc ::grid::clipRanges {ranges total} {
    set out {}
    foreach r $ranges {
        lassign $r lo hi
        if {$lo >= $total} continue
        lappend out [list $lo [expr {min($hi, $total - 1)}]]
    }
    return $out
}
proc ::grid::selContains {w p} {
    variable G
    foreach r $G($w,sel) {
        if {$p < [lindex $r 0]} { return 0 }
        if {$p <= [lindex $r 1]} { return 1 }
    }
    return 0
}
proc ::grid::selCount {w} {
    variable G
    set n 0
    foreach r $G($w,sel) { incr n [expr {[lindex $r 1] - [lindex $r 0] + 1}] }
    return $n
}
proc ::grid::selRemove {w p} {
    variable G
    set out {}
    foreach r $G($w,sel) {
        lassign $r lo hi
        if {$p < $lo || $p > $hi} { lappend out $r ; continue }
        if {$lo < $p} { lappend out [list $lo [expr {$p - 1}]] }
        if {$hi > $p} { lappend out [list [expr {$p + 1}] $hi] }
    }
    set G($w,sel) $out
}
# public: replace the selection by these positions
proc ::grid::select {w positions} {
    variable G
    set r {}
    foreach p $positions { if {$p >= 0 && $p < $G($w,total)} { lappend r [list $p $p] } }
    set G($w,sel) [normRanges $r]
    if {[llength $positions]} { set G($w,anchor) [lindex $positions 0] ; set G($w,cur) [lindex $positions end] }
    paintSel $w
}
proc ::grid::selectAll {w} {
    variable G
    if {$G($w,total) == 0} return
    set G($w,sel) [list [list 0 [expr {$G($w,total) - 1}]]]
    if {$G($w,cur) < 0} { set G($w,cur) 0 ; set G($w,anchor) 0 }
    paintSel $w
}
proc ::grid::selectLast {w} {
    variable G
    if {$G($w,total) == 0} return
    set last [expr {$G($w,total) - 1}]
    set G($w,sel) [list [list $last $last]]
    set G($w,anchor) $last ; set G($w,cur) $last
    ensureVisible $w $last
    paintSel $w
}
# positions of the selection in order (optionally just the first `limit`)
proc ::grid::selectedPositions {w {limit -1}} {
    variable G
    set out {}
    foreach r $G($w,sel) {
        for {set p [lindex $r 0]} {$p <= [lindex $r 1]} {incr p} {
            lappend out $p
            if {$limit >= 0 && [llength $out] >= $limit} { return $out }
        }
    }
    return $out
}
# store row ids of the selection (editable grids over a view)
proc ::grid::selectedRowids {w} {
    variable G
    set out {}
    foreach p [selectedPositions $w] {
        set id [{*}$G($w,src) rowid $p]
        if {$id ne ""} { lappend out $id }
    }
    return $out
}
# after any data change: tell streaming results whether they are still current
proc ::grid::checkAll {} {
    variable G
    foreach k [array names G *,src] {
        set w [string range $k 0 end-4]
        if {[winfo exists $w.t]} { staleCheck $w }
    }
}
# rows from the data source; engine-supplied sources return raw bytes, which are summarised here
proc ::grid::fetchRows {w first n} {
    variable G
    set rows [{*}$G($w,src) rows $first $n]
    if {[lindex $G($w,src) 0] in {::grid::memsrc ::grid::mksrc}} { return $rows }
    set bcols {} ; set i 0
    foreach t $G($w,types) { if {$t eq "B"} { lappend bcols $i } ; incr i }
    if {![llength $bcols]} { return $rows }
    return [summariseBytes $rows $G($w,types)]
}
proc ::grid::count {w} { variable G ; return $G($w,total) }
proc ::grid::hasData {w} { variable G ; expr {[info exists G($w,cols)] && [llength $G($w,cols)] > 0} }
proc ::grid::top {w} { variable G ; return $G($w,top) }

# ---- mouse -----------------------------------------------------------------------------------
proc ::grid::posAt {w y} {
    variable G
    set item [$w.t identify row 5 $y]
    if {$item eq "" || ![regexp {^s(\d+)$} $item -> k]} { return "" }
    return [expr {$G($w,top) + $k}]
}
proc ::grid::click {w x y state} {
    variable G
    set t $w.t
    set region [$t identify region $x $y]
    if {$region ne "cell" && $region ne "tree"} return          ;# headings and column edges: Tk's own handling
    focus $t
    set p [posAt $w $y]
    if {$p eq ""} return
    noteColumn $w $x $y
    editDoneIfOther $w $p
    set aqua [expr {[tk windowingsystem] eq "aqua"}]
    set toggle [expr {$aqua ? ($state & 8) : ($state & 4)}]
    set shift [expr {$state & 1}]
    if {$shift && $G($w,anchor) >= 0} {
        set a $G($w,anchor)
        set G($w,sel) [list [list [expr {min($a, $p)}] [expr {max($a, $p)}]]]
    } elseif {$toggle} {
        if {[selContains $w $p]} { selRemove $w $p } else { set G($w,sel) [normRanges [concat $G($w,sel) [list [list $p $p]]]] }
        set G($w,anchor) $p
    } else {
        set G($w,sel) [list [list $p $p]]
        set G($w,anchor) $p
    }
    set G($w,cur) $p
    set G($w,drag) 1
    paintSel $w
    return -code break
}
proc ::grid::dragTo {w x y} {
    variable G
    if {!$G($w,drag)} return
    set t $w.t
    lassign [metrics $w] hh rh
    set p [posAt $w $y]
    if {$p eq ""} {
        # above or below the rows: keep scrolling in that direction
        set dir [expr {$y < $hh ? -1 : 1}]
        wheelStep $w [expr {$dir}]
        set p [expr {$dir < 0 ? $G($w,top) : min($G($w,total) - 1, $G($w,top) + $G($w,attached) - 1)}]
        if {[info exists G($w,drag_after)]} { after cancel $G($w,drag_after) }
        set G($w,drag_after) [after 60 [list ::grid::dragTo $w $x $y]]
    } elseif {[info exists G($w,drag_after)]} { after cancel $G($w,drag_after) ; unset G($w,drag_after) }
    if {$p < 0 || $G($w,anchor) < 0} return
    set a $G($w,anchor)
    set G($w,sel) [list [list [expr {min($a, $p)}] [expr {max($a, $p)}]]]
    set G($w,cur) $p
    paintSel $w
}
proc ::grid::dragEnd {w} {
    variable G
    set G($w,drag) 0
    if {[info exists G($w,drag_after)]} { after cancel $G($w,drag_after) ; unset G($w,drag_after) }
}

# ---- hover ---------------------------------------------------------------------------------
proc ::grid::hoverTo {w item} {
    variable G
    if {$G($w,hov) eq $item} return
    set t $w.t
    if {$G($w,hov) ne "" && [$t exists $G($w,hov)]} {
        set p [expr {$G($w,top) + [string range $G($w,hov) 1 end]}]
        $t item $G($w,hov) -tags [rowTags $w $p]
    }
    set G($w,hov) ""
    if {$item ne "" && [$t exists $item]} {
        set p [expr {$G($w,top) + [string range $item 1 end]}]
        if {![selContains $w $p]} {
            $t item $item -tags [list hover]
            set G($w,hov) $item
        }
    }
}
proc ::grid::rehover {w} {
    set t $w.t
    if {![winfo exists $t] || ![winfo ismapped $t]} return
    lassign [winfo pointerxy $t] px py
    set x [expr {$px - [winfo rootx $t]}] ; set y [expr {$py - [winfo rooty $t]}]
    if {$x < 0 || $y < 0 || $x >= [winfo width $t] || $y >= [winfo height $t]} return
    set item [$t identify row $x $y]
    if {$item ne ""} { hoverTo $w $item }
}

# ============================================================================
#  Keyboard
# ============================================================================
proc ::grid::key {w delta extend} {
    variable G
    if {$G($w,total) == 0} return
    set last [expr {$G($w,total) - 1}]
    set cur $G($w,cur)
    set page [expr {max(1, [visRows $w] - 1)}]
    switch -- $delta {
        HOME { set new 0 }
        END  { set new $last }
        PAGE  { set new [expr {$cur < 0 ? $page - 1 : $cur + $page}] }
        -PAGE { set new [expr {$cur < 0 ? 0 : $cur - $page}] }
        default { set new [expr {$cur < 0 ? ($delta > 0 ? 0 : $last) : $cur + $delta}] }
    }
    set new [expr {max(0, min($last, $new))}]
    editAbort $w
    if {$extend && $G($w,anchor) >= 0} {
        set a $G($w,anchor)
        set G($w,sel) [list [list [expr {min($a, $new)}] [expr {max($a, $new)}]]]
    } else {
        set G($w,sel) [list [list $new $new]]
        set G($w,anchor) $new
    }
    set G($w,cur) $new
    ensureVisible $w $new
    paintSel $w
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
proc ::grid::noteColumn {w x y} {
    variable G
    set col [$w.t identify column $x $y]
    if {[regexp {^#(\d+)$} $col -> n] && $n > 1} { set G($w,lastcol) [expr {$n - 2}] }
}

# ============================================================================
#  Sorting
# ============================================================================
proc ::grid::sortBy {w i} {
    variable G
    if {$G($w,sortcol) == $i} {
        set G($w,sortdir) [expr {$G($w,sortdir) eq "asc" ? "desc" : "asc"}]
    } else { set G($w,sortcol) $i ; set G($w,sortdir) asc }
    editAbort $w
    set cursor [$w.t cget -cursor]
    $w.t configure -cursor watch ; update idletasks
    set err [catch {{*}$G($w,src) sort $i $G($w,sortdir) [lindex $G($w,types) $i]} msg]
    $w.t configure -cursor $cursor
    if {$err} { set G($w,lasterror) $msg ; event generate $w <<GridError>> -data $msg ; return }
    # the sort moves rows, so a selection by position would now mean different rows
    set G($w,sel) {} ; set G($w,anchor) -1 ; set G($w,cur) -1 ; set G($w,top) 0
    for {set j 0} {$j < [llength $G($w,cols)]} {incr j} {
        set txt [lindex $G($w,cols) $j]
        if {$j == $i} { append txt [expr {$G($w,sortdir) eq "asc" ? "  \u25B2" : "  \u25BC"}] }
        $w.t heading c$j -text $txt
    }
    paint $w
}

# ============================================================================
#  Copy / export
# ============================================================================
# Visit rows in chunks: calls  script rows  for each chunk of the given ranges (default: all rows).
proc ::grid::eachChunk {w ranges script} {
    variable G
    foreach r $ranges {
        lassign $r lo hi
        for {set p $lo} {$p <= $hi} {incr p 2000} {
            set n [expr {min(2000, $hi - $p + 1)}]
            uplevel 1 [list {*}$script [fetchRows $w $p $n]]
        }
    }
}
proc ::grid::tsv {w headers {onlySelected 1}} {
    variable G
    set lines {}
    if {$headers} { lappend lines [join $G($w,cols) \t] }
    if {$onlySelected && [llength $G($w,sel)]} {
        set ranges $G($w,sel)
    } elseif {$G($w,total) > 0} {
        set ranges [list [list 0 [expr {$G($w,total) - 1}]]]
    } else { set ranges {} }
    foreach r $ranges {
        lassign $r lo hi
        for {set p $lo} {$p <= $hi} {incr p 2000} {
            foreach row [fetchRows $w $p [expr {min(2000, $hi - $p + 1)}]] {
                set cells {}
                foreach v $row { lappend cells [string map [list \t " " \n " " \r ""] $v] }
                lappend lines [join $cells \t]
            }
        }
    }
    return [join $lines \n]
}
proc ::grid::copy {w headers} {
    clipboard clear
    clipboard append [tsv $w $headers 1]
}
proc ::grid::copyCell {w} {
    variable G
    if {$G($w,cur) < 0} return
    clipboard clear
    clipboard append [{*}$G($w,src) cell $G($w,cur) $G($w,lastcol)]
}

proc ::grid::csvEscape {v} {
    if {[regexp {[",\n\r]} $v]} { return "\"[string map {\" \"\"} $v]\"" }
    return $v
}
proc ::grid::lmap_csv {l} { set r {} ; foreach v $l { lappend r [csvEscape $v] } ; return $r }
# Streams every row to the file, so a 500,000-row view never has to fit in memory twice.
proc ::grid::exportCsv {w} {
    variable G
    if {![hasData $w]} return
    set f [tk_getSaveFile -title "Export results as CSV" -defaultextension .csv \
        -filetypes {{{CSV files} .csv} {{All files} *}}]
    if {$f eq ""} return
    set out [open $f w]
    fconfigure $out -encoding utf-8
    puts $out [join [lmap_csv $G($w,cols)] ,]
    set done 0
    for {set p 0} {$p < $G($w,total)} {incr p 2000} {
        foreach row [fetchRows $w $p [expr {min(2000, $G($w,total) - $p)}]] { puts $out [join [lmap_csv $row] ,] }
        incr done 2000
        if {[info commands ::app::setStatus] ne ""} { ::app::setStatus "Exporting... [::app::commas [expr {min($done, $G($w,total))}]] of [::app::commas $G($w,total)] rows" warn ; update idletasks }
    }
    close $out
    return $f
}

# ============================================================================
#  Context menu, hover cursor
# ============================================================================
proc ::grid::popupMenu {w x y X Y} {
    variable G
    set p [posAt $w $y]
    if {$p ne "" && ![selContains $w $p]} {
        set G($w,sel) [list [list $p $p]] ; set G($w,anchor) $p ; set G($w,cur) $p
        paintSel $w
    }
    noteColumn $w $x $y
    set m $w.menu
    catch {destroy $m}
    menu $m -tearoff 0
    ::theme::menu $m
    $m add command -label "Copy" -accelerator Ctrl+C -command [list ::grid::copy $w 0]
    $m add command -label "Copy with Headers" -accelerator Ctrl+Shift+C -command [list ::grid::copy $w 1]
    $m add command -label "Copy Cell" -command [list ::grid::copyCell $w]
    $m add separator
    $m add command -label "Select All" -accelerator Ctrl+A -command [list ::grid::selectAll $w]
    $m add command -label "Export as CSV\u2026" -command [list ::grid::exportCsv $w]
    if {$G($w,-editable)} {
        $m add separator
        $m add command -label "Edit Cell" -accelerator F2 -command [list ::grid::editCurrent $w]
        $m add command -label "Delete Row(s)" -accelerator Del -command [list event generate $w <<GridDelete>>]
    }
    ::menus::post $m $X $Y
}
proc ::grid::keyMenu {w} {
    variable G
    if {$G($w,cur) < 0} return
    set k [expr {$G($w,cur) - $G($w,top)}]
    if {$k < 0 || $k >= $G($w,attached)} return
    lassign [$w.t bbox s$k] x y cw ch
    popupMenu $w $x $y [expr {[winfo rootx $w.t] + $x + 24}] [expr {[winfo rooty $w.t] + $y + $ch}]
}

# hand cursor over subview cells, which open on double-click; row hover
proc ::grid::motion {w x y} {
    variable G
    set cursor ""
    if {[$w.t identify region $x $y] eq "cell" && [regexp {^#(\d+)$} [$w.t identify column $x $y] -> n] && $n > 1} {
        if {[dict exists $G($w,drill) [expr {$n - 2}]]} { set cursor hand2 }
    }
    if {[$w.t cget -cursor] ne $cursor} { $w.t configure -cursor $cursor }
    hoverTo $w [$w.t identify row $x $y]
}

# ============================================================================
#  Editing / drill-down
# ============================================================================
proc ::grid::doubleClick {w x y} {
    variable G
    if {[$w.t identify region $x $y] ne "cell"} return
    set p [posAt $w $y]
    set col [$w.t identify column $x $y]
    if {$p eq "" || ![regexp {^#(\d+)$} $col -> n] || $n < 2} return
    set ci [expr {$n - 2}]
    if {[dict exists $G($w,drill) $ci]} {
        if {$G($w,-drill) ne ""} {
            set id [{*}$G($w,src) rowid $p]
            if {$id ne ""} { uplevel #0 [list {*}$G($w,-drill) $id [dict get $G($w,drill) $ci]] }
        }
        return
    }
    if {$G($w,-editable)} { edit $w $p $ci }
}
proc ::grid::editCurrent {w} {
    variable G
    if {!$G($w,-editable) || $G($w,cur) < 0} return
    if {[dict exists $G($w,drill) $G($w,lastcol)]} return
    edit $w $G($w,cur) $G($w,lastcol)
}

proc ::grid::edit {w p ci} {
    variable G
    set t $w.t
    ensureVisible $w $p
    update idletasks
    set k [expr {$p - $G($w,top)}]
    if {$k < 0 || $k >= $G($w,attached)} return
    set bb [$t bbox s$k c$ci]
    if {$bb eq ""} return
    lassign $bb x y cw ch
    catch {destroy $t.edit}
    set G($w,editval) [{*}$G($w,src) cell $p $ci]
    set G($w,editing) [list $p $ci]
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
# an edit is open and the user clicked another row: accept it first
proc ::grid::editDoneIfOther {w p} {
    variable G
    if {$G($w,editing) ne "" && [lindex $G($w,editing) 0] != $p} { editDone $w 1 none }
}
proc ::grid::editAbort {w} {
    variable G
    if {$G($w,editing) eq ""} return
    set G($w,editing) ""
    catch {bind $w.t.edit <FocusOut> {}}
    catch {destroy $w.t.edit}
}

proc ::grid::editDone {w accept move} {
    variable G
    set t $w.t
    if {$G($w,editing) eq ""} return
    lassign $G($w,editing) p ci
    set new $G($w,editval)
    set old [{*}$G($w,src) cell $p $ci]
    set G($w,editing) ""
    bind $t.edit <FocusOut> {}
    set ok 1
    if {$accept && $new ne $old} {
        set rowid [{*}$G($w,src) rowid $p]
        set col [lindex $G($w,cols) $ci]
        if {[catch {uplevel #0 [list {*}$G($w,-commit) $rowid $col $new]} err]} {
            set ok 0
            event generate $w <<GridError>> -data $err
            set G($w,lasterror) $err
        } else {
            {*}$G($w,src) put $p $ci $new
            set k [expr {$p - $G($w,top)}]
            if {$k >= 0 && $k < $G($w,attached)} { $t set s$k c$ci [display $new] }
        }
    }
    destroy $t.edit
    focus $t
    if {!$ok} return
    switch -- $move {
        down  { if {$p + 1 < $G($w,total)} { select1 $w [expr {$p + 1}] ; edit $w [expr {$p + 1}] $ci } }
        right { if {$ci + 1 < [llength $G($w,cols)]} { set G($w,lastcol) [expr {$ci + 1}] ; edit $w $p [expr {$ci + 1}] } }
        left  { if {$ci > 0} { set G($w,lastcol) [expr {$ci - 1}] ; edit $w $p [expr {$ci - 1}] } }
    }
}
proc ::grid::select1 {w p} {
    variable G
    set G($w,sel) [list [list $p $p]] ; set G($w,anchor) $p ; set G($w,cur) $p
    ensureVisible $w $p
    paintSel $w
}
