# verify.tcl -- checks the Tcl code the expression compiler generates BEFORE it is installed.
#
# SQL expressions are compiled into small Tcl procs (expr.tcl, cg).  Every value that comes from a
# user - a string literal, a number, a name, a parameter - is put into that code with [list], which
# makes it exactly one word.  This file is the second line of defence: it parses the generated text
# with a small Tcl parser and insists that it has the shape the compiler is supposed to emit and
# nothing else:
#
#   * every command is  ::mkitsql::rt::<existing proc> | if | set | lindex | list | string equal | return
#   * `set` assigns only _ or tN; `lindex` only reads $r0 / $outer / an earlier lindex with an integer
#   * variables are only $r0 $outer $_ $tN
#   * `if` is  if {[cmd]|0|1 eq/ne "0"|"1"} {script} else {script}
#   * no word anywhere starts a substitution that was not written by the compiler
#
# If a literal ever managed to break out of its word, the text would contain a command that is not
# on this list and the statement is refused with "internal error: unsafe code".  Run on every
# compile (it costs microseconds); tests/injection.tcl and tests/codegen_audit.tcl exercise it.

namespace eval ::mkitsql {
    variable verifyOn 1
    variable verifyCmds {if set lindex list string return}
}

namespace eval ::mkitsql { variable verifiedOk ; array set verifiedOk {} }
proc ::mkitsql::verifyCode {text} {
    variable verifyOn ; variable verifiedOk
    if {!$verifyOn} return
    # verification is a pure function of the text: code that passed once passes again
    if {[info exists verifiedOk($text)]} return
    set pos 0
    if {[catch {vScript $text pos 0 0} msg opts]} {
        # running out of stack on a very deeply nested expression is reported by the caller as such
        if {[string match "too many nested evaluations*" $msg]} { return -options $opts $msg }
        error "internal error: unsafe code was generated for an expression ($msg)" "" {MKQL INTERNAL}
    }
    if {[array size verifiedOk] >= 2000} { array unset verifiedOk }
    set verifiedOk($text) 1
}

# parse a script starting at pos; closer = 1 when inside [ ... ] (stops at the matching ])
proc ::mkitsql::vScript {s posVar closer depth} {
    upvar 1 $posVar pos
    if {$depth > 400} { error "nesting too deep" }
    set n [string length $s]
    while 1 {
        # skip separators
        while {$pos < $n && [string index $s $pos] in {" " "\t" "\n" ";"}} { incr pos }
        if {$pos >= $n} {
            if {$closer} { error "missing ]" }
            return
        }
        if {$closer && [string index $s $pos] eq "\]"} { incr pos ; return }
        # one command
        set words {}
        while 1 {
            while {$pos < $n && [string index $s $pos] in {" " "\t"}} { incr pos }
            if {$pos >= $n} break
            set c [string index $s $pos]
            if {$c in {"\n" ";"}} break
            if {$closer && $c eq "\]"} break
            lappend words [vWord $s pos $depth]
        }
        vCommand $words $depth
    }
}

# one word -> {kind value}: lit (data), var name, cmd (a bracketed sub-script, already verified),
# brace (raw braced text)
proc ::mkitsql::vWord {s posVar depth} {
    upvar 1 $posVar pos
    set n [string length $s]
    set c [string index $s $pos]
    switch -- $c {
        "\[" {
            incr pos
            set start $pos
            # the sub-script's command name is checked by vCommand through a re-parse
            vScript $s pos 1 [expr {$depth + 1}]     ;# verifies every command inside
            return [list cmd ""]
        }
        "\{" {
            set start [incr pos]
            set lvl 1
            while {$pos < $n} {
                set ch [string index $s $pos]
                if {$ch eq "\\"} { incr pos 2 ; continue }
                if {$ch eq "\{"} { incr lvl } elseif {$ch eq "\}"} { if {[incr lvl -1] == 0} break }
                incr pos
            }
            if {$lvl != 0} { error "unbalanced brace" }
            set body [string range $s $start [expr {$pos - 1}]]
            incr pos
            if {$pos < $n && [string index $s $pos] ni {" " "\t" "\n" ";" "\]"}} { error "text after a braced word" }
            return [list brace $body]
        }
        "\"" { error "quoted word" }
        "$" {
            incr pos
            if {![regexp -start $pos {\A(r0|outer|_|t[0-9]+)(?![A-Za-z0-9_(:])} $s -> name]} { error "variable reference" }
            incr pos [string length $name]
            if {$pos < $n && [string index $s $pos] ni {" " "\t" "\n" ";" "\]"}} { error "text after a variable" }
            return [list var $name]
        }
    }
    # bare word: data.  Only backslash escapes are allowed to be "active"; an unescaped [ $ " or ] inside is a bug.
    set start $pos
    while {$pos < $n} {
        set ch [string index $s $pos]
        if {$ch eq "\\"} {
            if {$pos + 1 >= $n} { error "trailing backslash" }
            incr pos 2 ; continue
        }
        if {$ch in {" " "\t" "\n" ";" "\]"}} break
        if {$ch in {"\[" "$" "\""}} { error "unescaped substitution character in a word" }
        incr pos
    }
    if {$pos == $start} { error "unexpected character '[string index $s $pos]'" }
    return [list lit [string range $s $start [expr {$pos - 1}]]]
}

# check one parsed command (list of words)
proc ::mkitsql::vCommand {words depth} {
    variable verifyCmds
    if {![llength $words]} return
    lassign [lindex $words 0] kind name
    if {$kind ne "lit"} { error "command name is not a plain word" }
    set args [lrange $words 1 end]
    if {[string match ::mkitsql::rt::* $name]} {
        if {![regexp {^::mkitsql::rt::[A-Za-z0-9_]+$} $name] || ![llength [info commands $name]]} { error "unknown runtime command $name" }
        vArgs $args $depth
        return
    }
    if {$name ni $verifyCmds} { error "command '$name' is not allowed" }
    switch -- $name {
        set {
            if {[llength $args] != 2} { error "set needs two words" }
            lassign [lindex $args 0] k v
            if {$k ne "lit" || ![regexp {^(_|t[0-9]+)$} $v]} { error "set target" }
        }
        lindex {
            if {[llength $args] != 2} { error "lindex needs two words" }
            lassign [lindex $args 0] k v
            if {!(($k eq "var" && $v in {r0 outer}) || $k eq "cmd")} { error "lindex source" }
            lassign [lindex $args 1] k2 v2
            if {$k2 ne "lit" || ![regexp {^[0-9]+$} $v2]} { error "lindex index" }
        }
        string {
            lassign [lindex $args 0] k v
            if {$k ne "lit" || $v ne "equal" || [llength $args] != 3} { error "only string equal" }
            vArgs [lrange $args 1 end] $depth
        }
        list - return { vArgs $args $depth }
        if {
            # if {cond} {then} else {else}
            if {[llength $args] != 4} { error "if shape" }
            lassign $args cnd thn els elb
            if {[lindex $cnd 0] ne "brace" || [lindex $thn 0] ne "brace" || [lindex $elb 0] ne "brace"} { error "if bodies" }
            if {[lindex $els 0] ne "lit" || [lindex $els 1] ne "else"} { error "if else" }
            vExprCond [lindex $cnd 1] $depth
            set p 0 ; vScript [lindex $thn 1] p 0 [expr {$depth + 1}]
            set p 0 ; vScript [lindex $elb 1] p 0 [expr {$depth + 1}]
        }
    }
}
# arguments: data words, variables and bracketed commands are fine (brackets were parsed by vWord and
# their commands are checked by re-parsing the text).
proc ::mkitsql::vArgs {args_ depth} {
    foreach w $args_ {
        lassign $w k v
        switch -- $k {
            cmd - lit - var {}
            brace {}
            default { error "word kind $k" }
        }
    }
}
# the condition of a generated  if : a single [command], optionally  eq "0" / ne "1"
proc ::mkitsql::vExprCond {text depth} {
    set t [string trim $text]
    if {[string index $t 0] ne "\["} { error "if condition" }
    set pos 1
    vScript $t pos 1 [expr {$depth + 1}]      ;# verifies the command and finds its closing bracket
    set tail [string trim [string range $t $pos end]]
    if {$tail ne "" && ![regexp {^(eq|ne) "[01]"$} $tail]} { error "if condition tail" }
}
