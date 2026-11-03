# widgets.tcl -- small reusable UI pieces: tooltips, themed dialogs, the tab strip.

# ============================================================================
#  Tooltips
# ============================================================================
namespace eval ::tip {
    variable after ""
    variable text
    array set text {}
}
proc ::tip::attach {w msg} {
    variable text
    set text($w) $msg
    bind $w <Enter> [list ::tip::schedule %W]
    bind $w <Leave> [list ::tip::hide]
    bind $w <ButtonPress> [list ::tip::hide]
}
proc ::tip::update_ {w msg} { variable text ; set text($w) $msg }
proc ::tip::schedule {w} {
    variable after
    ::tip::hide
    set after [after 550 [list ::tip::show $w]]
}
proc ::tip::show {w} {
    variable text
    if {![winfo exists $w] || ![info exists text($w)]} return
    set t .tooltip
    catch {destroy $t}
    toplevel $t -background $::theme::c(border)
    wm overrideredirect $t 1
    catch {wm attributes $t -topmost 1}
    label $t.l -text $text($w) -background $::theme::c(raised) -foreground $::theme::c(fg) \
        -font MkSmall -padx 8 -pady 4 -justify left
    pack $t.l -padx 1 -pady 1
    set x [expr {[winfo rootx $w] + 8}]
    set y [expr {[winfo rooty $w] + [winfo height $w] + 6}]
    wm geometry $t +$x+$y
}
proc ::tip::hide {} {
    variable after
    if {$after ne ""} { after cancel $after ; set after "" }
    catch {destroy .tooltip}
}

# ============================================================================
#  Themed dialogs
# ============================================================================
namespace eval ::ui {
    variable result ""
    variable seq 0
}

proc ::ui::center {w {parent .}} {
    update idletasks
    set pw [winfo width $parent] ; set ph [winfo height $parent]
    if {$pw < 50} { set pw [winfo screenwidth .] ; set ph [winfo screenheight .] }
    set x [expr {[winfo rootx $parent] + ($pw - [winfo reqwidth $w]) / 2}]
    set y [expr {[winfo rooty $parent] + ($ph - [winfo reqheight $w]) / 3}]
    wm geometry $w +[expr {max($x,0)}]+[expr {max($y,0)}]
}

# Build a modal dialog skeleton:  $w.head (title), $w.body (content), $w.bar (buttons).
proc ::ui::modal {title} {
    variable seq
    set w .dlg[incr seq]
    toplevel $w -background $::theme::c(surface) -highlightthickness 1 \
        -highlightbackground $::theme::c(border) -highlightcolor $::theme::c(border)
    wm title $w $title
    wm transient $w .
    wm resizable $w 0 0
    ttk::label $w.head -text $title -style Title.TLabel -padding {24 20 24 0}
    ttk::frame $w.body -style Surface.TFrame -padding {24 12 24 20}
    ttk::frame $w.line -style Line.TFrame -height 1
    ttk::frame $w.bar -style Panel.TFrame -padding {16 12}
    pack $w.head -side top -fill x
    pack $w.bar -side bottom -fill x
    pack $w.line -side bottom -fill x
    pack $w.body -side top -fill both -expand 1
    return $w
}

proc ::ui::run {w {focus ""}} {
    variable result
    set result ""
    center $w
    update idletasks
    catch {grab $w}
    if {$focus ne ""} { focus $focus } else { focus $w }
    bind $w <Escape> [list set ::ui::result ""]
    wm protocol $w WM_DELETE_WINDOW [list set ::ui::result ""]
    vwait ::ui::result
    catch {grab release $w}
    destroy $w
    return $::ui::result
}

# Destructive verbs get the red button style.
proc ::ui::buttonStyle {label primary} {
    if {!$primary} { return TButton }
    if {$label in {Delete Drop Discard "Roll Back" "Don't Save"}} { return Danger.TButton }
    return Accent.TButton
}

# ask "Title" "Message" {Primary Other Cancel} ?icon?  ->  the label clicked ("" if closed).
# Buttons are laid out left to right as given; the first is the default.
proc ::ui::ask {title message {buttons {OK}} {icon ""}} {
    set w [modal $title]
    if {$icon ne ""} {
        ttk::label $w.body.i -image [::icons::big $icon] -style Surface.TLabel
        grid $w.body.i -row 0 -column 0 -sticky n -padx {0 18}
    }
    ttk::label $w.body.m -text $message -style Surface.TLabel -wraplength [::theme::px 400] -justify left
    grid $w.body.m -row 0 -column 1 -sticky nw
    set first ""
    set i 0
    foreach b $buttons {
        set btn $w.bar.b$i
        ttk::button $btn -text $b -width 10 -style [buttonStyle $b [expr {$i == 0}]] \
            -command [list set ::ui::result $b]
        if {$i == 0} { set first $btn }
        incr i
    }
    # right-align the row of buttons, preserving their order
    for {set j [expr {$i - 1}]} {$j >= 0} {incr j -1} { pack $w.bar.b$j -side right -padx {8 0} }
    bind $w <Return> [list set ::ui::result [lindex $buttons 0]]
    return [run $w $first]
}
proc ::ui::inform {title message} { ask $title $message OK info }
proc ::ui::problem {message {title "Something went wrong"}} { ask $title $message OK error }

# form "Title" {{key "Label" entry default} {key "Label" combo default {values}} {key "Label" check 0}} ?okText? ?validate? ?intro?
# Returns {ok dict} or "" when cancelled (use ::ui::formResult to unwrap).  The
# validator is called with the dict and returns "" or a message shown in the dialog.
proc ::ui::form {title fields {okText OK} {validate ""} {intro ""}} {
    variable result
    set w [modal $title]
    set row 0
    if {$intro ne ""} {
        ttk::label $w.body.intro -text $intro -style SurfaceDim.TLabel -wraplength [::theme::px 380] -justify left
        grid $w.body.intro -row $row -column 0 -columnspan 2 -sticky w -pady {0 14}
        incr row
    }
    set first ""
    array unset ::ui::F
    foreach f $fields {
        lassign $f key label kind default values
        set ::ui::F($key) $default
        if {$kind eq "check"} {
            ttk::checkbutton $w.body.e$key -variable ::ui::F($key) -text $label -style Surface.TCheckbutton
            grid $w.body.e$key -row $row -column 0 -columnspan 2 -sticky w -pady {8 4}
        } else {
            ttk::label $w.body.l$key -text $label -style Surface.TLabel
            grid $w.body.l$key -row $row -column 0 -sticky w -padx {0 16} -pady 6
            if {$kind eq "combo"} {
                ttk::combobox $w.body.e$key -textvariable ::ui::F($key) -values $values -state readonly -width 30
            } else {
                ttk::entry $w.body.e$key -textvariable ::ui::F($key) -width 32
            }
            grid $w.body.e$key -row $row -column 1 -sticky we -pady 6
        }
        if {$first eq ""} { set first $w.body.e$key }
        incr row
    }
    ttk::label $w.body.err -text "" -style Error.TLabel -wraplength [::theme::px 380]
    grid $w.body.err -row $row -column 0 -columnspan 2 -sticky w -pady {8 0}
    grid columnconfigure $w.body 1 -weight 1

    set ok [list ::ui::formOk $w $fields $validate]
    ttk::button $w.bar.ok -text $okText -width 10 -style Accent.TButton -command $ok
    ttk::button $w.bar.cancel -text Cancel -width 10 -command {set ::ui::result ""}
    pack $w.bar.cancel -side right -padx {8 0}
    pack $w.bar.ok -side right
    bind $w <Return> $ok
    if {[winfo class $first] eq "TEntry"} { $first selection range 0 end ; $first icursor end }
    return [run $w $first]
}
proc ::ui::formOk {w fields validate} {
    set d {}
    foreach f $fields { dict set d [lindex $f 0] [string trim $::ui::F([lindex $f 0])] }
    if {$validate ne ""} {
        set msg [{*}$validate $d]
        if {$msg ne ""} { $w.body.err configure -text "\u2716  $msg" ; return }
    }
    set ::ui::result [list ok $d]
}
# unwrap the {ok dict} produced by form
proc ::ui::formResult {r} { if {$r eq ""} { return "" } ; return [lindex $r 1] }

# Bind a sequence that may not exist on every windowing system (for example the X11
# keysym ISO_Left_Tab, which Tk on Windows and macOS rejects with "bad event type or
# keysym").  Returns 1 if the binding was made.  An unguarded bind of such a key
# made the whole app fail at start-up on Windows and macOS.
proc ::ui::bindSafe {w seq script} {
    return [expr {![catch {bind $w $seq $script}]}]
}

# Bind Ctrl+<key>, and on macOS Command+<key> as well (Command is the platform's
# primary modifier there; Control keeps working too).
proc ::ui::bindMod {w key script} {
    bind $w <Control-$key> $script
    if {[tk windowingsystem] eq "aqua"} { bind $w <Command-$key> $script }
}
# Shortcut text as the platform writes it.
proc ::ui::accel {text} {
    if {[tk windowingsystem] eq "aqua"} { return [string map {Ctrl+ Cmd+} $text] }
    return $text
}

# ---- row hover for treeviews ------------------------------------------------------
# The "hover" tag must be the FIRST tag configured on the tree (in Tk 8.6 the
# earliest-configured tag wins when several set the same option).
proc ::ui::hoverTree {t} {
    $t tag configure hover -background $::theme::c(hover)
    ::theme::reg $t {%w tag configure hover -background $::theme::c(hover)}
    bind $t <Motion> {+::ui::hoverMove %W %x %y}
    bind $t <Leave>  {+::ui::hoverMove %W -1 -1}
}
proc ::ui::hoverMove {t x y} {
    variable hov
    set item [expr {$x < 0 ? "" : [$t identify item $x $y]}]
    if {[info exists hov($t)] && $hov($t) eq $item} return
    if {[info exists hov($t)] && $hov($t) ne "" && [$t exists $hov($t)]} { $t tag remove hover $hov($t) }
    set hov($t) $item
    if {$item ne ""} { $t tag add hover $item }
}

# ---- placeholder text for entries and comboboxes ------------------------------------
proc ::ui::placeholder {e var text} {
    set l $e.ph
    label $l -text $text -font MkUI -borderwidth 0 -padx 0 -pady 0 -cursor xterm
    ::theme::reg $l {%w configure -background $::theme::c(editor) -foreground $::theme::c(faint)}
    bind $l <Button-1> [list focus $e]
    trace add variable $var write [list ::ui::placeholderSync $e $var]
    placeholderSync $e $var
}
proc ::ui::placeholderSync {e var args} {
    if {![winfo exists $e.ph]} return
    if {[set $var] eq ""} { place $e.ph -x 8 -rely 0.5 -anchor w } else { place forget $e.ph }
}

# ============================================================================
#  Tab strip
# ============================================================================
# A flat, closable tab strip.  Pages are managed by the owner: the strip only
# reports clicks via -select and -close callbacks (each called with the id).
namespace eval ::tabs {
    variable S
    array set S {}
}

proc ::tabs::create {w args} {
    variable S
    array set o {-select {} -close {} -small 0 -closable 1 -list 0 -bg bg}
    array set o $args
    set S($w,opts) [array get o]
    set S($w,ids) {} ; set S($w,sel) "" ; set S($w,hover) ""
    set h [expr {max([::theme::px [expr {$o(-small) ? 28 : 34}]], [font metrics MkUI -linespace] + [::theme::px 16])}]
    frame $w -height $h -borderwidth 0 -highlightthickness 0
    pack propagate $w 0
    frame $w.line -height 1 -borderwidth 0
    place $w.line -relx 0 -rely 1.0 -relwidth 1 -anchor sw -height 1
    if {$o(-list)} {
        label $w.more -text "\u25BE" -padx 10 -borderwidth 0 -cursor hand2
        pack $w.more -side right -fill y
        bind $w.more <Button-1> [list ::tabs::listMenu $w %X %Y]
        ::tip::attach $w.more "Active documents"
    }
    ::theme::reg $w [list ::tabs::paint %w]
    bind $w <Destroy> [list ::tabs::forget %W]
    return $w
}
proc ::tabs::forget {w} {
    variable S
    foreach k [array names S $w,*] { unset S($k) }
}
proc ::tabs::opt {w name} { variable S ; array set o $S($w,opts) ; return $o($name) }
proc ::tabs::ids {w} { variable S ; return $S($w,ids) }
proc ::tabs::current {w} { variable S ; return $S($w,sel) }
proc ::tabs::exists {w id} { variable S ; expr {[lsearch -exact $S($w,ids) $id] >= 0} }

proc ::tabs::add {w id title {icon ""}} {
    variable S
    set t $w.t$id
    set S($w,title,$id) $title ; set S($w,dirty,$id) 0 ; set S($w,icon,$id) $icon
    frame $t -borderwidth 0 -highlightthickness 0 -cursor arrow
    frame $t.bar -height 2 -borderwidth 0
    label $t.i -borderwidth 0 -padx 0
    if {$icon ne ""} { $t.i configure -image [::icons::get $icon] }
    label $t.l -text $title -font [expr {[opt $w -small] ? "MkSmall" : "MkUI"}] -borderwidth 0 -padx 6 -pady 0
    pack $t.bar -side top -fill x
    pack $t.i -side left -padx {10 0}
    pack $t.l -side left
    if {[opt $w -closable]} {
        label $t.x -image [::icons::get closex] -borderwidth 0 -padx 4
        pack $t.x -side left -padx {0 6}
        bind $t.x <Button-1> [list ::tabs::requestClose $w $id]
        bind $t.x <Enter> "[list ::tabs::hover $w $id] ; [list $t.x configure -image [::icons::get closexh]]"
        bind $t.x <Leave> [list ::tabs::hover $w ""]
    } else {
        pack $t.l -padx {0 12}
    }
    pack $t -side left -fill y
    # keep the "more" button on the far right
    foreach p [list $t $t.bar $t.i $t.l] {
        bind $p <Button-1> [list ::tabs::click $w $id]
        bind $p <ButtonRelease-2> [list ::tabs::requestClose $w $id]
        bind $p <Enter> [list ::tabs::hover $w $id]
        bind $p <Leave> [list ::tabs::hover $w ""]
    }
    lappend S($w,ids) $id
    paint $w
}
proc ::tabs::click {w id} { select $w $id 1 }
proc ::tabs::select {w id {notify 0}} {
    variable S
    if {![exists $w $id]} return
    set S($w,sel) $id
    paint $w
    set cmd [opt $w -select]
    if {$notify && $cmd ne ""} { uplevel #0 [list {*}$cmd $id] }
}
proc ::tabs::requestClose {w id} {
    set cmd [opt $w -close]
    if {$cmd ne ""} { uplevel #0 [list {*}$cmd $id] } else { remove $w $id }
}
proc ::tabs::hover {w id} { variable S ; set S($w,hover) $id ; paint $w }

# Remove a tab; returns the id that should become current ("" if none left).
proc ::tabs::remove {w id} {
    variable S
    set i [lsearch -exact $S($w,ids) $id]
    if {$i < 0} { return $S($w,sel) }
    set S($w,ids) [lreplace $S($w,ids) $i $i]
    destroy $w.t$id
    unset -nocomplain S($w,title,$id) S($w,dirty,$id) S($w,icon,$id)
    if {$S($w,sel) eq $id} {
        set S($w,sel) ""
        if {[llength $S($w,ids)]} {
            set S($w,sel) [lindex $S($w,ids) [expr {min($i, [llength $S($w,ids)] - 1)}]]
        }
    }
    paint $w
    return $S($w,sel)
}
proc ::tabs::setTitle {w id title} {
    variable S
    set S($w,title,$id) $title
    $w.t$id.l configure -text [expr {$S($w,dirty,$id) ? "$title \u2022" : $title}]
}
proc ::tabs::setDirty {w id d} {
    variable S
    set S($w,dirty,$id) $d
    setTitle $w $id $S($w,title,$id)
}
proc ::tabs::title {w id} { variable S ; return $S($w,title,$id) }

proc ::tabs::paint {w} {
    variable S
    set bg [expr {[opt $w -bg] eq "bg" ? $::theme::c(bg) : $::theme::c(panel)}]
    $w configure -background $bg
    $w.line configure -background $::theme::c(border)
    if {[winfo exists $w.more]} { $w.more configure -background $bg -foreground $::theme::c(dim) }
    foreach id $S($w,ids) {
        set t $w.t$id
        if {![winfo exists $t]} continue
        set sel [expr {$id eq $S($w,sel)}]
        if {$sel} {
            set tb $::theme::c(surface) ; set fg $::theme::c(fg) ; set bar $::theme::c(accent)
        } elseif {$id eq $S($w,hover)} {
            set tb $::theme::c(hover) ; set fg $::theme::c(fg) ; set bar $tb
        } else {
            set tb $bg ; set fg $::theme::c(dim) ; set bar $tb
        }
        $t configure -background $tb
        $t.bar configure -background $bar
        $t.i configure -background $tb
        $t.l configure -background $tb -foreground $fg
        if {[winfo exists $t.x]} {
            $t.x configure -background $tb \
                -image [::icons::get [expr {$sel || $id eq $S($w,hover) ? "closex" : "blank"}]]
        }
    }
    raise $w.line
}

proc ::tabs::listMenu {w x y} {
    variable S
    set m $w.menu
    catch {destroy $m}
    menu $m -tearoff 0
    ::theme::menu $m
    foreach id $S($w,ids) {
        $m add command -label $S($w,title,$id) -command [list ::tabs::select $w $id 1]
    }
    ::menus::post $m $x $y
}
