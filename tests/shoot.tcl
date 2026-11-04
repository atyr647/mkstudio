# Screenshot driver:  xvfb-run -s "-screen 0 1440x900x24" wish tests/shoot.tcl <scenario> <out.png> ?theme?
set here [file dirname [file normalize [info script]]]
set ::mkstudio_root [file join $here .. mkstudio.vfs]
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) /tmp/mks_home_[pid] ; file mkdir $::env(HOME)
lassign $argv scenario out theme
if {$theme eq ""} { set theme dark }
set ::app::cfg(theme) $theme
if {[info exists ::env(SCALE)]} { tk scaling $::env(SCALE) }
::app::main {}
wm geometry . 1360x820+0+0
update

proc settle {{ms 300}} { after $ms {set ::go 1} ; vwait ::go ; update }
proc shot {file} { settle ; exec import -window root $file }
proc expandAll {} {
    set t .main.ex.t
    for {set pass 0} {$pass < 6} {incr pass} {
        foreach item [array names ::explorer::M] {
            if {[$t exists $item]} { ::explorer::populate $item ; $t item $item -open 1 }
        }
    }
}

set f /tmp/shoot_demo.mk ; file delete $f
set tag [::store::createSample $f]
::app::afterDbChange

switch -- $scenario {
    realworld {
        set rw [::store::openFile /tmp/realworld.mk -readonly]
        ::app::afterDbChange
        ::app::openData $rw.dirs dirs
        ::ddoc::drill [lindex [::app::docs] 0] 2 files
        shot $out
    }
    bytes {
        set rw [::store::openFile /tmp/realworld.mk -readonly]
        ::app::afterDbChange
        set id [::app::openData $rw.dirs dirs]
        ::ddoc::drill $id 2 files
        set id2 [lindex [::app::docs] end]
        after 700 { exec import -window root $::out ; set ::ui::result close }
        ::ddoc::drill $id2 1 @contents
    }
    big {
        set b [::store::openFile /tmp/big.mk -readonly]
        ::app::afterDbChange
        set t0 [clock milliseconds]
        set id [::app::openData $b.big big]
        puts stderr "open data tab (500k rows): [expr {[clock milliseconds]-$t0}] ms"
        set t0 [clock milliseconds]
        set g [::app::docFrame $id].g
        update
        puts stderr "first paint: [expr {[clock milliseconds]-$t0}] ms"
        set t0 [clock milliseconds]
        for {set i 0} {$i < 50} {incr i} { ::grid::scrollTo $g [expr {$i * 9973}] ; update idletasks }
        puts stderr "50 jumps across the 500k rows: [expr {[clock milliseconds]-$t0}] ms"
        ::grid::scrollTo $g 250000
        ::grid::select $g {250002 250003 250004}
        shot $out
    }
    ctxgrid {
        set id [::app::openData $tag.products products]
        set g [::app::docFrame $id].g
        update
        ::grid::select $g {2}
        ::grid::popupMenu $g 100 80 [expr {[winfo rootx $g.t] + 120}] [expr {[winfo rooty $g.t] + 100}]
        ::menus::activate [::menus::current] 2
        settle 300
        exec import -window root $out
    }
    ctxeditor {
        set id [::app::newQuery "SELECT id, name FROM employees\nWHERE id < 5;" $tag 0]
        set ed [::app::docFrame $id].ed
        update
        ::editor::popupMenu $ed [expr {[winfo rootx $ed.t] + 200}] [expr {[winfo rooty $ed.t] + 60}]
        ::menus::activate [::menus::current] 3
        settle 300
        exec import -window root $out
    }
    focus {
        set id [::app::newQuery "SELECT * FROM employees LIMIT 5" $tag 1]
        update
        focus .tb.run
        settle 300
        exec import -window root $out
    }
    addcol {
        set id [::app::openData $tag.products products]
        update
        after 700 { exec import -window root $::out ; set ::ui::result "" }
        ::ddoc::addColumn $id
    }
    align {
        set id [::app::openData $tag.employees employees]
        set t [::app::docFrame $id].g.t
        update
        # report each column's geometry so the analysis can compare header vs cell text
        set x0 [winfo rootx $t]
        set y0 [winfo rooty $t]
        lassign [$t bbox r0] bx by bw bh
        set geo {}
        foreach c [$t cget -columns] {
            lassign [$t bbox r0 $c] cx cy cw ch
            lappend geo "$c,[expr {$x0+$cx}],$cw,[$t column $c -anchor]"
        }
        set f [open /tmp/align_geo.txt w] ; puts $f "[expr {$y0}] [expr {$y0+$by}] $bh $geo" ; close $f
        shot $out
    }
    welcome {
        ::app::closeDB $tag 1
        set ::app::cfg(recent) [list /home/ada/projects/inventory.mk /home/ada/projects/crm/customers.mk \
            /data/archive/2025/orders-archive.mk]
        ::app::refreshWelcome
        shot $out
    }
    confirm {
        set id [::app::openData $tag.products products]
        ::grid::select [::app::docFrame $id].g {1 2}
        after 700 { exec import -window root $::out ; set ::ui::result "" }
        ::ddoc::deleteRows $id
    }
    find {
        set txt "SELECT name, salary FROM employees\nWHERE salary > 90000\nORDER BY salary DESC;\n\nSELECT dept, AVG(salary) FROM employees GROUP BY dept;"
        set id [::app::newQuery $txt $tag 1]
        set ed [::app::docFrame $id].ed
        ::editor::findOpen $ed
        set ::editor::E($ed,find) salary
        ::editor::findMark $ed
        ::editor::findStep $ed 0
        ::editor::findStep $ed 1
        shot $out
    }
    filter {
        set ::explorer::filter "or"
        ::explorer::applyFilter
        set g [::app::openData $tag.orders orders]
        shot $out
    }
    hover {
        set id [::app::openData $tag.employees employees]
        set t [::app::docFrame $id].g.t
        settle
        lassign [$t bbox s4] x y
        ::ui::hoverMove $t [expr {$x + 100}] [expr {$y + 5}]
        $t selection set s1
        shot $out
    }
    empty {
        ::store::createView $tag notes {{id I {}} {text S {}}}
        ::app::dataChanged 1
        ::app::openData $tag.notes notes
        shot $out
    }
    main {
        set txt "-- Sample database. Press F5 to run the whole script.\nSELECT name, title, salary\nFROM employees\nORDER BY salary DESC\nLIMIT 10;\n\nSELECT dept, COUNT(*) AS people, ROUND(AVG(salary), 0) AS avg_salary\nFROM employees\nGROUP BY dept\nORDER BY avg_salary DESC;\n\n-- skills is a subview (a nested table in every row).\nSELECT id, name, skills FROM employees WHERE skills >= 3;"
        set id [::app::newQuery $txt $tag 1]
        expandAll
        set t .main.ex.t
        foreach item [$t children {}] { }
        # select the employees view for the properties pane
        foreach item [array names ::explorer::M] {
            if {[dict get $::explorer::M($item) key] eq "view:$tag.employees"} { $t selection set $item ; $t see $item }
        }
        ::app::showDoc $id
        ::qdoc::showPage $id r2
        shot $out
    }
    data {
        ::app::openData $tag.employees employees
        expandAll
        shot $out
    }
    design {
        ::app::openDesign $tag.employees employees
        expandAll
        shot $out
    }
    drill {
        set id [::app::newQuery "SELECT id, name, skills FROM employees WHERE skills >= 3;" $tag 1]
        ::app::showDoc $id
        ::qdoc::showPage $id r1
        shot $out
    }
    subview {
        ::app::openData $tag.employees employees
        ::ddoc::drill [lindex [::app::docs] 0] 2 skills
        shot $out
    }
    dialog {
        ::app::openDesign $tag.products products
        after 600 {
            update
            exec import -window root $::out
            set ::ui::result ""
        }
        ::design::addColumn [lindex [::app::docs] 0]
    }
    menu {
        ::app::openData $tag.products products
        update
        ::menus::openBar .mb.file
        ::menus::activate [::menus::current] 4
        settle 400
        exec import -window root $out
    }
    viewmenu {
        set id [::app::newQuery "SELECT 1" $tag 0]
        update
        ::menus::openBar .mb.view
        ::menus::activate [::menus::current] 3
        settle 400
        exec import -window root $out
    }
    ctxmenu {
        expandAll
        set t .main.ex.t
        foreach item [array names ::explorer::M] {
            if {[dict get $::explorer::M($item) key] eq "view:$tag.employees"} { set it $item }
        }
        $t selection set $it ; $t see $it ; update
        lassign [$t bbox $it] x y
        ::explorer::onMenu [expr {$x+40}] [expr {$y+5}] [expr {[winfo rootx $t]+$x+60}] [expr {[winfo rooty $t]+$y+12}]
        ::menus::activate [::menus::current] 1
        settle 400
        exec import -window root $out
    }
    pending {
        set id [::app::openData $tag.products products]
        ::ddoc::commit $id 0 name "Keyboard 65% (edited)"
        ::ddoc::commit $id 1 stock 1000
        ::ddoc::reload $id
        .main.ex.t selection set {}
        shot $out
    }
    error {
        set id [::app::newQuery "SELECT id, name\nFROM employees\nWHERE salary >> 5000;" $tag 1]
        shot $out
    }

}
exit 0
