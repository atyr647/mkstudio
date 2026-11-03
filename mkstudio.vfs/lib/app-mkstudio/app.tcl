# app.tcl -- MK Studio main window and application logic.

namespace eval ::app {
    variable version 1.0
    variable A            ;# per-document info:  A(type,id) A(title,id) A(saved,id) A(file,id)
    array set A {}
    variable seq 0
    variable qn 0
    variable cfg
    array set cfg {
        theme dark recent {} geometry 1360x820 showEx 1 showPr 0 exWidth 280 prWidth 280
        fontSize 11 lastDir ""
    }
    variable busyFlag 0
    variable root ""
    variable dbVar ""
    variable themeVar dark
    variable status
    array set status {}
}

# ============================================================================
#  small helpers
# ============================================================================
proc ::app::commas {n} {
    while {[regsub {^(-?\d+)(\d{3})} $n {\1,\2} n]} {}
    return $n
}
proc ::app::pump {} { update }

proc ::app::settingsFile {} {
    if {[info exists ::env(APPDATA)]} {
        set d [file join $::env(APPDATA) MKStudio]
        catch {file mkdir $d}
        return [file join $d settings.tcl]
    }
    foreach v {HOME USERPROFILE} {
        if {[info exists ::env($v)]} { return [file join $::env($v) .mkstudio.tcl] }
    }
    return ""
}
proc ::app::loadSettings {} {
    variable cfg
    set f [settingsFile]
    if {$f eq "" || ![file exists $f]} return
    if {[catch {
        set in [open $f r] ; fconfigure $in -encoding utf-8
        set data [read $in] ; close $in
        if {[llength $data] % 2 == 0} {
            foreach {k v} $data { if {[info exists cfg($k)]} { set cfg($k) $v } }
        }
    }]} return
}
proc ::app::saveSettings {} {
    variable cfg
    set f [settingsFile]
    if {$f eq ""} return
    catch {
        set cfg(geometry) [wm geometry .]
        set out [open $f w] ; fconfigure $out -encoding utf-8
        puts $out [array get cfg] ; close $out
    }
}
proc ::app::addRecent {path} {
    variable cfg
    set path [file normalize $path]
    set l [list $path]
    foreach r $cfg(recent) { if {$r ne $path && [llength $l] < 10} { lappend l $r } }
    set cfg(recent) $l
    set cfg(lastDir) [file dirname $path]
    rebuildRecent
}

# ============================================================================
#  status bar
# ============================================================================
proc ::app::setStatus {msg {kind ""}} {
    set c [expr {$kind eq "ok" ? "ok" : $kind eq "warn" ? "warn" : $kind eq "bad" ? "bad" : "dim"}]
    .sb.dot configure -foreground $::theme::c($c)
    .sb.msg configure -text $msg
}
proc ::app::setCursor {l c} { .sb.pos configure -text "Ln $l, Col $c" }
proc ::app::setRunInfo {ms rows} {
    set t "$ms ms"
    if {$rows ne ""} { append t "  ·  [commas $rows] row[expr {$rows == 1 ? {} : {s}}]" }
    .sb.run configure -text $t
}
proc ::app::pendingTotal {} {
    set n 0
    foreach t [::store::tags] { incr n [::store::dirty $t] }
    return $n
}
proc ::app::updatePending {} {
    set n [pendingTotal]
    if {$n > 0} {
        .sb.pend configure -text "●  $n unsaved change[expr {$n == 1 ? {} : {s}}]" -foreground $::theme::c(warn)
    } else { .sb.pend configure -text "" }
    foreach b {commit rollback} { .tb.$b state [expr {$n > 0 ? "!disabled" : "disabled"}] }
}

proc ::app::busy {flag} {
    variable busyFlag
    set busyFlag $flag
    if {$flag} {
        . configure -cursor watch
        .tb.run configure -text "Stop" -image [::icons::get stop]
        setStatus "Running..." warn
    } else {
        . configure -cursor ""
        .tb.run configure -text "Execute" -image [::icons::get play]
    }
}

proc ::app::cancel {} {
    variable busyFlag
    if {$busyFlag} { set ::mkql::cancel 1 ; setStatus "Cancelling…" warn }
}

# ============================================================================
#  window construction
# ============================================================================
proc ::app::buildMenus {} {
    frame .mb -borderwidth 0 -highlightthickness 0
    ::theme::reg .mb {%w configure -background $::theme::c(bg)}
    foreach {k label} {file File edit Edit view View query Query help Help} {
        ttk::menubutton .mb.$k -text $label -style Menubar.TMenubutton -menu .mb.$k.m
        menu .mb.$k.m -tearoff 0 -postcommand [list ::app::menuState $k]
        ::theme::reg .mb.$k.m {::theme::menu %w}
        pack .mb.$k -side left
    }

    set m .mb.file.m
    $m add command -label "New Query" -accelerator "Ctrl+N" -command ::app::newQuery
    $m add command -label "Open Script..." -command ::app::openScript
    $m add command -label "Save Script" -accelerator "Ctrl+S" -command ::app::saveScript
    $m add separator
    $m add command -label "Open Database..." -accelerator "Ctrl+O" -command ::app::openDB
    $m add cascade -label "Open Recent" -menu $m.recent
    menu $m.recent -tearoff 0
    ::theme::reg $m.recent {::theme::menu %w}
    $m add command -label "New Database..." -command ::app::newDB
    $m add command -label "New Sample Database..." -command ::app::newSample
    $m add command -label "Close Database" -command ::app::closeSelectedDB
    $m add separator
    $m add command -label "New View..." -command ::app::newView
    $m add command -label "Import CSV into View..." -command ::app::importCsv
    $m add separator
    $m add command -label "Commit Changes" -accelerator "Ctrl+Shift+S" -command ::app::commit
    $m add command -label "Roll Back Changes" -command ::app::rollback
    $m add separator
    $m add command -label "Close Tab" -accelerator "Ctrl+W" -command ::app::closeCurrent
    $m add command -label "Exit" -command ::app::quit

    set m .mb.edit.m
    $m add command -label "Undo" -accelerator "Ctrl+Z" -command {::app::editEvent <<Undo>>}
    $m add command -label "Redo" -accelerator "Ctrl+Y" -command {::app::editEvent <<Redo>>}
    $m add separator
    $m add command -label "Cut" -accelerator "Ctrl+X" -command {::app::editEvent <<Cut>>}
    $m add command -label "Copy" -accelerator "Ctrl+C" -command {::app::editEvent <<Copy>>}
    $m add command -label "Paste" -accelerator "Ctrl+V" -command {::app::editEvent <<Paste>>}
    $m add command -label "Select All" -accelerator "Ctrl+A" -command {::app::editEvent <<SelectAll>>}
    $m add separator
    $m add command -label "Toggle Comment" -accelerator "Ctrl+/" -command ::app::toggleComment

    set m .mb.view.m
    $m add checkbutton -label "Object Explorer" -accelerator F8 -variable ::app::cfg(showEx) -command ::app::applyPanes
    $m add checkbutton -label "Properties" -accelerator F4 -variable ::app::cfg(showPr) -command ::app::applyPanes
    $m add command -label "Show / Hide Results" -accelerator "Ctrl+R" -command ::app::toggleResults
    $m add separator
    $m add radiobutton -label "Dark Theme" -variable ::app::themeVar -value dark -command {::app::setTheme dark}
    $m add radiobutton -label "Light Theme" -variable ::app::themeVar -value light -command {::app::setTheme light}
    $m add separator
    $m add command -label "Larger Text" -accelerator "Ctrl++" -command {::editor::zoom {} 1}
    $m add command -label "Smaller Text" -accelerator "Ctrl+-" -command {::editor::zoom {} -1}
    $m add command -label "Reset Text Size" -command ::editor::zoomReset
    $m add separator
    $m add command -label "Refresh Explorer" -accelerator F5 -command ::explorer::refresh

    set m .mb.query.m
    $m add command -label "Execute" -accelerator "F5" -command ::app::execute
    $m add command -label "Cancel" -accelerator "Esc" -command ::app::cancel
    $m add separator
    $m add command -label "Export Results as CSV..." -command ::app::exportCsv

    set m .mb.help.m
    $m add command -label "About MK Studio" -command ::app::about
}

proc ::app::menuState {k} {
    set hasDb [expr {[llength [::store::tags]] > 0}]
    set q [currentQuery]
    set pend [expr {[pendingTotal] > 0}]
    proc ::app::_en {m item on} { $m entryconfigure $item -state [expr {$on ? "normal" : "disabled"}] }
    switch -- $k {
        file {
            set m .mb.file.m
            _en $m "Commit Changes" $pend ; _en $m "Roll Back Changes" $pend
            _en $m "Close Database" $hasDb ; _en $m "New View..." $hasDb ; _en $m "Import CSV into View..." $hasDb
            _en $m "Save Script" [expr {$q ne ""}]
        }
        query {
            set m .mb.query.m
            _en $m Execute [expr {$q ne "" && !$::app::busyFlag}]
            _en $m Cancel $::app::busyFlag
            _en $m "Export Results as CSV..." [expr {$q ne ""}]
        }
    }
}

proc ::app::rebuildRecent {} {
    variable cfg
    set m .mb.file.m.recent
    if {![winfo exists $m]} return
    $m delete 0 end
    if {![llength $cfg(recent)]} { $m add command -label "(none)" -state disabled ; return }
    foreach r $cfg(recent) {
        $m add command -label "[file tail $r]    [file dirname $r]" -command [list ::app::openDB $r]
    }
    $m add separator
    $m add command -label "Clear List" -command {set ::app::cfg(recent) {} ; ::app::rebuildRecent}
}

proc ::app::tbtn {name text icon cmd tip {style Tool.TButton}} {
    ttk::button .tb.$name -text $text -image [::icons::get $icon] -compound [expr {$text eq "" ? "image" : "left"}] \
        -style $style -command $cmd -takefocus 0
    ::tip::attach .tb.$name $tip
    pack .tb.$name -side left -padx 1 -pady 3
}
proc ::app::tsep {n} {
    ttk::separator .tb.sep$n -orient vertical
    pack .tb.sep$n -side left -fill y -padx 8 -pady 8
}

proc ::app::buildToolbar {} {
    ttk::frame .tb -padding {8 0}
    tbtn newq "New Query" docnew ::app::newQuery "New query window  (Ctrl+N)"
    tbtn open "" open ::app::openDB "Open a database  (Ctrl+O)"
    tsep 1
    ttk::label .tb.dl -text "Database" -style Dim.TLabel
    ttk::combobox .tb.db -state readonly -width 16 -textvariable ::app::dbVar -takefocus 0
    pack .tb.dl -side left -padx {2 6}
    pack .tb.db -side left
    bind .tb.db <<ComboboxSelected>> {::app::dbPicked}
    ::tip::attach .tb.db "Database this query runs against"
    tsep 2
    tbtn run "Execute" play ::app::runOrStop "Run the query, or just the selected text  (F5)" Run.TButton
    tsep 3
    tbtn commit "Commit" commit ::app::commit "Save pending changes to the file  (Ctrl+Shift+S)"
    tbtn rollback "Roll Back" rollback ::app::rollback "Discard pending changes"
}
proc ::app::runOrStop {} {
    variable busyFlag
    if {$busyFlag} { cancel } else { execute }
}

proc ::app::buildStatus {} {
    frame .sb -borderwidth 0 -highlightthickness 0 -height 26
    ::theme::reg .sb {%w configure -background $::theme::c(accentDim)}
    foreach n {dot msg pend run pos} { label .sb.$n -borderwidth 0 -font MkSmall }
    .sb.dot configure -text "●" -padx 12
    foreach n {dot msg pend run pos} {
        ::theme::reg .sb.$n [list %w configure -background $::theme::c(accentDim) -foreground $::theme::c(fg)]
    }
    ::theme::reg .sb.run {%w configure -foreground $::theme::c(dim)}
    ::theme::reg .sb.pos {%w configure -foreground $::theme::c(dim)}
    pack .sb.dot .sb.msg -side left
    pack .sb.pos -side right -padx 14
    pack .sb.run -side right -padx 8
    pack .sb.pend -side right -padx 8
    pack propagate .sb 0
    ::tip::attach .sb.pend "Changes are held in memory until you commit them  (Ctrl+Shift+S)"
}

proc ::app::buildMain {} {
    ttk::panedwindow .main -orient horizontal
    ::explorer::create .main.ex -action ::app::explorerAction -select ::app::onExplorerSelect
    ttk::frame .main.center
    ::tabs::create .main.center.tabs -list 1 -select ::app::tabSelected -close ::app::closeDoc
    ttk::frame .main.center.docs -style Surface.TFrame
    pack .main.center.tabs -side top -fill x
    pack .main.center.docs -side top -fill both -expand 1
    grid rowconfigure .main.center.docs 0 -weight 1 ; grid columnconfigure .main.center.docs 0 -weight 1
    ::props::create .main.pr
    buildWelcome
    .main add .main.ex -weight 0
    .main add .main.center -weight 1
    .main add .main.pr -weight 0
}

# ============================================================================
#  welcome page
# ============================================================================
proc ::app::buildWelcome {} {
    set w .main.center.docs.welcome
    ttk::frame $w -style Surface.TFrame
    grid $w -row 0 -column 0 -sticky nsew
    ttk::frame $w.c -style Surface.TFrame
    place $w.c -relx 0.5 -rely 0.42 -anchor center
    ttk::label $w.c.logo -image [::icons::logo] -style Surface.TLabel
    ttk::label $w.c.t -text "MK Studio" -style Huge.TLabel
    ttk::label $w.c.s -text "Browse, query and edit Metakit databases" -style SurfaceDim.TLabel
    grid $w.c.logo -pady {0 8}
    grid $w.c.t
    grid $w.c.s -pady {2 22}
    set r 3
    foreach {text cmd} {
        "Open a database..."     ::app::openDB
        "Try the sample database..." ::app::newSample
        "New query"              ::app::newQuery
    } {
        ttk::button $w.c.b$r -text $text -style Link.TButton -command $cmd -cursor hand2
        grid $w.c.b$r -row $r -sticky w -padx 70
        incr r
    }
    ttk::label $w.c.rh -text "RECENT" -style Section.TLabel
    grid $w.c.rh -row $r -sticky w -padx 70 -pady {22 4}
    ttk::frame $w.c.recent -style Surface.TFrame
    grid $w.c.recent -row [expr {$r+1}] -sticky w -padx 70
    ::theme::reg $w.c.rh {%w configure -background $::theme::c(surface) -foreground $::theme::c(dim)}
}

proc ::app::refreshWelcome {} {
    variable cfg
    set f .main.center.docs.welcome.c.recent
    if {![winfo exists $f]} return
    foreach c [winfo children $f] { destroy $c }
    set i 0
    foreach r $cfg(recent) {
        if {$i >= 5} break
        ttk::button $f.r$i -text "[file tail $r]   [file dirname $r]" -style Link.TButton \
            -command [list ::app::openDB $r] -cursor hand2
        pack $f.r$i -anchor w
        incr i
    }
    if {$i == 0} { ttk::label $f.none -text "No recent files" -style SurfaceDim.TLabel ; pack $f.none -anchor w }
}

# ============================================================================
#  panes, theme
# ============================================================================
proc ::app::applyPanes {} {
    variable cfg
    foreach {key win idx} {showEx .main.ex 0 showPr .main.pr 2} {
        set present [expr {[lsearch -exact [.main panes] $win] >= 0}]
        if {$cfg($key) && !$present} {
            if {$key eq "showEx"} { .main insert 0 $win -weight 0 } else { .main add $win -weight 0 }
            update idletasks
            if {$key eq "showEx"} { catch {.main sashpos 0 $cfg(exWidth)} }
            if {$key eq "showPr"} { catch {.main sashpos [expr {[llength [.main panes]] - 2}] [expr {[winfo width .main] - $cfg(prWidth)}]} }
        } elseif {!$cfg($key) && $present} {
            if {$key eq "showEx"} { set cfg(exWidth) [lindex [.main sashpos 0] 0] }
            if {$key eq "showPr"} { set cfg(prWidth) [expr {[winfo width .main] - [.main sashpos [expr {[llength [.main panes]] - 2}]]}] }
            .main forget $win
        }
    }
}
proc ::app::togglePane {key} {
    variable cfg
    set cfg($key) [expr {!$cfg($key)}]
    applyPanes
}
proc ::app::setTheme {name} {
    variable cfg ; variable themeVar
    set cfg(theme) $name ; set themeVar $name
    ::theme::apply $name
    updatePending
    refreshWelcome
}
proc ::app::toggleTheme {} { setTheme [expr {$::theme::name eq "dark" ? "light" : "dark"}] }

# ============================================================================
#  documents
# ============================================================================
proc ::app::docFrame {id} { return .main.center.docs.f$id }
proc ::app::newId {} { variable seq ; return d[incr seq] }
proc ::app::docs {} { return [::tabs::ids .main.center.tabs] }
proc ::app::currentDoc {} { return [::tabs::current .main.center.tabs] }
proc ::app::docType {id} { variable A ; if {[info exists A(type,$id)]} { return $A(type,$id) } ; return "" }
proc ::app::currentQuery {} {
    set id [currentDoc]
    if {$id ne "" && [docType $id] eq "query"} { return $id }
    return ""
}

proc ::app::addDoc {id type title icon} {
    variable A
    set A(type,$id) $type ; set A(title,$id) $title ; set A(file,$id) "" ; set A(saved,$id) ""
    ::tabs::add .main.center.tabs $id $title $icon
    grid [docFrame $id] -row 0 -column 0 -sticky nsew
    showDoc $id
}

proc ::app::showDoc {id} {
    variable A
    if {![info exists A(type,$id)]} return
    set f [docFrame $id]
    raise $f
    ::tabs::select .main.center.tabs $id
    docSelected $id
    switch -- $A(type,$id) {
        query { focus $f.ed.t ; ::editor::cursorMoved $f.ed }
        data  { focus $f.g.t }
    }
}
proc ::app::tabSelected {id} { showDoc $id }

proc ::app::docSelected {id} {
    variable dbVar
    updateDbCombo
    set isQ [expr {[docType $id] eq "query"}]
    if {$isQ} {
        set dbVar [::qdoc::db $id]
        if {$dbVar eq "" && [llength [::store::tags]] == 1} { set dbVar [lindex [::store::tags] 0] }
        .tb.db state !disabled
    } else {
        set dbVar ""
        .tb.db state disabled
    }
    .tb.run state [expr {$isQ || $::app::busyFlag ? "!disabled" : "disabled"}]
    if {!$isQ} { .sb.pos configure -text "" }
}

proc ::app::updateDbCombo {} {
    variable dbVar
    set tags [::store::tags]
    .tb.db configure -values $tags
    if {$dbVar ne "" && [lsearch -exact $tags $dbVar] < 0} { set dbVar "" }
}
proc ::app::dbPicked {} {
    variable dbVar
    set q [currentQuery]
    if {$q ne ""} { ::qdoc::setDb $q $dbVar }
}
# a query without an explicit database uses the only open one
proc ::app::dbAutoSelect {id} {
    set cur [::qdoc::db $id]
    set tags [::store::tags]
    if {$cur ne "" && [lsearch -exact $tags $cur] < 0} { set cur "" }
    if {$cur eq "" && [llength $tags] == 1} { set cur [lindex $tags 0] }
    ::qdoc::setDb $id $cur
}

proc ::app::newQuery {{text ""} {db ""} {run 0}} {
    variable A ; variable qn
    set id [newId]
    incr qn
    if {$db eq ""} {
        set db [explorerDb]
    }
    ::qdoc::create $id [docFrame $id] $db $text
    addDoc $id query "Query $qn" doc
    set A(saved,$id) $text
    set t [docFrame $id].ed.t
    # Tk's emacs-style Ctrl bindings would otherwise fight with ours inside the editor
    foreach {k cmd} {
        Control-n ::app::newQuery  Control-o ::app::openDB  Control-e ::app::execute
        Control-w ::app::closeCurrent  Control-r ::app::toggleResults
    } { bind $t <$k> "$cmd ; break" }
    if {$run} { ::qdoc::execute $id }
    return $id
}
proc ::app::explorerDb {} {
    set m [::explorer::selected]
    if {$m ne "" && [dict exists $m tag]} { return [dict get $m tag] }
    set tags [::store::tags]
    if {[llength $tags] == 1} { return [lindex $tags 0] }
    return ""
}

proc ::app::openData {mk title} {
    # focus an existing tab for the same path
    variable A
    foreach id [docs] {
        if {[docType $id] eq "data" && $A(path,$id) eq $mk} { showDoc $id ; return $id }
    }
    set id [newId]
    set A(path,$id) $mk
    ::ddoc::create $id [docFrame $id] $mk
    addDoc $id data $title edit
    set A(path,$id) $mk
    return $id
}
proc ::app::openDesign {mk title} {
    variable A
    foreach id [docs] {
        if {[docType $id] eq "design" && $A(path,$id) eq $mk} { showDoc $id ; return $id }
    }
    set id [newId]
    set A(path,$id) $mk
    ::design::create $id [docFrame $id] $mk
    addDoc $id design "$title (design)" design
    set A(path,$id) $mk
    return $id
}
proc ::app::docEdited {id} {
    variable A
    set f [docFrame $id]
    if {![info exists A(saved,$id)] || ![winfo exists $f.ed]} return
    set text [::editor::get $f.ed]
    ::tabs::setDirty .main.center.tabs $id [expr {$text ne $A(saved,$id) && !($text eq "" && $A(file,$id) eq "")}]
}

proc ::app::closeCurrent {} {
    set id [currentDoc]
    if {$id ne ""} { closeDoc $id }
}

proc ::app::closeDoc {id {force 0}} {
    variable A
    if {![info exists A(type,$id)]} { return 1 }
    set f [docFrame $id]
    if {!$force && $A(type,$id) eq "query"} {
        set text [string trim [::editor::get $f.ed]]
        if {$text ne "" && [::editor::get $f.ed] ne $A(saved,$id)} {
            set r [::ui::ask "Save changes?" "Save changes to '$A(title,$id)' before closing?" {Save "Don't Save" Cancel} help]
            if {$r eq "" || $r eq "Cancel"} { return 0 }
            if {$r eq "Save"} { if {![saveScript 0 $id]} { return 0 } }
        }
    }
    set next [::tabs::remove .main.center.tabs $id]
    destroy $f
    unset -nocomplain A(type,$id) A(title,$id) A(file,$id) A(saved,$id) A(path,$id)
    if {$next ne ""} { showDoc $next } else { raise .main.center.docs.welcome ; docSelected "" }
    update idletasks
    return 1
}

# ============================================================================
#  databases
# ============================================================================
proc ::app::openDB {{path ""}} {
    variable cfg
    if {$path eq ""} {
        set paths [tk_getOpenFile -title "Open Metakit database" -multiple 1 \
            -initialdir [expr {$cfg(lastDir) ne "" && [file isdirectory $cfg(lastDir)] ? $cfg(lastDir) : [pwd]}] \
            -filetypes {{{Metakit datafiles} {.mk .db .dat .kit .mkd}} {{All files} *}}]
    } else { set paths [list $path] }
    foreach p $paths { openOne $p }
}
proc ::app::openOne {path} {
    if {[catch {::store::openFile $path} tag]} {
        ::ui::problem "Could not open the file as a Metakit database:\n\n$path\n\n$tag" "Open database"
        return ""
    }
    addRecent $path
    afterDbChange
    setStatus "Opened '$tag'  ([file tail $path])" ok
    return $tag
}
proc ::app::newDB {} {
    variable cfg
    set path [tk_getSaveFile -title "Create Metakit database" -defaultextension .mk -confirmoverwrite 0 \
        -initialdir [expr {$cfg(lastDir) ne "" && [file isdirectory $cfg(lastDir)] ? $cfg(lastDir) : [pwd]}] \
        -filetypes {{{Metakit datafiles} {.mk}} {{All files} *}}]
    if {$path eq ""} return
    if {[file exists $path] && [file size $path] > 0} { openOne $path ; return }
    if {[catch {
        set tag [::store::openFile $path -create]
        ::store::commit $tag
    } err]} { ::ui::problem "Could not create the database:\n\n$err" ; return }
    addRecent $path
    afterDbChange
    setStatus "Created '$tag'. Use CREATE VIEW or New View to add data." ok
}
proc ::app::newSample {} {
    variable cfg ; variable A
    set path [tk_getSaveFile -title "Save sample database as" -defaultextension .mk -initialfile sample.mk \
        -initialdir [expr {$cfg(lastDir) ne "" && [file isdirectory $cfg(lastDir)] ? $cfg(lastDir) : [pwd]}] \
        -filetypes {{{Metakit datafiles} {.mk}} {{All files} *}}]
    if {$path eq ""} return
    set path [file normalize $path]
    foreach t [::store::tags] { if {[::store::path $t] eq $path} { if {![closeDB $t]} return } }
    if {[catch {
        file delete $path
        set tag [::store::createSample $path]
    } err]} { ::ui::problem "Could not create the sample database:\n\n$err" ; return }
    addRecent $path
    afterDbChange
    setStatus "Sample database '$tag' created: employees (with a skills subview), departments, products, orders (with a lines subview)." ok
    set text "-- Sample database. Press F5 to run the whole script, or select a statement and press F5.\nSELECT TOP 10 name, title, salary\nFROM employees\nORDER BY salary DESC;\n\nSELECT dept, COUNT(*) AS people, ROUND(AVG(salary), 0) AS avg_salary\nFROM employees\nGROUP BY dept\nORDER BY avg_salary DESC;\n\n-- skills is a subview (a nested table in every row).\n-- Double-click a ▸ cell in the grid to open it.\nSELECT id, name, skills FROM employees WHERE skills >= 3;"
    set id [newQuery $text $tag 1]
}

proc ::app::afterDbChange {} {
    ::explorer::refresh
    updateDbCombo
    updatePending
    foreach id [docs] {
        if {[docType $id] eq "query"} { dbAutoSelect $id }
    }
    docSelected [currentDoc]
    refreshWelcome
}

proc ::app::closeSelectedDB {} {
    set m [::explorer::selected]
    set tag ""
    if {$m ne "" && [dict exists $m tag]} { set tag [dict get $m tag] }
    if {$tag eq "" && [llength [::store::tags]] == 1} { set tag [lindex [::store::tags] 0] }
    if {$tag eq ""} { setStatus "Select a database in the Object Explorer first." warn ; return }
    closeDB $tag
}

# returns 1 when closed, 0 when the user cancelled
proc ::app::closeDB {tag {discard 0}} {
    variable A
    if {![::store::exists $tag]} { return 1 }
    if {!$discard && [::store::dirty $tag] > 0} {
        set r [::ui::ask "Close database" "'$tag' has [::store::dirty $tag] uncommitted change(s).\n\nCommit them to disk before closing?" {Commit "Discard" Cancel} help]
        if {$r eq "" || $r eq "Cancel"} { return 0 }
        if {$r eq "Commit"} {
            if {[catch {::store::commit $tag} err]} { ::ui::problem "Commit failed:\n\n$err" ; return 0 }
        }
    }
    foreach id [docs] {
        if {[docType $id] in {data design} && [lindex [split $A(path,$id) .] 0] eq $tag} { closeDoc $id 1 }
    }
    ::store::closeFile $tag
    afterDbChange
    setStatus "Closed '$tag'." ""
    return 1
}

proc ::app::targetTag {} {
    set m [::explorer::selected]
    if {$m ne "" && [dict exists $m tag]} { return [dict get $m tag] }
    set q [currentQuery]
    if {$q ne "" && [::qdoc::db $q] ne ""} { return [::qdoc::db $q] }
    set tags [::store::tags]
    if {[llength $tags] == 1} { return [lindex $tags 0] }
    return ""
}

proc ::app::commit {{tag ""}} {
    if {$tag eq ""} {
        set tags {}
        foreach t [::store::tags] { if {[::store::dirty $t] > 0} { lappend tags $t } }
        if {![llength $tags]} { setStatus "Nothing to commit." "" ; return }
        set pick [targetTag]
        if {$pick ne "" && [lsearch -exact $tags $pick] >= 0} { set tags [list $pick] }
    } else { set tags [list $tag] }
    foreach t $tags {
        if {[::store::readonly $t]} { setStatus "'$t' is read-only." warn ; continue }
        if {[catch {::store::commit $t} err]} { ::ui::problem "Commit of '$t' failed:\n\n$err" ; return }
    }
    ::explorer::refresh
    updatePending
    setStatus "Committed changes to [join $tags {, }]." ok
}
proc ::app::rollback {{tag ""}} {
    if {$tag eq ""} {
        set tag [targetTag]
        if {$tag eq "" || [::store::dirty $tag] == 0} {
            foreach t [::store::tags] { if {[::store::dirty $t] > 0} { set tag $t ; break } }
        }
    }
    if {$tag eq "" || [::store::dirty $tag] == 0} { setStatus "Nothing to roll back." "" ; return }
    set n [::store::dirty $tag]
    set r [::ui::ask "Roll back" "Discard $n uncommitted change(s) in '$tag'?\n\nThe database returns to its last committed state." {"Roll Back" Cancel} stop]
    if {$r ne "Roll Back"} return
    if {[catch {::store::rollback $tag} err]} { ::ui::problem "Roll back failed:\n\n$err" ; return }
    dataChanged 1
    setStatus "Rolled back '$tag'." ok
}

# called whenever data or structure changed
proc ::app::dataChanged {{structure 1}} {
    variable A
    updatePending
    if {$structure} {
        ::explorer::refresh
        foreach id [docs] {
            switch -- [docType $id] {
                data   { catch {::ddoc::reload $id} }
                design { catch {::design::refresh $id} }
            }
        }
    } else {
        # cheap path: only the pending counts / dirty markers changed
        ::explorer::refresh
    }
}

# ============================================================================
#  explorer integration
# ============================================================================
proc ::app::onExplorerSelect {meta} {
    if {$meta eq ""} { set meta [dict create kind root key root] }
    ::props::show [::explorer::describe $meta]
}

proc ::app::explorerAction {name m} {
    switch -- $name {
        openDB    openDB
        newDB     newDB
        newSample newSample
        newQuery  { newQuery "" [dict get $m tag] }
        newView   { newView [dict get $m tag] }
        closeDB   { closeDB [dict get $m tag] }
        commitDB  { commit [dict get $m tag] }
        rollbackDB { rollback [dict get $m tag] }
        copyPath  { clipboard clear ; clipboard append [::store::path [dict get $m tag]] ; setStatus "Path copied." ok }
        selectTop { newQuery "SELECT *\nFROM [dict get $m path]\nLIMIT 1000" [dict get $m tag] 1 }
        editRows  { openData [dict get $m path] [dict get $m name] }
        design    { openDesign [dict get $m path] [dict get $m name] }
        dropView  { dropView $m }
        dropSelected { if {$m ne "" && [dict get $m kind] eq "view"} { dropView $m } }
        copyName  { clipboard clear ; clipboard append [dict get $m name] ; setStatus "Name copied." ok }
        insertName {
            set q [currentQuery]
            if {$q eq ""} { setStatus "Open a query window first." warn ; return }
            ::editor::insertText [docFrame $q].ed [dict get $m name]
        }
    }
}

# create an empty view, then open it in the designer
proc ::app::newView {{tag ""}} {
    if {$tag eq ""} { set tag [targetTag] }
    if {$tag eq ""} { setStatus "Open a database first." warn ; return }
    if {[::store::readonly $tag]} { setStatus "'$tag' is open read-only." warn ; return }
    set r [::ui::formResult [::ui::form "New view in '$tag'" [list \
        {name "View name" entry ""} {first "First column" entry "id"} \
        [list type "Type" combo Integer [::design::types]]] "Create" [list ::app::validateNewView $tag]]]
    if {$r eq ""} return
    set name [dict get $r name]
    if {[catch {
        ::store::createView $tag $name [list [list [dict get $r first] [::design::letter [dict get $r type]] {}]]
    } err]} { ::ui::problem $err ; return }
    dataChanged 1
    openDesign $tag.$name $name
}
proc ::app::validateNewView {tag d} {
    set n [dict get $d name]
    if {$n eq ""} { return "Please enter a name." }
    if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $n]} { return "Use letters, digits and underscores, and don't start with a digit." }
    if {[::store::hasView $tag $n]} { return "A view called '$n' already exists." }
    if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} [dict get $d first]]} { return "Enter a valid first column name." }
    return ""
}

proc ::app::validateRow {path d} {
    set row [dict get $d row]
    if {![string is integer -strict $row] || $row < 0} { return "Enter a row number (0, 1, 2, ...)." }
    if {$row >= [::store::size $path]} { return "That view only has [::store::size $path] rows." }
    return ""
}
proc ::app::dropView {m} {
    variable A
    set path [dict get $m path]
    set r [::ui::ask "Drop view" "Drop '[dict get $m name]' and its [commas [::store::size $path]] row(s)?\n\nYou can still undo this with Roll Back until you commit." {Drop Cancel} stop]
    if {$r ne "Drop"} return
    foreach id [docs] {
        if {[docType $id] in {data design} && [string match "$path*" $A(path,$id)]} { closeDoc $id 1 }
    }
    if {[catch {
        if {[::store::readonly [dict get $m tag]]} { error "This database is open read-only." }
        ::store::dropView [dict get $m tag] [dict get $m name]
    } err]} { ::ui::problem $err ; return }
    dataChanged 1
    setStatus "View dropped." ok
}

# ============================================================================
#  query actions
# ============================================================================
proc ::app::execute {} {
    set id [currentQuery]
    if {$id eq ""} { setStatus "Open a query window first (Ctrl+N)." warn ; return }
    ::qdoc::execute $id
}
proc ::app::toggleResults {} {
    set id [currentQuery]
    if {$id ne ""} { ::qdoc::toggleResults $id }
}
proc ::app::toggleComment {} {
    set id [currentQuery]
    if {$id ne ""} { ::editor::toggleComment [docFrame $id].ed }
}
proc ::app::editEvent {ev} {
    set w [focus]
    if {$w eq ""} return
    if {$ev eq "<<SelectAll>>" && [winfo class $w] eq "Text"} { $w tag add sel 1.0 end-1c ; return }
    event generate $w $ev
}

# completion candidates: list of {word kind}
proc ::app::complete {ctx full} {
    set before $ctx
    regsub {[A-Za-z0-9_]*$} $before {} before
    set items {}
    set tags [::store::tags]
    set db [expr {[currentQuery] ne "" ? [::qdoc::db [currentQuery]] : ""}]
    # after FROM / INTO / UPDATE / VIEW ...: view and database names
    if {[regexp -nocase {\m(?:FROM|INTO|UPDATE|VIEW|TABLE|DESCRIBE|DESC|COMMIT|ROLLBACK|USE)\s+$} $before]} {
        foreach t $tags {
            lappend items [list $t database]
            foreach v [::store::views $t] { lappend items [list $v "view in $t"] }
        }
        return $items
    }
    if {[regexp {([A-Za-z0-9_]+)\.$} $before -> q] && [lsearch -exact $tags $q] >= 0} {
        foreach v [::store::views $q] { lappend items [list $v "view in $q"] }
        return $items
    }
    # columns of the view named after FROM / UPDATE / INTO in this statement
    if {[regexp -nocase {\m(?:FROM|UPDATE|INTO)\s+(?:([A-Za-z0-9_]+)\.)?([A-Za-z0-9_]+)} $full -> qd qv]} {
        foreach t [expr {$qd ne "" ? [list $qd] : $tags}] {
            if {![::store::exists $t] || ![::store::hasView $t $qv]} continue
            foreach c [::store::layout $t.$qv] {
                lappend items [list [lindex $c 0] "[string tolower [::store::typeName [lindex $c 1]]] column"]
            }
            break
        }
    }
    foreach t $tags {
        foreach v [::store::views $t] { lappend items [list $v "view in $t"] }
    }
    foreach f [concat $::mkql::aggs $::mkql::functions] { lappend items [list $f function] }
    foreach k $::mkql::keywords { lappend items [list $k keyword] }
    return $items
}

# ---- scripts, CSV --------------------------------------------------------------------
proc ::app::saveScript {{as 0} {id ""}} {
    variable A ; variable cfg
    if {$id eq ""} { set id [currentQuery] }
    if {$id eq "" || [docType $id] ne "query"} { return 0 }
    set f [docFrame $id]
    set file $A(file,$id)
    if {$as || $file eq ""} {
        set file [tk_getSaveFile -title "Save script" -defaultextension .mkql \
            -initialfile [expr {$A(file,$id) ne "" ? [file tail $A(file,$id)] : "query.mkql"}] \
            -initialdir [expr {$cfg(lastDir) ne "" && [file isdirectory $cfg(lastDir)] ? $cfg(lastDir) : [pwd]}] \
            -filetypes {{{MKQL scripts} {.mkql .sql}} {{All files} *}}]
        if {$file eq ""} { return 0 }
    }
    if {[catch {
        set out [open $file w] ; fconfigure $out -encoding utf-8
        puts -nonewline $out [::editor::get $f.ed] ; close $out
    } err]} { ::ui::problem "Could not save the script:\n\n$err" ; return 0 }
    set A(file,$id) $file
    set A(saved,$id) [::editor::get $f.ed]
    ::tabs::setTitle .main.center.tabs $id [file tail $file]
    set A(title,$id) [file tail $file]
    ::tabs::setDirty .main.center.tabs $id 0
    setStatus "Saved [file tail $file]." ok
    return 1
}
proc ::app::openScript {} {
    variable A ; variable cfg
    set file [tk_getOpenFile -title "Open script" \
        -initialdir [expr {$cfg(lastDir) ne "" && [file isdirectory $cfg(lastDir)] ? $cfg(lastDir) : [pwd]}] \
        -filetypes {{{MKQL scripts} {.mkql .sql .txt}} {{All files} *}}]
    if {$file eq ""} return
    if {[catch {
        set in [open $file r] ; fconfigure $in -encoding utf-8
        set text [read $in] ; close $in
    } err]} { ::ui::problem "Could not read the file:\n\n$err" ; return }
    set id [newQuery $text]
    set A(file,$id) $file ; set A(saved,$id) $text
    ::tabs::setTitle .main.center.tabs $id [file tail $file]
    set A(title,$id) [file tail $file]
    ::tabs::setDirty .main.center.tabs $id 0
}
proc ::app::exportCsv {} {
    set id [currentQuery]
    if {$id eq ""} { setStatus "Run a query first." warn ; return }
    set g [::qdoc::currentGrid $id]
    if {$g eq ""} { setStatus "There are no results to export." warn ; return }
    set f [::grid::exportCsv $g]
    if {$f ne ""} { setStatus "Exported [commas [::grid::count $g]] rows to [file tail $f]." ok }
}

# RFC-4180-ish CSV reader
proc ::app::parseCsv {text} {
    set rows {} ; set row {} ; set field "" ; set inq 0 ; set i 0
    set n [string length $text]
    if {[string index $text 0] eq "﻿"} { set i 1 }
    while {$i < $n} {
        set ch [string index $text $i]
        if {$inq} {
            if {$ch eq "\""} {
                if {[string index $text [expr {$i+1}]] eq "\""} { append field "\"" ; incr i } else { set inq 0 }
            } else { append field $ch }
        } else {
            switch -- $ch {
                "\"" { set inq 1 }
                "," { lappend row $field ; set field "" }
                "\r" {}
                "\n" { lappend row $field ; lappend rows $row ; set row {} ; set field "" }
                default { append field $ch }
            }
        }
        incr i
    }
    if {$field ne "" || [llength $row]} { lappend row $field ; lappend rows $row }
    return $rows
}

proc ::app::importCsv {} {
    variable cfg
    set targets {}
    foreach t [::store::tags] {
        if {[::store::readonly $t]} continue
        foreach v [::store::views $t] { lappend targets $t.$v }
    }
    if {![llength $targets]} { ::ui::inform "Import CSV" "Open a database that has at least one view first." ; return }
    set m [::explorer::selected]
    set def [lindex $targets 0]
    if {$m ne "" && [dict exists $m path] && [lsearch -exact $targets [dict get $m path]] >= 0} { set def [dict get $m path] }
    set r [::ui::formResult [::ui::form "Import CSV" [list \
        [list target "Import into view" combo $def $targets] \
        {header "First row contains column names" check 1}] "Choose File…" "" \
        "Columns are matched to the view's columns by name. Rows are added in memory; Commit to save."]]
    if {$r eq ""} return
    set file [tk_getOpenFile -title "Choose CSV file" \
        -initialdir [expr {$cfg(lastDir) ne "" && [file isdirectory $cfg(lastDir)] ? $cfg(lastDir) : [pwd]}] \
        -filetypes {{{CSV files} {.csv .tsv .txt}} {{All files} *}}]
    if {$file eq ""} return
    set mk [dict get $r target]
    if {[catch {
        set in [open $file r] ; fconfigure $in -encoding utf-8
        set data [read $in] ; close $in
        set rows [parseCsv $data]
        set layout [::store::layout $mk]
        if {![llength $rows]} { error "The file is empty." }
        if {[dict get $r header]} {
            set headers [lindex $rows 0] ; set rows [lrange $rows 1 end]
        } else {
            set headers {}
            foreach c $layout { if {[lindex $c 1] ne "V"} { lappend headers [lindex $c 0] } }
        }
        set map {}   ;# {csvIndex name type}
        set i 0
        foreach h $headers {
            set d [::store::findCol $layout [string trim $h]]
            if {$d ne "" && [lindex $d 1] ne "V"} { lappend map [list $i [lindex $d 0] [lindex $d 1]] }
            incr i
        }
        if {![llength $map]} { error "None of the CSV columns match a column of '$mk'.\n\nCSV columns: [join $headers {, }]" }
        set props {} ; foreach e $map { lappend props [lindex $e 1] }
        set prepared {} ; set rn [expr {[dict get $r header] ? 1 : 0}]
        foreach row $rows {
            incr rn
            if {[llength $row] == 1 && [lindex $row 0] eq ""} continue
            set vals {}
            foreach e $map {
                lassign $e ci name type
                set v [expr {$ci < [llength $row] ? [lindex $row $ci] : ""}]
                if {$v eq "" && $type in {I L F D}} { set v 0 }
                if {[catch {::store::coerce $name $type $v} cv]} { error "Row $rn: $cv" }
                lappend vals $cv
            }
            lappend prepared $vals
        }
        foreach vals $prepared { ::store::appendRow $mk $props $vals }
    } err]} { ::ui::problem "Import failed (nothing was added):\n\n$err" "Import CSV" ; return }
    dataChanged 1
    setStatus "Imported [commas [llength $prepared]] rows into $mk ([llength $map] of [llength $headers] CSV columns matched). Commit to save." ok
}

# ============================================================================
#  about, quit
# ============================================================================
proc ::app::about {} {
    variable version
    ::ui::ask "About MK Studio" "MK Studio $version\n\nA workbench for Metakit databases, written entirely in Tcl/Tk and designed to live inside a starpack.\n\nTcl [info patchlevel]  ·  Tk [package present Tk]\nMetakit: [expr {[::store::available] ? {Mk4tcl available} : {Mk4tcl missing}}]" OK help
}

proc ::app::quit {} {
    variable busyFlag
    if {$busyFlag} { cancel ; return }
    foreach t [::store::tags] {
        if {![closeDB $t]} return
    }
    foreach id [docs] {
        if {[docType $id] eq "query"} { if {![closeDoc $id]} return }
    }
    saveSettings
    destroy .
}

# ============================================================================
#  start up
# ============================================================================
proc ::app::bindKeys {} {
    bind . <F5>             {::app::execute ; break}
    bind . <Control-e>      {::app::execute ; break}
    bind . <Escape>         {::app::cancel}
    bind . <Control-n>      {::app::newQuery ; break}
    bind . <Control-o>      {::app::openDB ; break}
    bind . <Control-s>      {::app::saveScript ; break}
    bind . <Control-S>      {::app::commit ; break}
    bind . <Control-w>      {::app::closeCurrent ; break}
    bind . <Control-r>      {::app::toggleResults ; break}
    bind . <F8>             {::app::togglePane showEx ; break}
    bind . <F4>             {::app::togglePane showPr ; break}
    bind . <Control-Tab>    {::app::cycleTab 1 ; break}
    bind . <Control-Shift-Tab> {::app::cycleTab -1 ; break}
    bind . <Control-ISO_Left_Tab> {::app::cycleTab -1 ; break}
    bind . <Control-equal>  {::editor::zoom {} 1 ; break}
    bind . <Control-plus>   {::editor::zoom {} 1 ; break}
    bind . <Control-minus>  {::editor::zoom {} -1 ; break}
}
proc ::app::placeSashes {} {
    variable cfg
    set n [llength [.main panes]]
    if {$n == 3} {
        .main sashpos 0 $cfg(exWidth)
        .main sashpos 1 [expr {[winfo width .main] - $cfg(prWidth)}]
    } elseif {$n == 2 && $cfg(showEx)} {
        .main sashpos 0 $cfg(exWidth)
    } elseif {$n == 2} {
        .main sashpos 0 [expr {[winfo width .main] - $cfg(prWidth)}]
    }
}
proc ::app::cycleTab {dir} {
    set ids [docs]
    if {[llength $ids] < 2} return
    set i [lsearch -exact $ids [currentDoc]]
    showDoc [lindex $ids [expr {($i + $dir) % [llength $ids]}]]
}

proc ::app::main {argv} {
    variable cfg ; variable themeVar
    loadSettings
    set themeVar $cfg(theme)
    wm withdraw .
    wm title . "MK Studio"
    wm minsize . 960 600
    ::theme::init
    ::theme::apply $cfg(theme)
    catch {::editor::zoomReset ; set ::editor::fontSize $cfg(fontSize) ; font configure MkMono -size $cfg(fontSize)}
    catch {wm iconphoto . -default [::icons::get db]}

    buildMenus
    buildToolbar
    ttk::frame .tbline -style Line.TFrame -height 1
    buildMain
    buildStatus
    pack .mb -side top -fill x
    pack .tb -side top -fill x
    pack .tbline -side top -fill x
    pack .sb -side bottom -fill x
    pack .main -side top -fill both -expand 1
    rebuildRecent
    refreshWelcome
    bindKeys
    wm protocol . WM_DELETE_WINDOW ::app::quit
    wm geometry . $cfg(geometry)
    wm deiconify .
    update
    if {!$cfg(showEx)} { .main forget .main.ex }
    if {!$cfg(showPr)} { .main forget .main.pr }
    placeSashes
    docSelected ""
    updatePending
    setStatus "Ready" ok
    bind .main.ex <<ExplorerRefreshed>> {::app::onExplorerSelect [::explorer::selected]}
    onExplorerSelect {}

    foreach a $argv {
        if {[string match -* $a]} continue
        if {[file exists $a]} { openOne $a }
    }
    raise .main.center.docs.welcome
    return
}
