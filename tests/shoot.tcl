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
    welcome { ::app::closeDB $tag 1 ; shot $out }
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
    error {
        set id [::app::newQuery "SELECT id, name\nFROM employees\nWHERE salary >> 5000;" $tag 1]
        shot $out
    }

}
exit 0
