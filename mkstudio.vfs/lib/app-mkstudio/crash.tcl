# crash.tcl -- what happens when MK Studio itself goes wrong.
#
#   * An error nobody handled (a Tk callback, a bug) is caught here: the user sees a short dialog, and a report is written
#     to the crash folder.  Nothing is ever sent anywhere by the program; the dialog can copy the report or open a
#     pre-filled GitHub issue in the browser - the user reads it first and presses the button.
#   * The report holds: version, system, Tcl/Tk versions, the error message, the call stack as procedure names and line
#     numbers, and the last few "breadcrumbs" (what the program was doing, e.g. "database opened", "commit",
#     "query run (82 characters)").  It does NOT hold SQL text, rows, cell values or database contents; the user's home
#     folder and user name are replaced, and database file names are shortened.
#   * A crash the program cannot catch (Metakit or Tk dying, the power going) is noticed at the NEXT start: every
#     running copy keeps a marker file with its recent breadcrumbs; a marker whose process is gone was never removed by
#     a clean exit.  That becomes a report too.
# No Tk in this file except in `dialog`; tests/test_crash.tcl drives everything else.
namespace eval ::crash {
    variable crumbs {}              ;# ring buffer of recent breadcrumbs (time + text)
    variable crumbMax 60
    variable marker ""              ;# this process's marker file
    variable markerCh ""
    variable seen                   ;# error signature -> count
    array set seen {}
    variable dialogs 0              ;# dialogs shown this session
    variable inHandler 0
    variable started [clock seconds]
    variable keep 20                ;# reports kept
    variable lastReport ""
}

proc ::crash::dir {} {
    if {[info exists ::env(MKS_CRASH_DIR)] && $::env(MKS_CRASH_DIR) ne ""} { return $::env(MKS_CRASH_DIR) }
    if {[info exists ::env(LOCALAPPDATA)]} { return [file join $::env(LOCALAPPDATA) MKStudio crashes] }
    if {[info exists ::env(APPDATA)]} { return [file join $::env(APPDATA) MKStudio crashes] }
    set home ~ ; catch {set home [file normalize ~]}
    if {$::tcl_platform(os) eq "Darwin"} { return [file join $home Library Logs MKStudio] }
    if {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""} { return [file join $::env(XDG_STATE_HOME) mkstudio crashes] }
    return [file join $home .local state mkstudio crashes]
}
proc ::crash::ensureDir {} { set d [dir] ; catch {file mkdir $d} ; return $d }

# ---- breadcrumbs ------------------------------------------------------------------------------------------------------------
# Record what the program is doing.  Text only; never pass SQL or data.
proc ::crash::crumb {text} {
    variable crumbs ; variable crumbMax ; variable markerCh
    set line "[clock format [clock seconds] -format %H:%M:%S] [string range [string map {"\n" " "} $text] 0 120]"
    lappend crumbs $line
    if {[llength $crumbs] > $crumbMax} { set crumbs [lrange $crumbs end-[expr {$crumbMax - 1}] end] }
    if {$markerCh ne ""} { catch {puts $markerCh $line ; flush $markerCh} }
}

# ---- sessions: a marker per running copy ------------------------------------------------------------------------------------
# Call at start.  Returns the list of earlier sessions that ended without a clean exit: each {markerFile pid crumbs}.
proc ::crash::start {} {
    variable marker ; variable markerCh
    set d [ensureDir]
    set dead {}
    foreach m [glob -nocomplain -directory $d running-*.log] {
        if {![regexp {running-(\d+)\.log$} $m -> pid]} continue
        if {$pid == [pid]} continue
        if {[catch {::store::pidAlive $pid} alive]} { set alive [expr {![catch {exec kill -0 $pid}]}] }
        if {$alive} continue
        set crumbs {}
        catch {set h [open $m r] ; set crumbs [split [string trim [read $h]] "\n"] ; close $h}
        lappend dead [list $m $pid $crumbs]
    }
    set marker [file join $d running-[pid].log]
    if {[catch {set markerCh [open $marker w]}]} { set markerCh "" ; set marker "" } else {
        fconfigure $markerCh -buffering line
        puts $markerCh "started [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] version $::version::current"
        flush $markerCh
    }
    return $dead
}
# Call on a clean exit.
proc ::crash::cleanExit {} {
    variable marker ; variable markerCh
    if {$markerCh ne ""} { catch {close $markerCh} ; set markerCh "" }
    if {$marker ne ""} { catch {file delete $marker} ; set marker "" }
}
# Turn the dead sessions found by `start` into one report each; removes their markers.  Returns the report files.
proc ::crash::reportDead {dead} {
    set out {}
    foreach s $dead {
        lassign $s m pid crumbs
        set text [header "The previous session ended unexpectedly (process $pid)" ]
        append text "\nNo error was caught: the program was ended from outside, crashed inside a library, or the computer lost power.\n"
        append text "\nLast things it was doing:\n"
        foreach c [lrange $crumbs 1 end] { append text "  $c\n" }
        if {[llength $crumbs] <= 1} { append text "  (nothing recorded)\n" }
        lappend out [save $text unexpected-end]
        catch {file delete $m}
    }
    return $out
}

# ---- the report -------------------------------------------------------------------------------------------------------------
proc ::crash::scrub {text} {
    set map {}
    foreach v {HOME USERPROFILE} {
        if {[info exists ::env($v)] && [string length $::env($v)] > 2} {
            lappend map $::env($v) ~ [file nativename $::env($v)] ~ [string map {\\ /} $::env($v)] ~
        }
    }
    set text [string map $map $text]
    # the user name, as text (NOT as a pattern: a name such as "Ann (Work" or "Bob[1]" is not a valid regular expression)
    foreach v {USER USERNAME LOGNAME} {
        if {[info exists ::env($v)] && [string length $::env($v)] > 2} { set text [string map [list $::env($v) <user>] $text] }
    }
    # Quoted text in an error message is where a value can sneak in ("bad value 'Jane Roe 123-45-6789'").  Quotes around a plain
    # name (a variable, a command, a view) stay - that is what makes the message useful; anything else inside quotes goes.
    set text [scrubQuoted $text]
    # file names are the user's business: a path (it runs to the next ": " or the end of the line - folder names have spaces)
    # becomes <folder>/<file> plus its extension; so does a bare name that looks like a database file
    set text [scrubPaths $text]
    regsub -all {[^\s"'<>|/\\]+(\.(?:mk|mk4|mkd|db|dat|kit|metakit))(?![A-Za-z0-9_])} $text {<file>\1} text
    return $text
}
proc ::crash::scrubPaths {text} {
    set out "" ; set pos 0
    set re {(?:[A-Za-z]:[\\/]|~[\\/]|/)(?:[^\n"'<>|:]|:(?! ))+}
    while {[regexp -indices -start $pos $re $text m]} {
        lassign $m s e
        set prev [expr {$s == 0 ? " " : [string index $text [expr {$s - 1}]]}]
        if {![string is space $prev] && [string first $prev "(\[\{=,\"'"] < 0} {
            append out [string range $text $pos $s] ; set pos [expr {$s + 1}] ; continue       ;# "and/or", "a/b": not a path
        }
        set hit [string range $text $s $e]
        set ext ""
        regexp {(\.[A-Za-z0-9]{1,6})\s*$} $hit -> ext
        append out [string range $text $pos [expr {$s - 1}]] "<folder>/<file>$ext"
        set pos [expr {$e + 1}]
    }
    append out [string range $text $pos end]
    return $out
}
proc ::crash::scrubQuoted {text} {
    set out "" ; set pos 0 ; set n [string length $text]
    while {$pos < $n} {
        # a quote opens a quoted string only at the start of a word - the apostrophe in "can't" does not
        set qs -1 ; set from $pos
        while {[regexp -indices -start $from {['"]} $text m]} {
            set at [lindex $m 0]
            set prev [expr {$at == 0 ? " " : [string index $text [expr {$at - 1}]]}]
            if {[string is space $prev] || [string first $prev "(\[\{=:,"] >= 0} { set qs $at ; break }
            set from [expr {$at + 1}]
        }
        if {$qs < 0} break
        set quote [string index $text $qs]
        set close [string first $quote $text [expr {$qs + 1}]]
        if {$close < 0} break
        set body [string range $text [expr {$qs + 1}] [expr {$close - 1}]]
        append out [string range $text $pos $qs]
        if {[regexp {^[A-Za-z_:][A-Za-z0-9_:.\-]{0,60}$} $body]} { append out $body } else { append out "..." }
        append out $quote
        set pos [expr {$close + 1}]
    }
    append out [string range $text $pos end]
    return $out
}
proc ::crash::header {title} {
    set tk "no"
    catch {set tk "[package present Tk] ([tk windowingsystem])"}
    set mk [expr {[llength [info commands ::mk::file]] ? "yes" : "no"}]
    set mode "source"
    if {[info exists ::starkit::mode]} { set mode $::starkit::mode }
    set engine ""
    catch {set engine $::engine::name}
    set t "MK Studio crash report\n"
    append t "$title\n\n"
    append t "Time:       [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %Z}]\n"
    append t "Version:    $::version::current ($mode)\n"
    append t "System:     $::tcl_platform(os) $::tcl_platform(osVersion) $::tcl_platform(machine)\n"
    append t "Tcl / Tk:   [info patchlevel] / $tk\n"
    append t "Metakit:    $mk\n"
    if {$engine ne ""} { append t "Engine:     $engine\n" }
    append t "Running:    [expr {[clock seconds] - $::crash::started}] seconds\n"
    return $t
}
# the call stack as "procedure line" pairs - the code excerpts in errorInfo can contain SQL and data, so they are dropped
proc ::crash::stackSummary {errorInfo} {
    set lines {}
    foreach {all name ln} [regexp -all -inline {\((?:procedure|file) "([^"]+)" line (\d+)\)} $errorInfo] {
        lappend lines "  $name line $ln"
    }
    if {![llength $lines]} { return "  (no procedure frames)" }
    return [join $lines "\n"]
}
proc ::crash::build {msg errorInfo kind} {
    variable crumbs
    set text [header "$kind error"]
    append text "\nError:\n  [string range [string map {"\n" "\n  "} [scrub $msg]] 0 600]\n"
    append text "\nWhere (procedures, innermost first):\n[scrub [stackSummary $errorInfo]]\n"
    append text "\nLast things the program was doing:\n"
    foreach c $crumbs { append text "  $c\n" }
    if {![llength $crumbs]} { append text "  (nothing recorded)\n" }
    append text "\nNothing in this report comes from your databases: no SQL text, no rows or cell values.\n"
    return $text
}
proc ::crash::save {text {tag crash}} {
    variable keep ; variable lastReport
    set d [ensureDir]
    set base [file join $d $tag-[clock format [clock seconds] -format %Y%m%d-%H%M%S]]
    set f $base.txt ; set n 1
    while {[file exists $f]} { set f $base-[incr n].txt }
    if {[catch {set h [open $f w] ; fconfigure $h -encoding utf-8 ; puts -nonewline $h $text ; close $h}]} { return "" }
    set lastReport $f
    # keep the newest `keep` reports of each kind (by modification time, not by name: many "unexpected-end" files must not push
    # out the one real "crash" report that was just written)
    foreach kind {crash unexpected-end} {
        set all {}
        foreach x [glob -nocomplain -directory $d $kind-*.txt] { if {$x ne $f} { lappend all [list [file mtime $x] $x] } }
        set all [lsort -decreasing -index 0 -integer $all]
        # (the report just written always stays, whatever the clock says about its neighbours)
        set room [expr {[string match $d/$kind-* $f] ? $keep - 1 : $keep}]
        foreach old [lrange $all $room end] { catch {file delete [lindex $old 1]} }
    }
    return $f
}
# the whole story for one error; returns {file text}
proc ::crash::record {msg errorInfo {kind "Unhandled"}} {
    set text [build $msg $errorInfo $kind]
    return [list [save $text crash] $text]
}

# ---- the handler ---------------------------------------------------------------------------------------------------------
# bgerror replacement: record, tell the user once per distinct error (at most 3 dialogs a session), never loop.
proc ::crash::handle {msg errorInfo {kind "Unhandled"}} {
    variable seen ; variable inHandler ; variable dialogs
    if {$inHandler} return
    set inHandler 1
    catch {
        set sig [string range $msg 0 100]|[lindex [regexp -inline {\((?:procedure|file) "([^"]+)"} $errorInfo] 1]
        if {[info exists seen($sig)]} { incr seen($sig) ; return }
        set seen($sig) 1
        lassign [record $msg $errorInfo $kind] file text
        # tests: an error that nothing handled must fail the test, not open a dialog nobody can click
        if {[info exists ::env(MKS_CRASH_FATAL)] && $::env(MKS_CRASH_FATAL)} {
            puts stderr "UNHANDLED ERROR ($kind): $msg\n$errorInfo" ; exit 1
        }
        if {[llength [info commands ::crash::dialog]] && $dialogs < 3 && [info exists ::tk_version]} {
            incr dialogs
            dialog $file $text
        }
    }
    set inHandler 0
}
proc ::crash::install {} {
    catch {rename ::bgerror ::crash::originalBgerror}
    proc ::bgerror {msg} { ::crash::handle $msg $::errorInfo background }
}
# open the default browser (a URL, or a folder)
proc ::crash::openExternal {target} {
    switch -- $::tcl_platform(platform) {
        windows { return [catch {exec rundll32 url.dll,FileProtocolHandler $target &}] }
        default {
            set cmd [expr {$::tcl_platform(os) eq "Darwin" ? "open" : "xdg-open"}]
            return [catch {exec $cmd $target > /dev/null 2>@1 &}]
        }
    }
}
proc ::crash::urlEncode {s} {
    set out ""
    foreach ch [split [encoding convertto utf-8 $s] ""] {
        scan $ch %c c
        if {[string is alnum -strict $ch] && $c < 128 || $ch in {- _ . ~}} { append out $ch } else { append out [format %%%02X $c] }
    }
    return $out
}
# a GitHub "new issue" link with the report filled in (kept short: URLs have a length limit)
proc ::crash::issueUrl {text} {
    set body "**What I was doing:** (please describe)\n\n**Report** (nothing from my databases is in it):\n```\n[string range $text 0 3200]\n```\n"
    return "https://github.com/$::version::repo/issues/new?title=[urlEncode {Crash report}]&body=[urlEncode $body]"
}

# The dialog (needs Tk and ::ui).  Loops until the user continues or quits; the report is already on disk.
proc ::crash::dialog {file text} {
    set msg "Something went wrong inside MK Studio.\n\nYour databases are not affected by this message: nothing is written to a database until you commit, and an interrupted commit is undone the next time the file is opened.\n\nA report was saved:\n$file\n\nIt contains no SQL text and no data from your databases. Nothing is sent anywhere unless you choose \"Report on GitHub\" and submit it yourself."
    while 1 {
        set r [::ui::ask "MK Studio hit a problem" $msg {Continue "Copy Report" "Report on GitHub" "Open Folder" Quit} error]
        switch -- $r {
            "Copy Report"       { clipboard clear ; clipboard append $text }
            "Report on GitHub"  { openExternal [issueUrl $text] }
            "Open Folder"       { openExternal [file dirname $file] }
            Quit                { catch {::app::quit} ; if {[winfo exists .]} { cleanExit ; exit 1 } ; return }
            default             { return }
        }
    }
}
