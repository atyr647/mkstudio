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
    set Q($id,file) "" ; set Q($id,nres) 0 ; set Q($id,resultsShown) 1
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
    ttk::label $f.res.info.l -text "Ready" -style PanelDim.TLabel
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

proc ::qdoc::updateInfo {id} {
    variable Q
    set f [docf $id]
    set pid $Q($id,page)
    if {$pid eq "" || $pid eq "msg"} {
        $f.res.info.r configure -text ""
        return
    }
    set g $f.res.body.$pid
    if {[winfo exists $g]} {
        set n [::grid::count $g]
        $f.res.info.r configure -text "[::app::commas $n] row[expr {$n == 1 ? {} : {s}}]"
    }
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
        ::app::setStatus "Nothing to execute \u2014 type a statement first." warn
        return
    }
    clearResults $id
    $f.ed.t tag remove err 1.0 end
    showResults $id
    set db $Q($id,db)
    ::app::dbAutoSelect $id

    if {[catch {::mkql::parseScript $text} parsed opts]} {
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
        showPage $id msg
        ::app::setStatus "Syntax error" bad
        return
    }
    if {$parseOnly} {
        say $id "[stamp]  " dim
        say $id "Parsed [llength $parsed] statement[expr {[llength $parsed] == 1 ? {} : {s}}] \u2014 syntax is valid.\n" ok
        showPage $id msg
        ::app::setStatus "Syntax OK" ok
        return
    }

    set Q($id,running) 1
    ::app::busy 1
    set ::mkql::progressHook ::app::pump
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
        if {[catch {::mkql::execStatement $ast $db} res opts]} {
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
                set suffix [expr {[dict get $res truncated] ? "  (stopped at [::app::commas $::mkql::maxRows] rows \u2014 add LIMIT or WHERE)" : ""}]
                say $id "  \u2714  [::app::commas $cnt] row[expr {$cnt == 1 ? {} : {s}}]  \u00B7  $ms ms$suffix\n\n" ok
                set lastRows $cnt
            }
            message {
                say $id "  \u2714  [dict get $res text]  \u00B7  $ms ms\n\n" ok
                if {[dict exists $res use]} { setDb $id [dict get $res use] ; set db [dict get $res use] }
                if {$kind in {insert update delete create drop alter commit rollback}} { set changed 1 }
            }
        }
    }
    set ms [expr {[clock milliseconds] - $t0}]
    set ::mkql::progressHook {}
    set Q($id,running) 0
    ::app::busy 0

    # tidy result tab titles: "Results 1", "Results 2" when there are several
    if {$Q($id,nres) > 1} {
        for {set i 1} {$i <= $Q($id,nres)} {incr i} { ::tabs::setTitle $f.res.tabs r$i "Results $i" }
    }
    if {$failed} {
        say $id "Completed with errors in $ms ms\n" err
        showPage $id msg
        ::app::setStatus "Query completed with errors" bad
    } else {
        say $id "Completed [llength $parsed] statement[expr {[llength $parsed] == 1 ? {} : {s}}] in $ms ms\n" dim
        if {$Q($id,nres) > 0} { showPage $id r1 } else { showPage $id msg }
        ::app::setStatus "Query executed successfully" ok
    }
    $f.res.info.l configure -text [expr {$failed ? "Completed with errors" : "Query executed successfully"}]
    ::app::setRunInfo $ms $lastRows
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
    variable maxRows 20000
}

proc ::ddoc::docf {id} { return [::app::docFrame $id] }

# "tag.view!3.sub"  ->  "view[3].sub"   (what the user sees on tabs)
proc ::ddoc::label {mk} {
    regsub -all {!(\d+)\.} $mk {[\1].} p
    regsub -all {!(\d+)$} $p {[\1]} p
    return [join [lrange [split $p .] 1 end] .]
}

proc ::ddoc::create {id f mk} {
    variable D
    set D($id,mk) $mk
    ttk::frame $f -style Surface.TFrame
    ttk::frame $f.bar -style Surface.TFrame -padding {8 6}
    ttk::button $f.bar.add -text "Add Row" -image [::icons::get plus] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::addRow $id]
    ttk::button $f.bar.del -text "Delete" -image [::icons::get minus] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::deleteRows $id]
    ttk::label $f.bar.count -text "" -style SurfaceDim.TLabel
    pack $f.bar.add $f.bar.del -side left -padx {0 2}
    pack $f.bar.count -side right -padx 8

    ::grid::create $f.g -editable 1 -commit [list ::ddoc::commit $id] \
        -drill [list ::ddoc::drill $id] -changed [list ::ddoc::updateCount $id]
    ttk::frame $f.msg -style Panel.TFrame -padding {12 5}
    ttk::label $f.msg.l -text "" -style PanelDim.TLabel
    pack $f.msg.l -side left
    pack $f.bar -side top -fill x
    pack $f.msg -side bottom -fill x
    pack $f.g -side top -fill both -expand 1
    bind $f.g <<GridDelete>> [list ::ddoc::deleteRows $id]
    bind $f.g.t <Delete> [list ::ddoc::deleteRows $id]
    bind $f.g <<GridError>> [list ::ddoc::showError $id]
    reload $id
    return $f
}

proc ::ddoc::note {id text {kind dim}} {
    set f [docf $id]
    $f.msg.l configure -text $text -foreground [expr {$kind eq "bad" ? $::theme::c(bad) : $::theme::c(dim)}]
}
proc ::ddoc::showError {id} {
    set f [docf $id]
    note $id "✖  $::grid::G($f.g,lasterror)" bad
}
proc ::ddoc::hint {id} {
    note $id "Double-click a cell to edit it. Changes stay in memory until you Commit."
}

# Read the view straight from the store into the grid's result format.
proc ::ddoc::reload {id} {
    variable D ; variable maxRows
    set f [docf $id]
    set mk $D($id,mk)
    if {[catch {::store::layout $mk} layout]} {
        note $id "✖  This view no longer exists." bad
        return
    }
    set cols {} ; set types {} ; set props {} ; set drill [dict create]
    set i 0
    foreach c $layout {
        lassign $c n t
        lappend cols $n ; lappend types $t
        if {$t eq "V"} { dict set drill $i $n } else { lappend props $n }
        incr i
    }
    set total [::store::size $mk]
    set n [expr {min($total, $maxRows)}]
    set raw [::store::rows $mk $props 0 $n]
    set rows {} ; set rowids {}
    set r 0
    foreach vals $raw {
        set out {} ; set k 0
        foreach c $layout {
            lassign $c name t
            if {$t eq "V"} {
                set cnt [::store::subSize $mk $r $name]
                lappend out "▸ $cnt row[expr {$cnt == 1 ? {} : {s}}]"
            } else { lappend out [lindex $vals $k] ; incr k }
        }
        lappend rows $out ; lappend rowids $r
        incr r
    }
    ::grid::load $f.g [dict create cols $cols types $types rows $rows rowids $rowids drill $drill \
        source $mk truncated 0 editable 1]
    if {$total > $n} {
        note $id "Showing the first [::app::commas $n] of [::app::commas $total] rows."
    } else { hint $id }
}

proc ::ddoc::updateCount {id} {
    set f [docf $id]
    if {![winfo exists $f.g]} return
    set total [::store::size $::ddoc::D($id,mk)]
    $f.bar.count configure -text "[::app::commas $total] row[expr {$total == 1 ? {} : {s}}]"
}

proc ::ddoc::commit {id rowid col value} {
    variable D
    set mk $D($id,mk)
    if {[::store::readonly [lindex [split $mk .] 0]]} { error "This database is open read-only." }
    set d [::store::findCol [::store::layout $mk] $col]
    set v [::store::coerce [lindex $d 0] [lindex $d 1] $value]
    ::store::setCell $mk $rowid [lindex $d 0] $v
    hint $id
    ::app::dataChanged 0
}

proc ::ddoc::drill {id rowid sub} {
    variable D
    set mk $D($id,mk)
    ::app::openData "$mk!$rowid.$sub" "[label $mk]\[$rowid\].$sub"
}

proc ::ddoc::addRow {id} {
    variable D
    set f [docf $id]
    if {[catch {
        if {[::store::readonly [lindex [split $D($id,mk) .] 0]]} { error "This database is open read-only." }
        ::store::appendRow $D($id,mk) {} {}
    } err]} { note $id "✖  $err" bad ; return }
    reload $id
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
    set r [::ui::ask "Delete rows" "Delete $n row[expr {$n == 1 ? {} : {s}}]?\n\nYou can still undo this with Roll Back until you commit." {Delete Cancel} stop]
    if {$r ne "Delete"} return
    if {[catch {
        if {[::store::readonly [lindex [split $D($id,mk) .] 0]]} { error "This database is open read-only." }
        ::store::deleteRows $D($id,mk) $ids
    } err]} { note $id "✖  $err" bad ; return }
    reload $id
    ::app::dataChanged 0
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
    $f.t heading #0 -text "Column" -anchor w
    $f.t heading type -text "Type" -anchor w
    $f.t column #0 -width 300 -stretch 0
    $f.t column type -width 160 -stretch 1
    ttk::scrollbar $f.v -orient vertical -command [list $f.t yview]
    $f.t configure -yscrollcommand [list $f.v set]
    ttk::frame $f.msg -style Panel.TFrame -padding {12 5}
    ttk::label $f.msg.l -text "Structure changes stay in memory until you Commit." -style PanelDim.TLabel
    pack $f.msg.l -side left
    pack $f.bar -side top -fill x
    pack $f.msg -side bottom -fill x
    pack $f.v -side right -fill y
    pack $f.t -side left -fill both -expand 1
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
proc ::design::apply {id script} {
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

proc ::design::validate {id d} {
    variable X
    set n [dict get $d name]
    if {$n eq ""} { return "Please enter a name." }
    if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $n]} { return "Use letters, digits and underscores, and don't start with a digit." }
    if {[dict exists $d old] && [string equal -nocase $n [dict get $d old]]} { return "" }
    if {[::store::findCol [::store::layout $X($id,mk)] $n] ne ""} { return "A column called '$n' already exists." }
    return ""
}
proc ::design::types {} { variable typeMap ; return [dict keys $typeMap] }
proc ::design::letter {label} { variable typeMap ; return [dict get $typeMap $label] }

proc ::design::addColumn {id} {
    variable X
    set r [::ui::formResult [::ui::form "Add column" [list \
        {name "Name" entry ""} [list type "Type" combo String [types]]] "Add" \
        [list ::design::validate $id]]]
    if {$r eq ""} return
    set mk $X($id,mk)
    apply $id [list ::store::restructure $mk [concat [::store::layout $mk] \
        [list [list [dict get $r name] [letter [dict get $r type]] {}]]]]
}
proc ::design::addSubview {id} {
    variable X
    set r [::ui::formResult [::ui::form "Add subview" [list \
        {name "Subview name" entry ""} {first "First column" entry "id"} \
        [list type "Type" combo Integer [types]]] "Add" [list ::design::validate $id] \
        "A subview is a nested table: every row of this view holds its own list of rows."]]
    if {$r eq ""} return
    set mk $X($id,mk)
    apply $id [list ::store::restructure $mk [concat [::store::layout $mk] \
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
        "The data is copied into the changed column, which then moves to the end."]]
    if {$r eq ""} return
    set new [dict get $r name] ; set T [letter [dict get $r type]]
    if {$new eq $sel && $T eq [lindex $d 1]} return
    apply $id [list ::store::rebuildColumn $mk $sel $new $T]
}
proc ::design::validateEdit {id old d} { validate $id [dict merge $d [dict create old $old]] }

proc ::design::dropColumn {id} {
    variable X
    set sel [picked $id] ; if {$sel eq ""} return
    set r [::ui::ask "Drop column" "Drop '$sel' and all of its data?\n\nYou can still undo this with Roll Back until you commit." {Drop Cancel} stop]
    if {$r ne "Drop"} return
    set mk $X($id,mk)
    set new {}
    foreach c [::store::layout $mk] { if {[lindex $c 0] ne $sel} { lappend new $c } }
    if {![llength $new]} { ::ui::problem "A view needs at least one column." ; return }
    apply $id [list ::store::restructure $mk $new]
}
