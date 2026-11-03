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
    welcome {
        ::app::closeDB $tag 1
        set ::app::cfg(recent) [list /home/ada/projects/inventory.mk /home/ada/projects/crm/customers.mk \
            /data/archive/2025/orders-archive.mk]
        ::app::refreshWelcome
        shot $out
    }
    confirm {
        set id [::app::openData $tag.products products]
        [::app::docFrame $id].g.t selection set {r1 r2}
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
        update
        lassign [$t bbox r4] x y
        ::ui::hoverMove $t [expr {$x + 100}] [expr {$y + 5}]
        $t selection set r1
        shot $out
    }
    empty {
        ::store::createView $tag notes {{id I {}} {text S {}}}
        ::app::dataChanged 1
        ::app::openData $tag.notes notes
        shot $out
    }
    main {
        set txt "-- Sample database. Press F5 to run the whole script.\nSELECT TOP 10 name, title, salary\nFROM employees\nORDER BY salary DESC;\n\nSELECT dept, COUNT(*) AS people, ROUND(AVG(salary), 0) AS avg_salary\nFROM employees\nGROUP BY dept\nORDER BY avg_salary DESC;\n\n-- skills is a subview (a nested table in every row).\nSELECT id, name, skills FROM employees WHERE skills >= 3;"
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
