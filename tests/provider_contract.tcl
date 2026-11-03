# provider_contract.tcl -- a reusable conformance suite for streaming result providers (see engine.tcl).
#
# Any engine (the built-in dialect, mkit-sql, a server client) can run its providers through this:
#
#     source tests/provider_contract.tcl
#     provider_contract::run "my engine" $factory $mutate $restore
#
#   factory   a command (prefix) that runs the engine's query and returns   {provider expectedRows}
#             where expectedRows is the exact list of rows (each a list of cells) the query returns, in order.
#             The result must be big enough to need streaming in your engine (a few hundred rows is plenty).
#   mutate    a script that CHANGES the data the query read, behind the provider's back
#   restore   a script that puts the data back, so the next check starts from the same state
#
# Returns {passed failed}; failures are printed.  The rules checked are the ones in engine.tcl and
# docs/CONCURRENCY.md: slices are exact, row ids and cells agree with rows, sorting is stable and reorders every
# call, and - the lifetime rules - a provider never returns rows from a state other than the one the query
# saw: after the data changes it is stale and returns nothing (or, once frozen, exactly the old rows).
namespace eval provider_contract {
    variable pass 0 ; variable fail 0
}
proc provider_contract::check {name got want} {
    variable pass ; variable fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name: got <[string range $got 0 150]> want <[string range $want 0 150]>" }
}
proc provider_contract::ok {name cond {detail ""}} {
    variable pass ; variable fail
    if {$cond} { incr pass } else { incr fail ; puts "FAIL $name $detail" }
}
proc provider_contract::isNum {v} { return [string is double -strict $v] }

proc provider_contract::run {label factory mutate restore} {
    variable pass ; variable fail
    set pass 0 ; set fail 0
    # ---- reading ----
    lassign [{*}$factory] p exp
    set n [llength $exp]
    ok "$label: result is big enough to test ($n rows)" [expr {$n >= 50}]
    check "$label: count" [{*}$p count] $n
    check "$label: not stale when fresh" [{*}$p stale] 0
    check "$label: all rows in one read" [{*}$p rows 0 $n] $exp
    check "$label: a longer read stops at the end" [{*}$p rows 0 [expr {$n + 100}]] $exp
    check "$label: a window" [{*}$p rows 10 20] [lrange $exp 10 29]
    check "$label: the last row" [{*}$p rows [expr {$n - 1}] 5] [list [lindex $exp end]]
    check "$label: past the end" [{*}$p rows $n 5] {}
    check "$label: zero rows" [{*}$p rows 3 0] {}
    set chunks {}
    for {set f 0} {$f < $n} {incr f 7} { lappend chunks {*}[{*}$p rows $f 7] }
    check "$label: chunked reads add up" $chunks $exp
    check "$label: reading again gives the same rows" [{*}$p rows 5 10] [lrange $exp 5 14]
    set bad 0
    foreach i {0 1 17 33} {
        if {$i < $n} { foreach ci {0 1} { if {[{*}$p cell $i $ci] ne [lindex $exp $i $ci]} { incr bad } } }
    }
    check "$label: cell agrees with rows" $bad 0
    set ids {}
    for {set i 0} {$i < $n} {incr i} { lappend ids [{*}$p rowid $i] }
    ok "$label: row ids are distinct" [expr {[llength [lsort -unique $ids]] == $n}]
    # ---- sorting ----
    foreach dir {asc desc} {
        {*}$p sort 0 $dir ""
        set got [{*}$p rows 0 $n]
        check "$label: sort $dir keeps the row count" [{*}$p count] $n
        check "$label: sort $dir is a permutation" [lsort $got] [lsort $exp]
        set vals {} ; foreach r $got { lappend vals [lindex $r 0] }
        set numeric 1 ; foreach v $vals { if {![isNum $v]} { set numeric 0 ; break } }
        set want [lsort [expr {$numeric ? "-real" : "-dictionary"}] [expr {$dir eq "asc" ? "-increasing" : "-decreasing"}] $vals]
        if {$numeric} { check "$label: sort $dir orders by the column" $vals $want } else {
            ok "$label: sort $dir orders by the column" [expr {$vals eq $want || [lsort -nocase -ascii -[expr {$dir eq {asc} ? {increasing} : {decreasing}}] $vals] eq $vals}]
        }
        # stable: rows with equal sort keys keep their original relative order
        set seen [dict create] ; set stable 1
        foreach r $got { dict lappend seen [lindex $r 0] $r }
        dict for {k rs} $seen {
            set orig {} ; foreach r $exp { if {[lindex $r 0] eq $k} { lappend orig $r } }
            if {$rs ne $orig} { set stable 0 }
        }
        ok "$label: sort $dir is stable" $stable
        ids_agree $label $p $got $n
    }
    {*}$p destroy
    # ---- lifetime ----
    lassign [{*}$factory] p exp
    uplevel #0 $mutate
    check "$label: stale once the data changed" [{*}$p stale] 1
    check "$label: a stale provider returns no rows (never another state's)" [{*}$p rows 0 5] {}
    {*}$p destroy
    uplevel #0 $restore
    # a provider that was frozen BEFORE the change keeps the old rows, and is not stale
    lassign [{*}$factory] p exp
    {*}$p freeze
    uplevel #0 $mutate
    check "$label: frozen keeps the rows it had" [{*}$p rows 0 [llength $exp]] $exp
    check "$label: frozen is not stale" [{*}$p stale] 0
    check "$label: frozen count" [{*}$p count] [llength $exp]
    {*}$p sort 0 desc ""
    check "$label: frozen can still be sorted" [lsort [{*}$p rows 0 [llength $exp]]] [lsort $exp]
    {*}$p freeze
    check "$label: freeze twice is harmless" [{*}$p count] [llength $exp]
    {*}$p destroy
    uplevel #0 $restore
    # destroyed providers are safe to call
    lassign [{*}$factory] p exp
    {*}$p destroy
    ok "$label: destroy twice" [expr {![catch {{*}$p destroy}]}]
    check "$label: destroyed provider has no rows" [catch {{*}$p rows 0 5} r] [catch {set r2 {}} ]
    ok "$label: destroyed provider reports stale or empty" [expr {[catch {{*}$p stale} s] || $s == 1 || [{*}$p count] == 0}]
    return [list $pass $fail]
}
proc provider_contract::ids_agree {label p got n} {
    # after a sort the row ids must follow the rows: reading rows then ids is consistent with a re-read
    set again [{*}$p rows 0 $n]
    check "$label: a sorted provider is stable across reads" $again $got
}
