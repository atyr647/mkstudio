# explorer.tcl -- Object Explorer (left) and Properties (right) panes.
#
#   databases
#     `- <db>                       a Metakit datafile
#         `- Views
#             `- <view>             rows shown on the right
#                 `- Columns
#                     |- <column>   (type)
#                     `- <subview>  expandable: its own columns
#
#   ::explorer::create w -action cmd -select cmd
#      -action {name meta}   a context-menu / double-click action
#      -select {meta}        selection changed

namespace eval ::explorer {
    variable M            ;# tree item -> meta dict
    array set M {}
    variable opts
    variable w ""
    variable counter 0
}

proc ::explorer::create {win args} {
    variable opts ; variable w
    set w $win
    array set opts {-action {} -select {}}
    array set opts $args

    ttk::frame $w -style Panel.TFrame
    ttk::frame $w.head -style Panel.TFrame -padding {14 10 8 6}
    ttk::label $w.head.l -text "OBJECT EXPLORER" -style Section.TLabel
    pack $w.head.l -side left

    ttk::treeview $w.t -style Panel.Treeview -columns {detail} -show tree -selectmode browse \
        -yscrollcommand [list $w.v set]
    ttk::scrollbar $w.v -orient vertical -command [list $w.t yview]
    $w.t column #0 -stretch 1 -minwidth 120
    $w.t column detail -stretch 0 -width 64 -anchor e
    pack $w.head -side top -fill x
    pack $w.v -side right -fill y
    pack $w.t -side left -fill both -expand 1
    ::theme::reg $w.t {::explorer::recolor %w}

    bind $w.t <<TreeviewOpen>>   [list ::explorer::onOpen]
    bind $w.t <<TreeviewSelect>> [list ::explorer::onSelect]
    bind $w.t <Double-1>         [list ::explorer::onDouble %x %y]
    bind $w.t <Button-3>         [list ::explorer::onMenu %x %y %X %Y]
    bind $w.t <Button-2>         [list ::explorer::onMenu %x %y %X %Y]
    bind $w.t <Control-Button-1> [list ::explorer::onMenu %x %y %X %Y]
    bind $w.t <F5>               "[list ::explorer::refresh] ; break"
    bind $w.t <Delete>           [list ::explorer::act dropSelected]
    refresh
    return $w
}

proc ::explorer::recolor {t} {
    $t tag configure dirty -foreground $::theme::c(warn)
    $t tag configure ro -foreground $::theme::c(dim)
}

# ---- tree building -------------------------------------------------------------------
proc ::explorer::addNode {parent text icon detail meta {expandable 0} {tags {}}} {
    variable M ; variable w
    set item [$w.t insert $parent end -text " $text" -image [::icons::get $icon] \
        -values [list $detail] -tags $tags]
    set M($item) $meta
    if {$expandable} { $w.t insert $item end -id $item.ph -text "" }
    return $item
}

proc ::explorer::key {meta} { dict get $meta key }

proc ::explorer::refresh {} {
    variable M ; variable w
    set t $w.t
    # remember what was expanded and selected
    set open {} ; set sel ""
    foreach item [array names M] {
        if {[$t exists $item] && [$t item $item -open]} { lappend open [dict get $M($item) key] }
    }
    set s [$t selection]
    if {$s ne "" && [info exists M($s)]} { set sel [dict get $M($s) key] }
    $t delete [$t children {}]
    array unset M
    array set M {}
    set root [addNode {} "Metakit Databases" server [llength [::store::tags]] [dict create kind root key root] 0]
    foreach tag [::store::tags] { addDb $root $tag }
    if {![llength [::store::tags]]} {
        addNode $root "Open a database..." open "" [dict create kind hint key hint] 0
    }
    $t item $root -open 1
    restore $root $open $sel
    event generate $w <<ExplorerRefreshed>>
}

proc ::explorer::addDb {parent tag} {
    set n [::store::dirty $tag]
    set ro [::store::readonly $tag]
    set detail [expr {$ro ? "read-only" : ($n ? "$n pending" : "")}]
    set tags [expr {$n ? "dirty" : ($ro ? "ro" : "")}]
    addNode $parent $tag db $detail [dict create kind db tag $tag key db:$tag] 1 $tags
}

proc ::explorer::restore {item open sel} {
    variable M ; variable w
    set t $w.t
    foreach child [$t children $item] {
        if {![info exists M($child)]} continue
        set key [dict get $M($child) key]
        if {$key eq $sel} { $t selection set $child }
        if {[lsearch -exact $open $key] >= 0} {
            populate $child
            $t item $child -open 1
            restore $child $open $sel
        }
    }
}

proc ::explorer::collapseAll {} {
    variable w
    foreach item [$w.t children {}] {
        foreach c [$w.t children $item] { $w.t item $c -open 0 }
    }
}

# fill in the real children of an item (lazy)
proc ::explorer::populate {item} {
    variable M ; variable w
    set t $w.t
    if {![$t exists $item.ph]} return
    $t delete $item.ph
    set m $M($item)
    switch -- [dict get $m kind] {
        db {
            set tag [dict get $m tag]
            addNode $item "Views" folder [llength [::store::views $tag]] \
                [dict create kind views tag $tag key views:$tag] 1
        }
        views {
            set tag [dict get $m tag]
            foreach v [::store::views $tag] {
                set path $tag.$v
                addNode $item $v table [::store::size $path] \
                    [dict create kind view tag $tag name $v path $path key view:$path] 1
            }
        }
        view {
            set path [dict get $m path]
            set layout [::store::layout $path]
            addNode $item "Columns" folder [llength $layout] \
                [dict create kind cols tag [dict get $m tag] path $path layout $layout key cols:$path] 1
        }
        cols - sub {
            set tag [dict get $m tag]
            set path [dict get $m path]
            set chain [expr {[dict exists $m chain] ? [dict get $m chain] : ""}]
            foreach c [dict get $m layout] {
                lassign $c name type sub
                if {$type eq "V"} {
                    addNode $item $name col_V "[llength $sub] cols" [dict create kind sub tag $tag path $path \
                        name $name type V layout $sub chain [concat $chain [list $name]] \
                        key sub:$path:[join [concat $chain [list $name]] .]] 1
                } else {
                    addNode $item $name col_$type [string tolower [::store::typeName $type]] \
                        [dict create kind col tag $tag path $path name $name type $type chain $chain \
                        key col:$path:[join [concat $chain [list $name]] .]] 0
                }
            }
        }
    }
}

proc ::explorer::onOpen {} {
    variable w
    foreach item [$w.t selection] { populate $item }
    set f [$w.t focus]
    if {$f ne ""} { populate $f }
}

proc ::explorer::meta {item} {
    variable M
    if {[info exists M($item)]} { return $M($item) }
    return {}
}
proc ::explorer::selected {} {
    variable w
    set s [$w.t selection]
    if {$s eq ""} { return {} }
    return [meta [lindex $s 0]]
}

proc ::explorer::onSelect {} {
    variable opts
    if {[dict exists [selected] kind] && [dict get [selected] kind] eq "hint"} { after idle [list ::explorer::act openDB [selected]] ; return }
    if {$opts(-select) ne ""} { uplevel #0 [list {*}$opts(-select) [selected]] }
}

proc ::explorer::onDouble {x y} {
    variable w
    set item [$w.t identify row $x $y]
    if {$item eq ""} return
    set m [meta $item]
    switch -- [dict get $m kind] {
        col  { act insertName $m }
        view { act editRows $m ; return -code break }
    }
}

# ---- context menus -------------------------------------------------------------------
proc ::explorer::act {name {m ""}} {
    variable opts
    if {$m eq ""} { set m [selected] }
    if {$opts(-action) ne ""} { uplevel #0 [list {*}$opts(-action) $name $m] }
}

proc ::explorer::onMenu {x y X Y} {
    variable w
    set item [$w.t identify row $x $y]
    if {$item ne ""} { $w.t selection set $item ; $w.t focus $item }
    set m [expr {$item ne "" ? [meta $item] : [dict create kind root key root]}]
    set mn $w.menu
    catch {destroy $mn}
    menu $mn -tearoff 0
    ::theme::menu $mn
    switch -- [dict get $m kind] {
        root {
            $mn add command -label "Open Database..." -command [list ::explorer::act openDB $m]
            $mn add command -label "New Database..." -command [list ::explorer::act newDB $m]
            $mn add command -label "New Sample Database..." -command [list ::explorer::act newSample $m]
        }
        db {
            $mn add command -label "New Query" -command [list ::explorer::act newQuery $m]
            $mn add separator
            $mn add command -label "New View..." -command [list ::explorer::act newView $m]
            $mn add separator
            $mn add command -label "Commit Changes" -command [list ::explorer::act commitDB $m]
            $mn add command -label "Roll Back Changes" -command [list ::explorer::act rollbackDB $m]
            $mn add separator
            $mn add command -label "Close Database" -command [list ::explorer::act closeDB $m]
            $mn add command -label "Copy File Path" -command [list ::explorer::act copyPath $m]
        }
        views {
            $mn add command -label "New View..." -command [list ::explorer::act newView $m]
        }
        view {
            $mn add command -label "Edit Rows" -command [list ::explorer::act editRows $m]
            $mn add command -label "Design" -command [list ::explorer::act design $m]
            $mn add command -label "Select Top 1000 Rows" -command [list ::explorer::act selectTop $m]
            $mn add separator
            $mn add command -label "Drop View..." -accelerator Del -command [list ::explorer::act dropView $m]
            $mn add command -label "Copy Name" -command [list ::explorer::act copyName $m]
        }
        col - sub {
            $mn add command -label "Insert Name into Query" -command [list ::explorer::act insertName $m]
            $mn add command -label "Copy Name" -command [list ::explorer::act copyName $m]
        }
        default { destroy $mn ; return }
    }
    tk_popup $mn $X $Y
}

# ---- data for the Properties pane --------------------------------------------------------
# returns {title subtitle sections}, sections = {name {key value key value ...} ...}
proc ::explorer::describe {m} {
    if {$m eq ""} { return {"" "" {}} }
    switch -- [dict get $m kind] {
        root {
            set rows {}
            foreach t [::store::tags] { lappend rows $t [::store::path $t] }
            return [list "Databases" "Metakit datafiles" [list General [list "Open files" [llength [::store::tags]]] \
                Files $rows]]
        }
        db {
            set tag [dict get $m tag]
            set bytes [::store::fileSize $tag]
            return [list $tag "Metakit datafile" [list \
                General [list Name $tag Path [::store::path $tag] Size [fmtBytes $bytes] \
                    Mode [expr {[::store::readonly $tag] ? "read-only" : "read-write"}]] \
                Status [list "Pending changes" [::store::dirty $tag] Views [llength [::store::views $tag]]]]]
        }
        views {
            set tag [dict get $m tag]
            return [list Views "Folder in $tag" [list General [list Database $tag Count [llength [::store::views $tag]]]]]
        }
        view {
            set path [dict get $m path]
            set layout [::store::layout $path]
            set subs 0
            foreach c $layout { if {[lindex $c 1] eq "V"} { incr subs } }
            return [list [dict get $m name] "Metakit view" [list \
                General [list Name [dict get $m name] Database [dict get $m tag] Rows [::store::size $path] \
                    Columns [llength $layout] Subviews $subs] \
                Layout [list Path $path Structure [::store::formatLayout $layout]]]]
        }
        cols {
            return [list Columns "Folder" [list General [list Count [llength [dict get $m layout]]]]]
        }
        col - sub {
            set type [dict get $m type]
            set chain [expr {[dict exists $m chain] ? [dict get $m chain] : ""}]
            set sections [list General [list Name [dict get $m name] \
                "Data type" "[::store::typeName $type] ($type)" \
                Kind [expr {$type eq "V" ? "subview (nested table)" : "column"}] \
                View [lindex [split [dict get $m path] .] end]]]
            if {$type eq "V"} {
                lappend sections Subview [list Columns [llength [dict get $m layout]] \
                    Structure [::store::formatLayout [dict get $m layout]]]
            }
            return [list [dict get $m name] [expr {$type eq "V" ? "Subview" : "Column"}] $sections]
        }
    }
    return {"" "" {}}
}
proc ::explorer::fmtBytes {n} {
    if {$n < 1024} { return "$n bytes" }
    if {$n < 1048576} { return [format "%.1f KB" [expr {$n / 1024.0}]] }
    return [format "%.2f MB" [expr {$n / 1048576.0}]]
}

# ============================================================================
#  Properties pane
# ============================================================================
namespace eval ::props { variable w "" }

proc ::props::create {win} {
    variable w
    set w $win
    ttk::frame $w -style Panel.TFrame
    ttk::frame $w.head -style Panel.TFrame -padding {14 10 14 6}
    ttk::label $w.head.l -text "PROPERTIES" -style Section.TLabel
    pack $w.head.l -side left
    ttk::label $w.title -text "" -style Panel.TLabel -font MkTitle -padding {14 4 14 0}
    ttk::label $w.sub -text "" -style PanelDim.TLabel -padding {14 0 14 10}
    ttk::treeview $w.t -style Panel.Treeview -columns {value} -show tree -selectmode browse
    $w.t column #0 -width 110 -stretch 0
    $w.t column value -width 120 -stretch 1 -anchor w
    ttk::scrollbar $w.v -orient vertical -command [list $w.t yview]
    $w.t configure -yscrollcommand [list $w.v set]
    pack $w.head -side top -fill x
    pack $w.title -side top -fill x
    pack $w.sub -side top -fill x
    pack $w.v -side right -fill y
    pack $w.t -side left -fill both -expand 1
    ::theme::reg $w.t {::props::recolor %w}
    return $w
}
proc ::props::recolor {t} {
    $t tag configure cat -font MkUIBold -foreground $::theme::c(dim)
}
proc ::props::show {desc} {
    variable w
    lassign $desc title subtitle sections
    $w.title configure -text $title
    $w.sub configure -text $subtitle
    $w.t delete [$w.t children {}]
    foreach {cat kv} $sections {
        set parent [$w.t insert {} end -text [string toupper $cat] -open 1 -tags cat]
        foreach {k v} $kv {
            $w.t insert $parent end -text $k -values [list $v]
        }
    }
}
