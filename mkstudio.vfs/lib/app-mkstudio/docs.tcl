# docs.tcl -- the kinds of document that live in the centre tab strip.
#
#   ::qdoc    query editor + results/messages            (SSMS "query window")
#   ::ddoc    editable data grid for one view/subview    (SSMS "Edit Top 200 Rows")
#   ::design  view designer                              (SSMS "Table Designer")
#   ::helpdoc MKQL reference

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
#  Data document: editable grid over a view or subview
# ============================================================================
namespace eval ::ddoc {
    variable D
    array set D {}
}

# mk path "tag.view!3.sub"  ->  MKQL path "tag.view[3].sub"
proc ::ddoc::mkqlPath {mk} {
    regsub -all {!(\d+)\.} $mk {[\1].} p
    regsub -all {!(\d+)$} $p {[\1]} p
    return $p
}

proc ::ddoc::create {id f mk} {
    variable D
    set D($id,mk) $mk ; set D($id,limit) 1000 ; set D($id,filter) ""
    ttk::frame $f -style Surface.TFrame
    ttk::frame $f.bar -style Surface.TFrame -padding {8 6}
    ttk::button $f.bar.add -text "Add Row" -image [::icons::get plus] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::addRow $id]
    ttk::button $f.bar.del -text "Delete" -image [::icons::get minus] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::deleteRows $id]
    ttk::button $f.bar.ref -text "Refresh" -image [::icons::get refresh] -compound left \
        -style ToolSurface.TButton -command [list ::ddoc::reload $id]
    ttk::separator $f.bar.s1 -orient vertical
    ttk::label $f.bar.tl -text "Show" -style SurfaceDim.TLabel
    ttk::combobox $f.bar.top -width 7 -state readonly -values {100 1000 5000 10000 All} \
        -textvariable ::ddoc::D($id,limit)
    ttk::label $f.bar.wl -text "Filter" -style SurfaceDim.TLabel
    ttk::entry $f.bar.where -textvariable ::ddoc::D($id,filter) -width 40
    ttk::button $f.bar.apply -text "Apply" -command [list ::ddoc::reload $id]
    ttk::label $f.bar.count -text "" -style SurfaceDim.TLabel
    pack $f.bar.add $f.bar.del $f.bar.ref -side left -padx {0 2}
    pack $f.bar.s1 -side left -fill y -padx 10
    pack $f.bar.tl $f.bar.top -side left -padx {0 6}
    pack $f.bar.wl $f.bar.where $f.bar.apply -side left -padx {8 0}
    pack $f.bar.count -side right -padx 8
    ::tip::attach $f.bar.where "MKQL condition, e.g.  salary > 60000 AND name LIKE 'A%'"
    bind $f.bar.where <Return> [list ::ddoc::reload $id]
    bind $f.bar.top <<ComboboxSelected>> [list ::ddoc::reload $id]

    ::grid::create $f.g -editable 1 -commit [list ::ddoc::commit $id] \
        -drill [list ::ddoc::drill $id] -changed [list ::ddoc::updateCount $id]
    ttk::frame $f.msg -style Panel.TFrame -padding {12 5}
    ttk::label $f.msg.l -text "Double-click a cell (or press F2) to edit. Changes are held in memory until you Commit." \
        -style PanelDim.TLabel
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

proc ::ddoc::docf {id} { return [::app::docFrame $id] }

proc ::ddoc::showError {id} {
    variable D
    set f [docf $id]
    set err [expr {[info exists ::grid::G($f.g,lasterror)] ? $::grid::G($f.g,lasterror) : "Invalid value"}]
    $f.msg.l configure -text "\u2716  $err" -foreground $::theme::c(bad)
}
proc ::ddoc::note {id text {kind dim}} {
    set f [docf $id]
    $f.msg.l configure -text $text -foreground [expr {$kind eq "bad" ? $::theme::c(bad) : $::theme::c(dim)}]
}

proc ::ddoc::reload {id} {
    variable D
    set f [docf $id]
    set mk $D($id,mk)
    if {[catch {::store::layout $mk} layout]} {
        note $id "\u2716  This view no longer exists." bad
        return
    }
    set sql "SELECT * FROM [mkqlPath $mk]"
    if {[string trim $D($id,filter)] ne ""} { append sql " WHERE $D($id,filter)" }
    if {$D($id,limit) ne "All"} { append sql " LIMIT $D($id,limit)" }
    if {[catch {::mkql::run $sql} res]} {
        note $id "\u2716  $res" bad
        return
    }
    ::grid::load $f.g $res
    note $id "Double-click a cell (or press F2) to edit. Changes are held in memory until you Commit."
}

proc ::ddoc::updateCount {id} {
    set f [docf $id]
    if {![winfo exists $f.g]} return
    set total [::store::size $::ddoc::D($id,mk)]
    set shown [::grid::count $f.g]
    $f.bar.count configure -text "[::app::commas $shown] of [::app::commas $total] rows"
}

proc ::ddoc::commit {id rowid col value} {
    variable D
    set mk $D($id,mk)
    set d [::mkql::layoutLookup [::store::layout $mk] $col]
    set v [::mkql::coerce [lindex $d 0] [lindex $d 1] $value]
    ::mkql::checkWritable [lindex [split $mk .] 0]
    ::store::setCell $mk $rowid [lindex $d 0] $v
    ::app::dataChanged 0
}

proc ::ddoc::drill {id rowid sub} {
    variable D
    set mk $D($id,mk)
    ::app::openData "$mk!$rowid.$sub" "[join [lrange [split [mkqlPath $mk] .] 1 end] .]\[$rowid\].$sub"
}

proc ::ddoc::addRow {id} {
    variable D
    set f [docf $id]
    set mk $D($id,mk)
    if {[catch {
        ::mkql::checkWritable [lindex [split $mk .] 0]
        set idx [::store::appendRow $mk {} {}]
    } err]} { note $id "\u2716  $err" bad ; return }
    if {$D($id,limit) ne "All" && $idx >= $D($id,limit)} { set D($id,limit) All }
    set D($id,filter) ""
    reload $id
    ::grid::selectLast $f.g
    ::app::dataChanged 0
    ::app::setStatus "Row added \u2014 edit its cells, then Commit to save." ok
}

proc ::ddoc::deleteRows {id} {
    variable D
    set f [docf $id]
    set ids [::grid::selectedRowids $f.g]
    if {![llength $ids]} { note $id "Select one or more rows to delete." ; return }
    set n [llength $ids]
    set r [::ui::ask "Delete rows" "Delete $n row[expr {$n == 1 ? {} : {s}}] from [mkqlPath $D($id,mk)]?\n\nThis is held in memory until you commit, and Roll Back can undo it." {Delete Cancel} stop]
    if {$r ne "Delete"} return
    if {[catch {
        ::mkql::checkWritable [lindex [split $D($id,mk) .] 0]
        ::store::deleteRows $D($id,mk) $ids
    } err]} { note $id "\u2716  $err" bad ; return }
    reload $id
    ::app::dataChanged 0
    ::app::setStatus "$n row[expr {$n == 1 ? {} : {s}}] deleted." ok
}

# ============================================================================
#  Designer
# ============================================================================
namespace eval ::design {
    variable X
    array set X {}
}

proc ::design::create {id f mk} {
    variable X
    set X($id,mk) $mk
    ttk::frame $f -style Surface.TFrame
    ttk::frame $f.bar -style Surface.TFrame -padding {8 6}
    foreach {b text icon cmd} {
        addc "Add Column" plus addColumn
        adds "Add Subview" subview addSubview
        ren  "Rename" edit rename
        typ  "Change Type" design retype
        drop "Drop" trash dropColumn
    } {
        ttk::button $f.bar.$b -text $text -image [::icons::get $icon] -compound left \
            -style ToolSurface.TButton -command [list ::design::$cmd $id]
        pack $f.bar.$b -side left -padx {0 2}
    }
    ttk::label $f.bar.path -text "" -style SurfaceDim.TLabel
    pack $f.bar.path -side right -padx 8

    ttk::panedwindow $f.pw -orient vertical
    ttk::frame $f.top -style Surface.TFrame
    ttk::treeview $f.t -style Grid.Treeview -columns {type kind code} -show {tree headings} -selectmode browse
    $f.t heading #0 -text "Column name" -anchor w
    $f.t heading type -text "Data type" -anchor w
    $f.t heading kind -text "Kind" -anchor w
    $f.t heading code -text "Code" -anchor w
    $f.t column #0 -width 260 -stretch 0
    $f.t column type -width 140 -stretch 0
    $f.t column kind -width 120 -stretch 0
    $f.t column code -width 60 -stretch 1
    ttk::scrollbar $f.v -orient vertical -command [list $f.t yview]
    $f.t configure -yscrollcommand [list $f.v set]
    pack $f.v -in $f.top -side right -fill y
    pack $f.t -in $f.top -side left -fill both -expand 1

    ttk::frame $f.logf -style Surface.TFrame
    ttk::label $f.logf.h -text "  EXECUTED STATEMENTS" -style Section.TLabel -padding {8 6}
    text $f.logf.t -height 7 -font MkMono -borderwidth 0 -highlightthickness 0 -padx 12 -pady 8 \
        -state disabled -wrap word
    ::theme::reg $f.logf.t [list ::design::recolorLog %w]
    pack $f.logf.h -side top -fill x
    pack $f.logf.t -side top -fill both -expand 1
    $f.pw add $f.top -weight 3
    $f.pw add $f.logf -weight 1
    pack $f.bar -side top -fill x
    pack $f.pw -side top -fill both -expand 1
    bind $f.t <<TreeviewSelect>> [list ::design::onSelect $id]
    refresh $id
    log $id "-- Every change below runs as MKQL. Nothing is written to disk until you Commit."
    return $f
}
proc ::design::docf {id} { return [::app::docFrame $id] }
proc ::design::recolorLog {t} {
    $t configure -background $::theme::c(editor) -foreground $::theme::c(fg) \
        -selectbackground $::theme::c(sel)
    $t tag configure cmt -foreground $::theme::c(comment)
    $t tag configure stmt -foreground $::theme::c(kw)
    $t tag configure bad -foreground $::theme::c(bad)
}
proc ::design::log {id text {tag stmt}} {
    set t [docf $id].logf.t
    if {[string match --* $text]} { set tag cmt }
    $t configure -state normal ; $t insert end "$text\n" $tag ; $t configure -state disabled ; $t see end
}

proc ::design::refresh {id} {
    variable X
    set f [docf $id]
    set t $f.t
    set sel [$t selection]
    $t delete [$t children {}]
    set mk $X($id,mk)
    $f.bar.path configure -text [::ddoc::mkqlPath $mk]
    if {[catch {::store::layout $mk} layout]} return
    fillTree $t {} $layout {} 0
    if {$sel ne "" && [$t exists $sel]} { $t selection set $sel }
}
proc ::design::fillTree {t parent layout chain depth} {
    foreach c $layout {
        lassign $c n type sub
        set id [join [concat $chain [list $n]] "/"]
        $t insert $parent end -id $id -text " $n" -image [::icons::get col_$type] -open 1 \
            -values [list [::store::typeName $type] [expr {$type eq "V" ? "subview" : "column"}] $type]
        if {$type eq "V"} { fillTree $t $id $sub [concat $chain [list $n]] [expr {$depth+1}] }
    }
}
proc ::design::selected {id} {
    set sel [[docf $id].t selection]
    if {$sel eq ""} { return "" }
    return $sel
}
proc ::design::onSelect {id} {}

# run an MKQL statement and log it
proc ::design::run {id sql} {
    set path [::ddoc::mkqlPath $::design::X($id,mk)]
    log $id "$sql;"
    if {[catch {::mkql::run $sql} res]} {
        log $id "-- error: $res" bad
        ::ui::problem $res
        return 0
    }
    log $id "-- [dict get $res text]"
    refresh $id
    ::app::dataChanged 1
    return 1
}
proc ::design::q {name} { return "\"[string map {\" \"\"} $name]\"" }
proc ::design::topLevelSelection {id} {
    set sel [selected $id]
    if {$sel eq ""} { ::ui::inform "Select a column" "Select a column in the list first." ; return "" }
    if {[string first / $sel] >= 0} {
        ::ui::inform "Nested column" "This column belongs to a subview. Open the parent view's subview in the data editor, or use ALTER VIEW from a query window." ; return ""
    }
    return $sel
}
proc ::design::typeChoices {} { return {String Integer Long Float Double Bytes} }
proc ::design::typeWord {label} { return [string tolower $label] }

proc ::design::addColumn {id} {
    variable X
    set r [::ui::formResult [::ui::form "Add column" [list \
        {name "Column name" entry ""} \
        [list type "Data type" combo String [typeChoices]]] "Add Column" \
        [list ::design::validateName $id]]]
    if {$r eq ""} return
    run $id "ALTER VIEW [::ddoc::mkqlPath $X($id,mk)] ADD [q [dict get $r name]] [typeWord [dict get $r type]]"
}
proc ::design::addSubview {id} {
    variable X
    set r [::ui::formResult [::ui::form "Add subview" [list \
        {name "Subview name" entry ""} \
        {first "First column" entry "id"} \
        [list type "Column type" combo Integer [typeChoices]]] "Add Subview" \
        [list ::design::validateName $id] \
        "A subview is a nested table: every row of this view gets its own list of rows."]]
    if {$r eq ""} return
    run $id "ALTER VIEW [::ddoc::mkqlPath $X($id,mk)] ADD [q [dict get $r name]] ([q [dict get $r first]] [typeWord [dict get $r type]])"
}
proc ::design::validateName {id d} {
    set n [dict get $d name]
    if {$n eq ""} { return "Please enter a name." }
    if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $n]} { return "Use letters, digits and underscores only (and don't start with a digit)." }
    return ""
}
proc ::design::rename {id} {
    variable X
    set sel [topLevelSelection $id] ; if {$sel eq ""} return
    set r [::ui::formResult [::ui::form "Rename column" [list [list name "New name" entry $sel]] "Rename" \
        [list ::design::validateName $id] \
        "Metakit identifies a column by name and type, so renaming copies the data to a new column. The renamed column moves to the end of the layout."]]
    if {$r eq ""} return
    run $id "ALTER VIEW [::ddoc::mkqlPath $X($id,mk)] RENAME [q $sel] TO [q [dict get $r name]]"
}
proc ::design::retype {id} {
    variable X
    set sel [topLevelSelection $id] ; if {$sel eq ""} return
    set cur [[docf $id].t set $sel type]
    if {$cur eq "Subview"} { ::ui::inform "Subview" "A subview has no data type to change." ; return }
    set r [::ui::formResult [::ui::form "Change data type" [list \
        [list type "New type for '$sel'" combo $cur [typeChoices]]] "Change Type" "" \
        "Values are converted where possible (text that isn't a number becomes 0). The column moves to the end of the layout."]]
    if {$r eq ""} return
    run $id "ALTER VIEW [::ddoc::mkqlPath $X($id,mk)] MODIFY [q $sel] [typeWord [dict get $r type]]"
}
proc ::design::dropColumn {id} {
    variable X
    set sel [topLevelSelection $id] ; if {$sel eq ""} return
    set a [::ui::ask "Drop column" "Drop column '$sel' and all of its data?\n\nThis is held in memory until you commit, and Roll Back can undo it." {Drop Cancel} stop]
    if {$a ne "Drop"} return
    run $id "ALTER VIEW [::ddoc::mkqlPath $X($id,mk)] DROP [q $sel]"
}

# ============================================================================
#  Help / reference document
# ============================================================================
namespace eval ::helpdoc {}

proc ::helpdoc::create {id f} {
    ttk::frame $f -style Surface.TFrame
    text $f.t -wrap word -font MkUI -borderwidth 0 -highlightthickness 0 -padx 40 -pady 24 \
        -cursor arrow -spacing1 3 -spacing3 3 -yscrollcommand [list $f.v set]
    ttk::scrollbar $f.v -orient vertical -command [list $f.t yview]
    pack $f.v -side right -fill y
    pack $f.t -side left -fill both -expand 1
    ::theme::reg $f.t [list ::helpdoc::recolor %w]
    set t $f.t
    foreach {kind text} [content] {
        switch -- $kind {
            h1 { $t insert end "$text\n" h1 }
            h2 { $t insert end "\n$text\n" h2 }
            p  { $t insert end "$text\n" p }
            c  { $t insert end "$text\n" code }
        }
    }
    $t configure -state disabled
    return $f
}
proc ::helpdoc::recolor {t} {
    $t configure -background $::theme::c(surface) -foreground $::theme::c(fg) -selectbackground $::theme::c(sel) \
        -selectforeground $::theme::c(selFg)
    $t tag configure h1 -font MkHuge -foreground $::theme::c(fg) -spacing3 8
    $t tag configure h2 -font MkTitle -foreground $::theme::c(accent) -spacing1 10
    $t tag configure p -foreground $::theme::c(fg) -lmargin1 0 -lmargin2 0
    $t tag configure code -font MkMono -foreground $::theme::c(str) -background $::theme::c(editor) \
        -lmargin1 16 -lmargin2 16 -rmargin 16 -spacing1 1 -spacing3 1
}
proc ::helpdoc::content {} {
    return {
h1 "MKQL Reference"
p "MKQL is a small SQL-style language built around Metakit's model: a datafile holds named views (tables); a view has typed columns; and a column can be a subview \u2014 a whole nested table stored inside every row."
p "Run a script with F5 (or Ctrl+E). Select some text first to run only that. Statements are separated by semicolons. Ctrl+Space completes view and column names."

h2 "Paths"
p "A view is  view  or  db.view  (db is the database name shown in the explorer). A subview of one row is written with the row number:"
c "employees\[3\].skills          -- subview of row 3\ndemo.orders\[0\].lines         -- qualified with the database"
p "Every row also has a hidden  _rowid  column holding its position."

h2 "Querying"
c "SELECT * FROM employees;\nSELECT TOP 10 name, salary FROM employees ORDER BY salary DESC;\nSELECT dept, COUNT(*) AS people, AVG(salary) AS avg_pay\n  FROM employees\n  WHERE active = 1 AND name LIKE 'A%'\n  GROUP BY dept HAVING COUNT(*) > 2\n  ORDER BY avg_pay DESC LIMIT 5;\nSELECT DISTINCT status FROM orders;\nSELECT skill, level FROM employees\[0\].skills;"
p "WHERE supports  = <> < <= > >=  AND OR NOT  LIKE (% and _)  IN (...)  BETWEEN x AND y  IS NULL (empty). A subview column used in an expression is its number of rows:"
c "SELECT name FROM employees WHERE skills >= 3;"
p "Aggregates: COUNT SUM AVG MIN MAX. Functions: UPPER LOWER LENGTH TRIM SUBSTR REPLACE CONCAT ROUND ABS FLOOR CEIL COALESCE NOW.  || joins text.  SELECT with no FROM works as a calculator."
p "In a result grid, double-click a  \u25B8 N rows  cell to open that subview."

h2 "Changing data"
c "INSERT INTO products (sku, name, price) VALUES ('X-1', 'Test', 9.5), ('X-2', 'Two', 3);\nINSERT INTO employees\[0\].skills (skill, level) VALUES ('Go', 3);\nUPDATE products SET price = price * 1.1 WHERE stock < 20;\nDELETE FROM orders WHERE status = 'returned';"
p "Changes live in memory. The explorer shows the database with a pending count; use Commit (Ctrl+Shift+S) to write to disk, or Roll Back to throw them away."

h2 "Structure"
c "CREATE VIEW notes (id int, body string, tags (tag string, weight float));\nALTER VIEW notes ADD pinned int;\nALTER VIEW notes RENAME body TO text;\nALTER VIEW notes MODIFY id long;\nALTER VIEW notes DROP pinned;\nDROP VIEW notes;"
p "Column types: string, int, long, float, double, bytes. A column followed by a parenthesised list is a subview. Metakit identifies a column by name and type, so RENAME and MODIFY copy the data into a new column that ends up last in the layout."

h2 "Inspecting"
c "SHOW DATABASES;\nSHOW VIEWS;\nDESCRIBE employees;\nUSE demo;       -- default database for this query window\nCOMMIT;\nROLLBACK;"

h2 "Keyboard"
c "F5 / Ctrl+E      execute (selection if any)\nCtrl+F5          parse only\nEsc              cancel a running query\nCtrl+N           new query      Ctrl+O  open database\nCtrl+Shift+S     commit         Ctrl+S  save script\nCtrl+W           close tab      Ctrl+Tab  next tab\nF8 / F4          toggle explorer / properties\nCtrl+R           toggle results pane\nCtrl+/           comment lines  Ctrl+Space  complete\nCtrl + wheel     zoom editor"
    }
}
