# docs.tcl -- the kinds of document that live in the centre tab strip.
#
#   ::qdoc    query editor + results/messages            (SSMS "query window")
#   ::ddoc    editable data grid for one view/subview    (SSMS "Edit Top 200 Rows")
#   ::design  view designer                              (SSMS "Table Designer")


# ============================================================================
#  Query document
# ============================================================================
namespace eval ::qdoc {
    variable Q
    array set Q {}
}

proc ::qdoc::create {id f {db ""} {text ""}} {
    variable Q
    set Q($id,db) $db ; set Q($id,running) 0 ; set Q($id,pages) {} ; set Q($id,page) ""
    set Q($id,file) "" ; set Q($id,nres) 0 ; set Q($id,resultsShown) 1 ; set Q($id,summary) ""
    ttk::frame $f -style Surface.TFrame
    ttk::panedwindow $f.pw -orient vertical
    pack $f.pw -fill both -expand 1

    ::editor::create $f.ed -poscmd [list ::app::setCursor] -modcmd [list ::qdoc::edited $id] \
        -runcmd [list ::qdoc::execute $id] -completer ::app::complete
    ttk::frame $f.res -style Surface.TFrame
    $f.pw add $f.ed -weight 3
    $f.pw add $f.res -weight 2

    # results area: a small tab strip, the pages, and an info bar
    ::tabs::create $f.res.tabs -small 1 -closable 0 -bg panel \
        -select [list ::qdoc::showPage $id]
    ttk::frame $f.res.body -style Surface.TFrame
    ttk::frame $f.res.info -style Panel.TFrame -padding {12 4}
    ttk::label $f.res.info.l -text "  Press F5 to run the query, or select part of it first" -style PanelDim.TLabel \
        -image [::icons::get blank] -compound left
    ttk::label $f.res.info.r -text "" -style PanelDim.TLabel
    pack $f.res.info.l -side left
    pack $f.res.info.r -side right
    pack $f.res.tabs -side top -fill x
    pack $f.res.info -side bottom -fill x
    pack $f.res.body -side top -fill both -expand 1
    grid rowconfigure $f.res.body 0 -weight 1 ; grid columnconfigure $f.res.body 0 -weight 1

    # messages page (always present)
    set m $f.res.body.msg
    ttk::frame $m -style Surface.TFrame
    text $m.t -wrap word -font MkMono -borderwidth 0 -highlightthickness 0 -padx 14 -pady 10 \
        -state disabled -cursor arrow -spacing1 2 -spacing3 2 -yscrollcommand [list $m.v set]
    ttk::scrollbar $m.v -orient vertical -command [list $m.t yview]
    pack $m.v -side right -fill y
    pack $m.t -side left -fill both -expand 1
    ::theme::reg $m.t [list ::qdoc::recolorMessages %w]
    addPage $id msg "Messages" $m

    if {$text ne ""} { ::editor::setText $f.ed $text }
    return $f
}

proc ::qdoc::recolorMessages {t} {
    $t configure -background $::theme::c(surface) -foreground $::theme::c(fg) \
        -selectbackground $::theme::c(sel) -selectforeground $::theme::c(selFg)
    $t tag configure dim -foreground $::theme::c(dim)
    $t tag configure ok -foreground $::theme::c(ok)
    $t tag configure err -foreground $::theme::c(bad)
    $t tag configure warn -foreground $::theme::c(warn)
    $t tag configure stmt -foreground $::theme::c(kw)
    $t tag configure head -foreground $::theme::c(fg) -font MkUIBold
}

proc ::qdoc::docf {id} { return [::app::docFrame $id] }

proc ::qdoc::addPage {id pid title page} {
    variable Q
    set f [docf $id]
    grid $page -row 0 -column 0 -sticky nsew
    lappend Q($id,pages) $pid
    ::tabs::add $f.res.tabs $pid $title [expr {$pid eq "msg" ? "doc" : "table"}]
    return $page
}

proc ::qdoc::showPage {id pid} {
    variable Q
    set f [docf $id]
    set Q($id,page) $pid
    set page $f.res.body.$pid
    if {[winfo exists $page]} { raise $page }
    ::tabs::select $f.res.tabs $pid
    updateInfo $id
}

proc ::qdoc::edited {id} {
    variable Q
    ::app::docEdited $id
}

proc ::qdoc::db {id} { variable Q ; return $Q($id,db) }
proc ::qdoc::setDb {id db} {
    variable Q
    set Q($id,db) $db
    ::app::docSelected $id
}

# remove all result grids from the previous run
proc ::qdoc::clearResults {id} {
    variable Q
    set f [docf $id]
    foreach pid $Q($id,pages) {
        if {$pid eq "msg"} continue
        destroy $f.res.body.$pid
        ::tabs::remove $f.res.tabs $pid
    }
    set Q($id,pages) {msg}
    set Q($id,nres) 0
    set t $f.res.body.msg.t
    $t configure -state normal ; $t delete 1.0 end ; $t configure -state disabled
}

proc ::qdoc::say {id text {tag {}}} {
    set t [docf $id].res.body.msg.t
    $t configure -state normal
    $t insert end $text $tag
    $t configure -state disabled
    $t see end
}

# Results bar, right side:  database . elapsed . rows of the visible result
proc ::qdoc::updateInfo {id} {
    variable Q
    set f [docf $id]
    set parts {}
    if {$Q($id,summary) ne ""} { set parts $Q($id,summary) }
    set pid $Q($id,page)
    set g $f.res.body.$pid
    if {$pid ne "" && $pid ne "msg" && [winfo exists $g]} {
        set n [::grid::count $g]
        lappend parts "[::app::commas $n] row[expr {$n == 1 ? {} : {s}}]"
    }
    $f.res.info.r configure -text [join $parts "   \u00B7   "]
}
proc ::qdoc::outcome {id kind text} {
    set f [docf $id]
    set img [dict get {ok check bad closexh none blank} $kind]
    $f.res.info.l configure -text "  $text" -image [::icons::get $img] -compound left
}

proc ::qdoc::toggleResults {id} {
    variable Q
    set f [docf $id]
    if {$Q($id,resultsShown)} {
        $f.pw forget $f.res ; set Q($id,resultsShown) 0
    } else {
        $f.pw add $f.res -weight 2 ; set Q($id,resultsShown) 1
    }
}
proc ::qdoc::showResults {id} {
    variable Q
    if {!$Q($id,resultsShown)} { toggleResults $id }
}

# location text for an absolute character offset in the editor
proc ::qdoc::where {id pos} {
    set t [docf $id].ed.t
    lassign [split [$t index "1.0 + ${pos}c"] .] l c
    return "Line $l, column [expr {$c + 1}]"
}

proc ::qdoc::stamp {} { clock format [clock seconds] -format %H:%M:%S }

proc ::qdoc::execute {id {parseOnly 0}} {
    variable Q
    if {$Q($id,running)} return
    set f [docf $id]
    lassign [::editor::runText $f.ed] text base
    if {[string trim $text] eq ""} {
        outcome $id bad "Nothing to run \u2014 type a query first."
        return
    }
    clearResults $id
    $f.ed.t tag remove err 1.0 end
    showResults $id
    set db $Q($id,db)
    ::app::dbAutoSelect $id

    if {[catch {::engine::parseScript $text} parsed opts]} {
        set code [dict get $opts -errorcode]
        say $id "[stamp]  " dim
        say $id "Syntax error\n" err
        if {[lindex $code 0] eq "MKQL"} {
            lassign $code _ kind pos len
            ::editor::markError $f.ed [expr {$base + $pos}] $len
            say $id "  [where $id [expr {$base + $pos}]]:  " dim
            say $id "$parsed\n" err
        } else {
            say $id "  $parsed\n" err
        }
        set Q($id,summary) ""
        showPage $id msg
        outcome $id bad "Syntax error \u2014 see Messages"
        return
    }
    if {$parseOnly} {
        say $id "[stamp]  " dim
        say $id "Parsed [llength $parsed] statement[expr {[llength $parsed] == 1 ? {} : {s}}] \u2014 syntax is valid.\n" ok
        showPage $id msg
        outcome $id ok "Syntax is valid"
        return
    }

    set Q($id,running) 1
    ::app::busy 1
    set ::engine::progressHook ::app::pump
    set t0 [clock milliseconds]
    set failed 0 ; set changed 0 ; set lastRows ""
    set n 0
    foreach p $parsed {
        lassign $p ast a b stext
        incr n
        set short [string map [list \n " "] [string trim $stext]]
        regsub -all {\s+} $short { } short
        if {[string length $short] > 90} { set short "[string range $short 0 87]\u2026" }
        say $id "[stamp]  " dim
        say $id "$short\n" stmt
        set s0 [clock milliseconds]
        if {[catch {::engine::execute $ast $db} res opts]} {
            set failed 1
            set code [dict get $opts -errorcode]
            if {[lindex $code 0] eq "MKQL" && [lindex $code 1] eq "SYNTAX"} {
                ::editor::markError $f.ed [expr {$base + [lindex $code 2]}] [lindex $code 3]
            } else {
                ::editor::markError $f.ed [expr {$base + $a}] [expr {$b - $a}]
            }
            say $id "  \u2716  $res\n\n" err
            break
        }
        set ms [expr {[clock milliseconds] - $s0}]
        set kind [lindex $ast 0]
        switch -- [dict get $res kind] {
            rowset {
                incr Q($id,nres)
                set pid r$Q($id,nres)
                set g [docf $id].res.body.$pid
                ::grid::create $g -drill [list ::qdoc::drill $id $pid] -changed [list ::qdoc::updateInfo $id]
                set cnt [::grid::load $g $res]
                addPage $id $pid "Results" $g
                set suffix [expr {[dict get $res truncated] ? "  (stopped at [::app::commas $::engine::maxRows] rows \u2014 add LIMIT or WHERE)" : ""}]
                say $id "  \u2714  [::app::commas $cnt] row[expr {$cnt == 1 ? {} : {s}}]  \u00B7  $ms ms$suffix\n\n" ok
                set lastRows $cnt
            }
            message {
                say $id "  \u2714  [dict get $res text]  \u00B7  $ms ms\n\n" ok
                if {[dict exists $res use]} { setDb $id [dict get $res use] ; set db [dict get $res use] }
                if {$kind in {insert update delete merge create drop alter commit rollback}} { set changed 1 }
            }
        }
    }
    set ms [expr {[clock milliseconds] - $t0}]
    set ::engine::progressHook {}
    set Q($id,running) 0
    ::app::busy 0

    # tidy result tab titles: "Results 1", "Results 2" when there are several
    if {$Q($id,nres) > 1} {
        for {set i 1} {$i <= $Q($id,nres)} {incr i} { ::tabs::setTitle $f.res.tabs r$i "Results $i" }
    }
    set Q($id,summary) [list [expr {$db ne "" ? $db : "no database"}] "$ms ms"]
    if {$failed} {
        say $id "Completed with errors in $ms ms\n" err
        showPage $id msg
        outcome $id bad "Query completed with errors \u2014 see Messages"
    } else {
        say $id "Completed [llength $parsed] statement[expr {[llength $parsed] == 1 ? {} : {s}}] in $ms ms\n" dim
        if {$Q($id,nres) > 0} { showPage $id r1 } else { showPage $id msg }
        outcome $id ok "Query executed successfully"
    }
    ::app::setStatus "Ready" ok
    if {$changed} { ::app::dataChanged }
    focus $f.ed.t
}

# double-click on a subview cell in a result grid
proc ::qdoc::drill {id pid rowid sub} {
    set g [docf $id].res.body.$pid
    set src $::grid::G($g,source)
    if {$src eq ""} return
    regsub -all {!(\d+)\.} $src {[\1].} p
    ::app::newQuery "SELECT * FROM $p\[$rowid\].$sub" [lindex [split $src .] 0] 1
}

proc ::qdoc::currentGrid {id} {
    variable Q
    set pid $Q($id,page)
    if {$pid eq "" || $pid eq "msg"} { return "" }
    set g [docf $id].res.body.$pid
    return [expr {[winfo exists $g] ? $g : ""}]
}

# ============================================================================
#  Data document: editable grid over one view or subview
# ============================================================================
namespace eval ::ddoc {
    variable D
    array set D {}
}

proc ::ddoc::docf {id} { return [::app::docFrame $id] }

# "tag.view!3.sub"  ->  "view[3].sub"   (what the user sees on tabs)
proc ::ddoc::viewLabel {mk} {
    regsub -all {!(\d+)\.} $mk {[\1].} p
    regsub -all {!(\d+)$} $p {[\1]} p
    return [join [lrange [split $p .] 1 end] .]
}

proc ::ddoc::create {id f mk} {
    variable D
    set D($id,mk) $mk ; set D($id,undo) {} ; set D($id,redo) {}
    ttk::frame $f -style Surface.TFrame
    ttk::frame $f.bar -style Surface.TFrame -padding {8 6}
    ttk::button $f.bar.add -text "Add Row" -image [::icons::get plus] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::addRow $id]
    ttk::button $f.bar.del -text "Delete" -image [::icons::get minus] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::deleteRows $id]
    ttk::button $f.bar.col -text "Add Column" -image [::icons::get col_I] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::addColumn $id]
    ttk::label $f.bar.count -text "" -style SurfaceDim.TLabel
    pack $f.bar.add $f.bar.del -side left -padx {0 2}
    pack $f.bar.col -side left -padx {8 2}
    if {[string first ! $mk] >= 0} {
        $f.bar.col state disabled
        ::tip::attach $f.bar.col "Columns of a subview can't be changed from a row. Open the view's Design tab."
    } else {
        ::tip::attach $f.bar.col "Add a new column to this view  (more options in Design)"
    }
    pack $f.bar.count -side right -padx 2

    set ro [readonly $id]
    if {$ro} { foreach b {add del col} { $f.bar.$b state disabled } }
    ::grid::create $f.g -editable [expr {!$ro}] -commit [list ::ddoc::commit $id] \
        -drill [list ::ddoc::drill $id] -changed [list ::ddoc::updateCount $id]
    ttk::frame $f.msg -style Panel.TFrame -padding {12 5}
    ttk::label $f.msg.l -text "" -style PanelDim.TLabel
    pack $f.msg.l -side left
    pack $f.bar -side top -fill x
    pack $f.msg -side bottom -fill x
    pack $f.g -side top -fill both -expand 1
    ::ui::bindMod $f.g.t z "[list ::ddoc::undo $id] ; break"
    ::ui::bindMod $f.g.t Z "[list ::ddoc::redo $id] ; break"
    ::ui::bindMod $f.g.t y "[list ::ddoc::redo $id] ; break"
    bind $f.g <<GridDelete>> [list ::ddoc::deleteRows $id]
    bind $f.g.t <Delete> [list ::ddoc::deleteRows $id]
    bind $f.g <<GridError>> [list ::ddoc::showError $id]
    reload $id
    return $f
}

proc ::ddoc::readonly {id} {
    variable D
    return [::store::readonly [lindex [split $D($id,mk) .] 0]]
}
proc ::ddoc::note {id text {kind dim}} {
    set f [docf $id]
    $f.msg.l configure -text $text -foreground [expr {$kind eq "bad" ? $::theme::c(bad) : $::theme::c(dim)}]
}
proc ::ddoc::showError {id} {
    set f [docf $id]
    note $id "\u2716  $::grid::G($f.g,lasterror)" bad
}
proc ::ddoc::hint {id} {
    if {[readonly $id]} { note $id "This database is open read-only." ; return }
    note $id "Double-click a cell to edit it. Changes stay in memory until you Commit."
}

# (Re)attach the grid to the view.  Every row is available - the grid reads them as they scroll
# into view - so there is no paging.  keep=1 keeps the scroll position and selection.
proc ::ddoc::reload {id {keep 0}} {
    variable D
    set f [docf $id]
    set mk $D($id,mk)
    if {[catch {::grid::loadStore $f.g $mk $keep} err]} {
        note $id "\u2716  This view no longer exists." bad
        return
    }
    if {[::store::size $mk] == 0} {
        note $id "This view is empty. Click Add Row to create the first row."
    } else { hint $id }
}

# row count label
proc ::ddoc::updateCount {id} {
    variable D
    set f [docf $id]
    if {![winfo exists $f.g]} return
    set total [::grid::count $f.g]
    $f.bar.count configure -text "[::app::commas $total] row[expr {$total == 1 ? {} : {s}}]"
}

proc ::ddoc::commit {id rowid col value} {
    variable D
    set mk $D($id,mk)
    if {[::store::readonly [lindex [split $mk .] 0]]} { error "This database is open read-only." }
    set d [::store::findCol [::store::layout $mk] $col]
    set v [::store::coerce [lindex $d 0] [lindex $d 1] $value]
    set old [::store::cell $mk $rowid [lindex $d 0]]
    ::store::setCell $mk $rowid [lindex $d 0] $v
    if {$old ne $v} { push $id [list cell $rowid [lindex $d 0] $old $v] }
    hint $id
    ::app::dataChanged 0
}

proc ::ddoc::drill {id rowid sub} {
    variable D
    set mk $D($id,mk)
    if {[string index $sub 0] eq "@"} {
        ::bytes::view $mk $rowid [string range $sub 1 end] [readonly $id] $id
        reload $id 1
        return
    }
    ::app::openData "$mk!$rowid.$sub" "[viewLabel $mk]\[$rowid\].$sub"
}

proc ::ddoc::addColumn {id} {
    variable D
    if {![::design::promptAddColumn $D($id,mk)]} return
    ::app::dataChanged 1
    note $id "Column added. It's empty for existing rows - double-click cells to fill it in."
}

proc ::ddoc::addRow {id} {
    variable D
    set f [docf $id]
    if {[catch {
        if {[::store::readonly [lindex [split $D($id,mk) .] 0]]} { error "This database is open read-only." }
        set idx [::store::appendRow $D($id,mk) {} {}]
        push $id [list add $idx {}]
    } err]} { note $id "\u2716  $err" bad ; return }
    reload $id 1
    ::grid::selectLast $f.g
    ::app::dataChanged 0
    note $id "Row added. Double-click its cells to fill them in."
}

proc ::ddoc::deleteRows {id} {
    variable D
    set f [docf $id]
    set ids [::grid::selectedRowids $f.g]
    if {![llength $ids]} { note $id "Select one or more rows first." ; return }
    set n [llength $ids]
    set r [::ui::ask "Delete rows" "Delete $n row[expr {$n == 1 ? {} : {s}}]?\n\nYou can still undo this with Roll Back until you commit." {Delete Cancel} warn]
    if {$r ne "Delete"} return
    if {[catch {
        if {[::store::readonly [lindex [split $D($id,mk) .] 0]]} { error "This database is open read-only." }
        set snaps {}
        foreach i [lsort -integer -unique $ids] { lappend snaps [list $i [::store::captureRow $D($id,mk) $i]] }
        ::store::deleteRows $D($id,mk) $ids
        push $id [list del $snaps]
    } err]} { note $id "\u2716  $err" bad ; return }
    reload $id
    ::app::dataChanged 0
    note $id "Deleted $n row[expr {$n == 1 ? {} : {s}}]. Press Ctrl+Z to undo."
}

# ---- undo / redo ----------------------------------------------------------------------
# Actions:  {cell rowid col old new}   {add idx snapshot}   {del {{idx snapshot} ...}}
# Each is validated against the live data first and refused if it has since changed
# (for example by a query run in another tab), rather than risking a wrong write.
proc ::ddoc::push {id action} {
    variable D
    lappend D($id,undo) $action
    if {[llength $D($id,undo)] > 200} { set D($id,undo) [lrange $D($id,undo) end-199 end] }
    set D($id,redo) {}
}
proc ::ddoc::clearUndo {} {
    variable D
    foreach k [array names D *,undo] { set D($k) {} }
    foreach k [array names D *,redo] { set D($k) {} }
}
proc ::ddoc::undo {id} { step $id undo redo }
proc ::ddoc::redo {id} { step $id redo undo }

proc ::ddoc::step {id from to} {
    variable D
    if {![llength $D($id,$from)]} { note $id "Nothing to [expr {$from eq "undo" ? {undo} : {redo}}]." ; return }
    if {[readonly $id]} return
    set mk $D($id,mk)
    set action [lindex $D($id,$from) end]
    set verb [expr {$from eq "undo" ? "Undid" : "Redid"}]
    if {[catch {
        switch -- [lindex $action 0] {
            cell {
                lassign $action _ rowid col old new
                set want [expr {$from eq "undo" ? $new : $old}] ; set put [expr {$from eq "undo" ? $old : $new}]
                if {$rowid >= [::store::size $mk] || [::store::cell $mk $rowid $col] ne $want} {
                    error "the cell was changed elsewhere"
                }
                ::store::setCell $mk $rowid $col $put
                set msg "$verb edit of '$col' in row [expr {$rowid + 1}]."
            }
            add {
                lassign $action _ idx snap
                if {$from eq "undo"} {
                    if {$idx != [::store::size $mk] - 1} { error "rows were added or removed elsewhere" }
                    set snap [::store::captureRow $mk $idx]
                    ::store::deleteRows $mk [list $idx]
                    set action [list add $idx $snap]
                } else {
                    ::store::restoreRow $mk $idx $snap
                }
                set msg "$verb adding row [expr {$idx + 1}]."
            }
            del {
                set snaps [lindex $action 1]
                if {$from eq "undo"} {
                    foreach s $snaps { ::store::restoreRow $mk [lindex $s 0] [lindex $s 1] }
                } else {
                    set idx {} ; foreach s $snaps { lappend idx [lindex $s 0] }
                    if {[lindex $idx end] >= [::store::size $mk]} { error "rows were added or removed elsewhere" }
                    ::store::deleteRows $mk $idx
                }
                set msg "$verb deleting [llength $snaps] row[expr {[llength $snaps] == 1 ? {} : {s}}]."
            }
        }
    } err]} { note $id "\u2716  Can't [expr {$from eq {undo} ? {undo} : {redo}}]: $err." bad ; return }
    set D($id,$from) [lrange $D($id,$from) 0 end-1]
    lappend D($id,$to) $action
    reload $id 1
    ::app::dataChanged 0
    note $id $msg
}

# ============================================================================
#  Designer: the columns of a view
# ============================================================================
namespace eval ::design {
    variable X
    array set X {}
    variable typeMap {String S Integer I Long L Float F Double D Bytes B}
}

proc ::design::docf {id} { return [::app::docFrame $id] }

proc ::design::create {id f mk} {
    variable X
    set X($id,mk) $mk
    ttk::frame $f -style Surface.TFrame
    ttk::frame $f.bar -style Surface.TFrame -padding {8 6}
    foreach {b text icon cmd} {
        addc "Add Column"  plus    addColumn
        adds "Add Subview" subview addSubview
        edit "Edit"        edit    editColumn
        drop "Drop"        trash   dropColumn
    } {
        ttk::button $f.bar.$b -text $text -image [::icons::get $icon] -compound left \
            -style ToolSurface.TButton -command [list ::design::$cmd $id]
        pack $f.bar.$b -side left -padx {0 2}
    }
    ttk::treeview $f.t -style Grid.Treeview -columns {type} -show {tree headings} -selectmode browse
    ::ui::hoverTree $f.t
    $f.t heading #0 -text "Column" -anchor w
    $f.t heading type -text "Type" -anchor w
    $f.t column #0 -width [::theme::px 300] -stretch 0
    $f.t column type -width [::theme::px 160] -stretch 1
    ttk::scrollbar $f.v -orient vertical -command [list $f.t yview]
    $f.t configure -yscrollcommand [list $f.v set]
    ttk::frame $f.msg -style Panel.TFrame -padding {12 5}
    ttk::label $f.msg.l -text "Structure changes stay in memory until you Commit." -style PanelDim.TLabel
    pack $f.msg.l -side left
    pack $f.bar -side top -fill x
    pack $f.msg -side bottom -fill x
    pack $f.v -side right -fill y
    pack $f.t -side left -fill both -expand 1
    if {[::store::readonly [lindex [split $mk .] 0]]} {
        foreach b {addc adds edit drop} { $f.bar.$b state disabled }
        $f.msg.l configure -text "This database is open read-only."
    }
    bind $f.t <Double-1> [list ::design::editColumn $id]
    bind $f.t <Delete> [list ::design::dropColumn $id]
    refresh $id
    return $f
}

proc ::design::refresh {id} {
    variable X
    set f [docf $id]
    set t $f.t
    set sel [$t selection]
    $t delete [$t children {}]
    if {[catch {::store::layout $X($id,mk)} layout]} return
    fillTree $t {} $layout {}
    if {$sel ne "" && [$t exists $sel]} { $t selection set $sel }
}
proc ::design::fillTree {t parent layout chain} {
    foreach c $layout {
        lassign $c n type sub
        set id [join [concat $chain [list $n]] /]
        $t insert $parent end -id $id -text " $n" -image [::icons::get col_$type] -open 1 \
            -values [list [expr {$type eq "V" ? "Subview" : [::store::typeName $type]}]]
        if {$type eq "V"} { fillTree $t $id $sub [concat $chain [list $n]] }
    }
}
proc ::design::note {id text {kind dim}} {
    [docf $id].msg.l configure -text $text -foreground [expr {$kind eq "bad" ? $::theme::c(bad) : $::theme::c(dim)}]
}

# a top-level column the user has selected, or ""
proc ::design::picked {id} {
    set sel [[docf $id].t selection]
    if {$sel eq ""} { note $id "Select a column first." ; return "" }
    if {[string first / $sel] >= 0} {
        note $id "Columns inside a subview can't be changed here." ; return ""
    }
    return $sel
}

# apply a new layout and refresh everything
proc ::design::applyChange {id script} {
    variable X
    set mk $X($id,mk)
    if {[catch {
        if {[::store::readonly [lindex [split $mk .] 0]]} { error "This database is open read-only." }
        uplevel #0 $script
    } err]} { ::ui::problem $err ; return 0 }
    refresh $id
    ::app::dataChanged 1
    note $id "Done. Commit to keep the change, or Roll Back to undo it."
    return 1
}

proc ::design::validate {id d} { variable X ; return [validateMk $X($id,mk) $d] }
proc ::design::validateMk {mk d} {
    set n [dict get $d name]
    if {$n eq ""} { return "Please enter a name." }
    if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $n]} { return "Use letters, digits and underscores, and don't start with a digit." }
    if {[dict exists $d old] && [string equal -nocase $n [dict get $d old]]} { return "" }
    if {[::store::findCol [::store::layout $mk] $n] ne ""} { return "A column called '$n' already exists." }
    return ""
}
proc ::design::types {} { variable typeMap ; return [dict keys $typeMap] }
proc ::design::letter {label} { variable typeMap ; return [dict get $typeMap $label] }

# Ask for a name and type, then add the column.  Shared by the Designer and the
# data editor.  Returns 1 if a column was added.
proc ::design::promptAddColumn {mk} {
    set r [::ui::formResult [::ui::form "Add column to [::ddoc::viewLabel $mk]" [list \
        {name "Name" entry ""} [list type "Type" combo String [types]]] "Add" \
        [list ::design::validateMk $mk]]]
    if {$r eq ""} { return 0 }
    if {[catch {
        if {[::store::readonly [lindex [split $mk .] 0]]} { error "This database is open read-only." }
        ::store::restructure $mk [concat [::store::layout $mk] \
            [list [list [dict get $r name] [letter [dict get $r type]] {}]]]
    } err]} { ::ui::problem $err ; return 0 }
    return 1
}
proc ::design::addColumn {id} {
    variable X
    if {![promptAddColumn $X($id,mk)]} return
    refresh $id
    ::app::dataChanged 1
    note $id "Column added. Commit to keep the change, or Roll Back to undo it."
}
proc ::design::addSubview {id} {
    variable X
    set r [::ui::formResult [::ui::form "Add subview" [list \
        {name "Subview name" entry ""} {first "First column" entry "id"} \
        [list type "Type" combo Integer [types]]] "Add" [list ::design::validate $id] \
        "A subview is a nested table: every row of this view holds its own list of rows."]]
    if {$r eq ""} return
    set mk $X($id,mk)
    applyChange $id [list ::store::restructure $mk [concat [::store::layout $mk] \
        [list [list [dict get $r name] V [list [list [dict get $r first] [letter [dict get $r type]] {}]]]]]]
}
proc ::design::editColumn {id} {
    variable X
    set sel [picked $id] ; if {$sel eq ""} return
    set mk $X($id,mk)
    set d [::store::findCol [::store::layout $mk] $sel]
    if {[lindex $d 1] eq "V"} { note $id "A subview can't be renamed. Add a new one and move its rows." ; return }
    set r [::ui::formResult [::ui::form "Edit column" [list \
        [list name "Name" entry $sel] \
        [list type "Type" combo [::store::typeName [lindex $d 1]] [types]]] "Save" \
        [list ::design::validateEdit $id $sel] \
        "The data is copied across into the changed column."]]
    if {$r eq ""} return
    set new [dict get $r name] ; set T [letter [dict get $r type]]
    if {$new eq $sel && $T eq [lindex $d 1]} return
    applyChange $id [list ::store::rebuildColumn $mk $sel $new $T]
}
proc ::design::validateEdit {id old d} { validate $id [dict merge $d [dict create old $old]] }

proc ::design::dropColumn {id} {
    variable X
    set sel [picked $id] ; if {$sel eq ""} return
    set r [::ui::ask "Drop column" "Drop '$sel' and all of its data?\n\nYou can still undo this with Roll Back until you commit." {Drop Cancel} warn]
    if {$r ne "Drop"} return
    set mk $X($id,mk)
    set new {}
    foreach c [::store::layout $mk] { if {[lindex $c 0] ne $sel} { lappend new $c } }
    if {![llength $new]} { ::ui::problem "A view needs at least one column." ; return }
    applyChange $id [list ::store::restructure $mk $new]
}

# ============================================================================
#  Bytes viewer: hex dump of a binary cell, with export / replace-from-file
# ============================================================================
namespace eval ::bytes { variable maxDump 4096 }

proc ::bytes::dump {data} {
    variable maxDump
    set n [string length $data]
    set show [string range $data 0 [expr {$maxDump - 1}]]
    set out {}
    for {set off 0} {$off < [string length $show]} {incr off 16} {
        set chunk [string range $show $off [expr {$off + 15}]]
        binary scan $chunk H* hx
        regsub -all {..} $hx {& } hx
        set ascii [regsub -all {[^\x20-\x7e]} $chunk .]
        lappend out [format "%08x  %-48s |%s|" $off $hx $ascii]
    }
    if {$n > $maxDump} { lappend out "... [expr {$n - $maxDump}] more bytes not shown (Export to see all)" }
    return [join $out \n]
}

proc ::bytes::view {mk rowid col readonly {docId ""}} {
    set data [::store::cell $mk $rowid $col]
    set w [::ui::modal "Bytes: $col"]
    set n [string length $data]
    ttk::label $w.body.info -style SurfaceDim.TLabel \
        -text "[::app::commas $n] byte[expr {$n == 1 ? {} : {s}}]   -   [::ddoc::viewLabel $mk]\[$rowid\].$col"
    text $w.body.t -width 78 -height 18 -font MkMono -borderwidth 0 -highlightthickness 0 -padx 10 -pady 8 \
        -wrap none -state normal
    $w.body.t insert 1.0 [expr {$n ? [dump $data] : "(empty)"}]
    $w.body.t configure -state disabled
    ::theme::reg $w.body.t {%w configure -background $::theme::c(editor) -foreground $::theme::c(fg) -selectbackground $::theme::c(sel)}
    pack $w.body.info -side top -anchor w -pady {0 8}
    pack $w.body.t -side top -fill both -expand 1
    ttk::button $w.bar.close -text Close -width 10 -style Accent.TButton -command {set ::ui::result close}
    ttk::button $w.bar.exp -text "Export..." -width 10 -command [list ::bytes::export $mk $rowid $col]
    ttk::button $w.bar.rep -text "Replace..." -width 10 -command [list ::bytes::replace $w $mk $rowid $col $docId]
    ttk::button $w.bar.clr -text "Clear" -width 8 -command [list ::bytes::clear $w $mk $rowid $col $docId]
    pack $w.bar.close -side right
    pack $w.bar.exp -side left
    if {!$readonly} { pack $w.bar.rep $w.bar.clr -side left -padx {8 0} }
    bind $w <Return> {set ::ui::result close}
    ::ui::run $w $w.bar.close
}
proc ::bytes::export {mk rowid col} {
    set f [tk_getSaveFile -title "Export bytes" -initialfile $col.bin]
    if {$f eq ""} return
    if {[catch {
        set out [open $f wb] ; puts -nonewline $out [::store::cell $mk $rowid $col] ; close $out
    } err]} { ::ui::problem $err }
}
proc ::bytes::record {docId mk rowid col old new} {
    if {$docId ne "" && $old ne $new} { ::ddoc::push $docId [list cell $rowid $col $old $new] }
}
proc ::bytes::replace {w mk rowid col docId} {
    set f [tk_getOpenFile -title "Replace with file contents"]
    if {$f eq ""} return
    if {[catch {
        set in [open $f rb] ; set data [read $in] ; close $in
        set old [::store::cell $mk $rowid $col]
        ::store::setCell $mk $rowid $col $data
        record $docId $mk $rowid $col $old $data
        ::app::dataChanged 0
    } err]} { ::ui::problem $err ; return }
    set ::ui::result changed
}
proc ::bytes::clear {w mk rowid col docId} {
    if {[catch {
        set old [::store::cell $mk $rowid $col]
        ::store::setCell $mk $rowid $col ""
        record $docId $mk $rowid $col $old ""
        ::app::dataChanged 0
    } err]} { ::ui::problem $err ; return }
    set ::ui::result changed
}
