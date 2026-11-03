# Static checks, no display needed:  tclsh tests/lint.tcl
#  1. no proc may share its name with a Tcl/Tk command (inside its own namespace the
#     proc would silently replace the command - this caused real bugs before)
#  2. every source file is pure ASCII (Tcl's `source` encoding is platform dependent)
#  3. no Tcl 8.6-only commands, so classic 8.5 tclkits keep working
set dir [file join [file dirname [file normalize [info script]]] .. mkstudio.vfs lib app-mkstudio]
set builtin {after append apply array binary break catch chan clock close concat continue dict encoding eof
    error eval exec exit expr file fileevent flush for foreach format gets glob global if incr info interp
    join lappend lassign lindex linsert list llength lrange lrepeat lreplace lreverse lsearch lset lsort
    namespace open package pid proc puts pwd read regexp regsub rename return scan seek set socket source
    split string subst switch tell time trace unset update uplevel upvar variable vwait while
    bell bind bindtags button canvas checkbutton clipboard destroy entry event focus font frame grab grid image
    label labelframe listbox lower menu menubutton message option pack panedwindow place radiobutton raise
    scale scrollbar selection spinbox text tk toplevel winfo wm}
# deliberate, audited exceptions (never called bare inside their own namespace)
set allowed {theme::apply theme::menu theme::scale}
set only86 {lmap try finally throw tailcall "string cat" "dict getdef" "dict getwithdefault" lseq "string reverse" "chan configure"}
set fails 0
foreach f [lsort [glob -directory $dir *.tcl]] {
    set in [open $f r] ; fconfigure $in -encoding binary ; set bin [read $in] ; close $in
    if {[regexp {[\x80-\xff]} $bin]} { puts "NON-ASCII in [file tail $f]" ; incr fails }
    set in [open $f r] ; set src [read $in] ; close $in
    foreach {all ns name} [regexp -all -inline -line {^proc ::(\w+)::(\w+) } $src] {
        if {[lsearch -exact $builtin $name] >= 0 && [lsearch -exact $allowed "${ns}::$name"] < 0} {
            puts "SHADOWS Tcl/Tk command: ::$ns::$name  ([file tail $f])" ; incr fails
        }
    }
    set n 0
    foreach line [split $src \n] {
        incr n
        if {[string match "\\#*" [string trimleft $line]]} continue
        foreach w {lmap try finally throw tailcall} {
            if {[regexp "(^|\[\\\[;\{\] *)$w " $line]} { puts "8.6-only '$w' at [file tail $f]:$n" ; incr fails }
        }
    }
}
puts [expr {$fails ? "$fails lint problem(s)" : "lint clean"}]
exit [expr {$fails ? 1 : 0}]
