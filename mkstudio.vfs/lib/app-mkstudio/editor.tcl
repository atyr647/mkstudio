# editor.tcl -- the MKQL query editor: line numbers, syntax highlighting,
# current-line marker, auto-indent, comment toggle, error marking, completion.
#
#   ::editor::create w ?-poscmd cmd? ?-modcmd cmd? ?-runcmd cmd? ?-completer cmd?
#   the text widget is  $w.t

namespace eval ::editor {
    variable E
    array set E {}
    variable fontSize 11
}

proc ::editor::create {w args} {
    variable E
    array set o {-poscmd {} -modcmd {} -runcmd {} -completer {}}
    array set o $args
    foreach k [array names o] { set E($w,$k) $o($k) }
    set E($w,nlines) 0 ; set E($w,hl) "" ; set E($w,popup) ""

    ttk::frame $w -style Editor.TFrame
    text $w.g -width 4 -takefocus 0 -cursor arrow -state disabled -wrap none -font MkMono \
        -borderwidth 0 -highlightthickness 0 -padx 8 -pady 8 -spacing1 2 -spacing3 2 -insertwidth 0
    text $w.t -wrap none -undo 1 -maxundo 500 -font MkMono -borderwidth 0 -highlightthickness 0 \
        -padx 10 -pady 8 -spacing1 2 -spacing3 2 -insertwidth 2 -tabs {32} \
        -yscrollcommand [list ::editor::yscroll $w] -xscrollcommand [list $w.h set]
    ttk::scrollbar $w.v -orient vertical -command [list ::editor::yview $w]
    ttk::scrollbar $w.h -orient horizontal -command [list $w.t xview]
    grid $w.g -row 0 -column 0 -sticky ns
    grid $w.t -row 0 -column 1 -sticky nsew
    grid $w.v -row 0 -column 2 -sticky ns
    grid $w.h -row 1 -column 1 -sticky ew
    grid rowconfigure $w 0 -weight 1 ; grid columnconfigure $w 1 -weight 1
    $w.g tag configure r -justify right

    ::theme::reg $w.t [list ::editor::recolor %w]
    applyFont $w

    set t $w.t
    bind $t <<Modified>>    [list ::editor::modified $w]
    bind $t <KeyRelease>    [list ::editor::cursorMoved $w]
    bind $t <ButtonRelease-1> [list ::editor::cursorMoved $w]
    bind $t <Tab>           "[list ::editor::indent $w 1] ; break"
    bind $t <ISO_Left_Tab>  "[list ::editor::indent $w -1] ; break"
    bind $t <Shift-Tab>     "[list ::editor::indent $w -1] ; break"
    bind $t <Return>        "[list ::editor::newline $w] ; break"
    bind $t <KP_Enter>      "[list ::editor::newline $w] ; break"
    bind $t <Control-slash> "[list ::editor::toggleComment $w] ; break"
    bind $t <Control-space> "[list ::editor::complete $w] ; break"
    bind $t <Control-a>     "$t tag add sel 1.0 end-1c ; $t mark set insert end-1c ; break"
    bind $t <Control-y>     "[list event generate $t <<Redo>>] ; break"
    bind $t <Control-d>     "[list ::editor::duplicateLine $w] ; break"
    bind $t <<Paste>>       "[list ::editor::paste $w] ; break"
    bind $t <Button-3>      [list ::editor::menu $w %X %Y]
    bind $t <Control-MouseWheel> [list ::editor::zoomWheel $w %D]
    bind $t <Control-Button-4>   "[list ::editor::zoom $w 1] ; break"
    bind $t <Control-Button-5>   "[list ::editor::zoom $w -1] ; break"
    bind $t <Escape>        [list ::editor::closePopup $w]
    bind $t <FocusOut>      [list ::editor::closePopup $w]
    bind $w <Destroy>       [list ::editor::forget $w]
    $t edit modified 0
    modified $w
    return $w
}
proc ::editor::forget {w} {
    variable E
    foreach k [array names E $w,*] { unset E($k) }
}

proc ::editor::applyFont {w} {
    variable fontSize
    font configure MkMono -size $fontSize
}
proc ::editor::zoom {w dir} {
    variable fontSize
    set n [expr {$fontSize + $dir}]
    if {$n < 7 || $n > 28} return
    set fontSize $n
    font configure MkMono -size $n
}
proc ::editor::zoomWheel {w d} { zoom $w [expr {$d > 0 ? 1 : -1}] ; return -code break }
proc ::editor::zoomReset {} {
    variable fontSize ; set fontSize 11 ; font configure MkMono -size 11
}

proc ::editor::recolor {t} {
    set w [winfo parent $t]
    set c(x) 0
    $t configure -background $::theme::c(editor) -foreground $::theme::c(fg) \
        -insertbackground $::theme::c(accent) -selectbackground $::theme::c(sel) \
        -selectforeground $::theme::c(selFg) -inactiveselectbackground $::theme::c(sel)
    $w.g configure -background $::theme::c(editor) -foreground $::theme::c(gutter) \
        -selectbackground $::theme::c(editor) -selectforeground $::theme::c(gutter)
    $w.g tag configure cur -foreground $::theme::c(fg)
    $t tag configure curline -background $::theme::c(curline)
    $t tag configure kw -foreground $::theme::c(kw)
    $t tag configure str -foreground $::theme::c(str)
    $t tag configure num -foreground $::theme::c(num)
    $t tag configure fn -foreground $::theme::c(fn)
    $t tag configure type -foreground $::theme::c(type)
    $t tag configure op -foreground $::theme::c(op)
    $t tag configure comment -foreground $::theme::c(comment)
    $t tag configure err -underline 1 -foreground $::theme::c(bad) -background $::theme::c(errbg)
    $t tag lower curline
    $t tag raise sel
    foreach tg {kw str num fn type op comment err} { $t tag raise $tg curline }
    $t tag raise sel err
}

# ---- scrolling / gutter -----------------------------------------------------------
proc ::editor::yscroll {w first last} {
    $w.v set $first $last
    $w.g yview moveto $first
}
proc ::editor::yview {w args} {
    $w.t yview {*}$args
    $w.g yview moveto [lindex [$w.t yview] 0]
}
proc ::editor::updateGutter {w} {
    variable E
    set n [lindex [split [$w.t index end-1c] .] 0]
    if {$n == $E($w,nlines)} return
    set E($w,nlines) $n
    set digits [expr {max(3, [string length $n])}]
    $w.g configure -width $digits -state normal
    $w.g delete 1.0 end
    set txt {}
    for {set i 1} {$i <= $n} {incr i} { lappend txt $i }
    $w.g insert 1.0 [join $txt \n] r
    $w.g configure -state disabled
    $w.g yview moveto [lindex [$w.t yview] 0]
}

proc ::editor::modified {w} {
    variable E
    if {![winfo exists $w.t]} return
    if {![$w.t edit modified]} return
    $w.t edit modified 0
    $w.t tag remove err 1.0 end
    updateGutter $w
    if {$E($w,hl) ne ""} { after cancel $E($w,hl) }
    set E($w,hl) [after 50 [list ::editor::highlight $w]]
    cursorMoved $w
    if {$E($w,popup) ne ""} { after idle [list ::editor::complete $w 1] }
    if {$E($w,-modcmd) ne ""} { uplevel #0 $E($w,-modcmd) }
}

proc ::editor::cursorMoved {w} {
    variable E
    set t $w.t
    $t tag remove curline 1.0 end
    set line [lindex [split [$t index insert] .] 0]
    if {[llength [$t tag ranges sel]] == 0} { $t tag add curline $line.0 [expr {$line+1}].0 }
    $w.g tag remove cur 1.0 end
    $w.g tag add cur $line.0 $line.end
    if {$E($w,-poscmd) ne ""} {
        lassign [split [$t index insert] .] l c
        uplevel #0 [list {*}$E($w,-poscmd) $l [expr {$c + 1}]]
    }
}

# ---- highlighting -----------------------------------------------------------------
proc ::editor::highlight {w} {
    variable E
    set E($w,hl) ""
    if {![winfo exists $w.t]} return
    set t $w.t
    foreach tg {kw str num fn type op comment} { $t tag remove $tg 1.0 end }
    set text [$t get 1.0 end-1c]
    set kinds {comment comment str str num kw {} {}}
    # same lexer as the engine: comment | block comment | string | "ident" | number | word | operator
    foreach {all g1 g2 g3 g4 g5 g6 g7 g8} [regexp -all -inline -indices $::mkql::tokenRe $text] {
        set k 0
        foreach g [list $g1 $g2 $g3 $g4 $g5 $g6 $g7 $g8] {
            if {[lindex $g 0] >= 0} break
            incr k
        }
        lassign $all s e
        set tag ""
        switch -- $k {
            0 - 1 { set tag comment }
            2     { set tag str }
            3     { set tag ident }
            4     { set tag num }
            5     {
                set word [string toupper [string range $text $s $e]]
                if {[lsearch -exact $::mkql::keywords $word] >= 0} { set tag kw
                } elseif {[lsearch -exact $::mkql::aggs $word] >= 0 || [lsearch -exact $::mkql::functions $word] >= 0} { set tag fn
                } elseif {[lsearch -exact {STRING TEXT INT INTEGER LONG BIGINT FLOAT REAL DOUBLE BYTES BLOB} $word] >= 0} { set tag type }
            }
            6     { set tag op }
        }
        if {$tag eq "" || $tag eq "ident"} continue
        $t tag add $tag "1.0 + ${s}c" "1.0 + [expr {$e + 1}]c"
    }
}

proc ::editor::markError {w pos len} {
    set t $w.t
    $t tag remove err 1.0 end
    set a [$t index "1.0 + ${pos}c"]
    set b [$t index "1.0 + [expr {$pos + max($len,1)}]c"]
    if {[$t compare $a == $b]} { set a [$t index "$a - 1c"] }
    $t tag add err $a $b
    $t mark set insert $a
    $t see $a
}

# ---- editing helpers -----------------------------------------------------------------
proc ::editor::newline {w} {
    set t $w.t
    if {[llength [$t tag ranges sel]]} { $t delete sel.first sel.last }
    set line [$t get "insert linestart" "insert lineend"]
    regexp {^[ \t]*} $line ws
    # indent to just the cursor column if the cursor is inside the indentation
    set col [lindex [split [$t index insert] .] 1]
    if {$col < [string length $ws]} { set ws [string range $ws 0 $col-1] }
    $t insert insert "\n$ws"
    $t see insert
}

proc ::editor::selLines {w} {
    set t $w.t
    if {[llength [$t tag ranges sel]]} {
        set a [lindex [split [$t index sel.first] .] 0]
        set b [lindex [split [$t index sel.last] .] 0]
        if {[lindex [split [$t index sel.last] .] 1] == 0 && $b > $a} { incr b -1 }
    } else {
        set a [set b [lindex [split [$t index insert] .] 0]]
    }
    return [list $a $b]
}

proc ::editor::indent {w dir} {
    set t $w.t
    set hasSel [llength [$t tag ranges sel]]
    if {$dir > 0 && !$hasSel} { $t insert insert "    " ; return }
    lassign [selLines $w] a b
    $t edit separator
    for {set l $a} {$l <= $b} {incr l} {
        if {$dir > 0} {
            $t insert $l.0 "    "
        } else {
            set s [$t get $l.0 $l.end]
            regexp {^ {1,4}|^\t} $s ws
            if {[info exists ws] && $ws ne ""} { $t delete $l.0 "$l.0 + [string length $ws]c" }
            unset -nocomplain ws
        }
    }
    $t edit separator
    if {$hasSel} { $t tag add sel $a.0 [expr {$b+1}].0 }
}

proc ::editor::toggleComment {w} {
    set t $w.t
    lassign [selLines $w] a b
    set all 1
    for {set l $a} {$l <= $b} {incr l} {
        set s [$t get $l.0 $l.end]
        if {[string trim $s] ne "" && ![regexp {^\s*--} $s]} { set all 0 }
    }
    $t edit separator
    for {set l $a} {$l <= $b} {incr l} {
        set s [$t get $l.0 $l.end]
        if {[string trim $s] eq ""} continue
        if {$all} {
            regexp {^(\s*)-- ?(.*)$} $s -> ws rest
            $t delete $l.0 $l.end
            $t insert $l.0 $ws$rest
        } else {
            regexp {^(\s*)} $s -> ws
            $t insert "$l.0 + [string length $ws]c" "-- "
        }
    }
    $t edit separator
}

proc ::editor::duplicateLine {w} {
    set t $w.t
    set l [lindex [split [$t index insert] .] 0]
    set s [$t get $l.0 $l.end]
    $t insert $l.end "\n$s"
}

proc ::editor::paste {w} {
    set t $w.t
    if {[catch {clipboard get} s]} return
    $t edit separator
    if {[llength [$t tag ranges sel]]} { $t delete sel.first sel.last }
    $t insert insert $s
    $t see insert
    $t edit separator
}

# ---- text access ------------------------------------------------------------------------
proc ::editor::get {w} { $w.t get 1.0 end-1c }
proc ::editor::setText {w s} {
    $w.t delete 1.0 end
    $w.t insert 1.0 $s
    $w.t edit reset
    $w.t edit modified 0
    modified $w
    $w.t edit modified 1
    modified $w
    $w.t mark set insert 1.0
}
proc ::editor::insertText {w s} {
    $w.t insert insert $s
    $w.t see insert
    focus $w.t
}
# {text offset} for the selection, or the whole buffer
proc ::editor::runText {w} {
    set t $w.t
    if {[llength [$t tag ranges sel]]} {
        set off [string length [$t get 1.0 sel.first]]
        return [list [$t get sel.first sel.last] $off]
    }
    return [list [get $w] 0]
}

proc ::editor::menu {w X Y} {
    variable E
    set t $w.t
    set m $w.menu
    catch {destroy $m}
    menu $m -tearoff 0
    ::theme::menu $m
    if {$E($w,-runcmd) ne ""} {
        $m add command -label "Execute" -accelerator F5 -command $E($w,-runcmd)
        $m add separator
    }
    $m add command -label "Cut" -accelerator Ctrl+X -command [list event generate $t <<Cut>>]
    $m add command -label "Copy" -accelerator Ctrl+C -command [list event generate $t <<Copy>>]
    $m add command -label "Paste" -accelerator Ctrl+V -command [list event generate $t <<Paste>>]
    $m add separator
    $m add command -label "Select All" -accelerator Ctrl+A -command [list $t tag add sel 1.0 end-1c]
    $m add command -label "Toggle Comment" -accelerator Ctrl+/ -command [list ::editor::toggleComment $w]
    tk_popup $m $X $Y
}

# ---- completion ---------------------------------------------------------------------------
proc ::editor::complete {w {auto 0}} {
    variable E
    set t $w.t
    closePopup $w
    if {$E($w,-completer) eq ""} return
    set before [$t get "insert linestart" insert]
    regexp {[A-Za-z_][A-Za-z0-9_]*$} $before prefix
    if {![info exists prefix]} { set prefix "" }
    if {$auto && $prefix eq ""} return
    set ctx [$t get 1.0 insert]
    set all [uplevel #0 [list {*}$E($w,-completer) $ctx [get $w]]]
    set items {}
    foreach it $all {
        if {$prefix eq "" || [string match -nocase $prefix* [lindex $it 0]]} { lappend items $it }
    }
    if {![llength $items]} return
    if {[llength $items] == 1 && [lindex $items 0 0] eq $prefix} return
    set E($w,items) $items ; set E($w,prefix) $prefix
    set p .complete
    catch {destroy $p}
    toplevel $p -background $::theme::c(border)
    wm overrideredirect $p 1
    catch {wm attributes $p -topmost 1}
    listbox $p.l -font MkMono -background $::theme::c(raised) -foreground $::theme::c(fg) \
        -selectbackground $::theme::c(accent) -selectforeground $::theme::c(accentFg) \
        -borderwidth 0 -highlightthickness 0 -activestyle none -exportselection 0 \
        -height [expr {min(10, [llength $items])}] -width 30
    pack $p.l -padx 1 -pady 1
    foreach it $items { $p.l insert end [format "%-26s %s" [lindex $it 0] [lindex $it 1]] }
    $p.l selection set 0
    set bb [$t bbox insert]
    if {$bb eq ""} { set bb {0 0 0 0} }
    wm geometry $p +[expr {[winfo rootx $t] + [lindex $bb 0] - [font measure MkMono $prefix]}]+[expr {[winfo rooty $t] + [lindex $bb 1] + [lindex $bb 3] + 2}]
    set E($w,popup) $p
    bind $p.l <Double-1> [list ::editor::accept $w]
    # keyboard handling while the popup is open
    bind $t <Down>   "[list ::editor::popupMove $w 1] ; break"
    bind $t <Up>     "[list ::editor::popupMove $w -1] ; break"
    bind $t <Return> "[list ::editor::accept $w] ; break"
    bind $t <Tab>    "[list ::editor::accept $w] ; break"
}
proc ::editor::popupMove {w d} {
    variable E
    set l $E($w,popup).l
    set cur [lindex [$l curselection] 0]
    set n [expr {max(0, min([$l size] - 1, $cur + $d))}]
    $l selection clear 0 end ; $l selection set $n ; $l see $n
}
proc ::editor::accept {w} {
    variable E
    set t $w.t
    set l $E($w,popup).l
    set i [lindex [$l curselection] 0]
    set word [lindex $E($w,items) $i 0]
    set prefix $E($w,prefix)
    closePopup $w
    if {$prefix ne ""} { $t delete "insert - [string length $prefix]c" insert }
    $t insert insert $word
}
proc ::editor::closePopup {w} {
    variable E
    if {![info exists E($w,popup)] || $E($w,popup) eq ""} return
    catch {destroy $E($w,popup)}
    set E($w,popup) ""
    set t $w.t
    # restore the normal key bindings
    bind $t <Down> {} ; bind $t <Up> {}
    bind $t <Return> "[list ::editor::newline $w] ; break"
    bind $t <Tab>    "[list ::editor::indent $w 1] ; break"
}
