# mkql_reference.tcl -- TEST-ONLY.  The original, simple, row-at-a-time SELECT executor, kept verbatim
# (apart from names) as the oracle for tests/test_engine_diff.tcl: the optimised executor must
# return exactly what this one returns.  Not part of the application.
namespace eval ::mkqlref {
    namespace path ::mkql
    namespace upvar ::engine maxRows maxRows progressHook progressHook cancel cancel
}

proc ::mkqlref::scanRows {mk props subs where stopAt} {
    variable progressHook ; variable cancel
    set cancel 0
    set n [::store::size $mk]
    set out {} ; set found 0
    set chunk 500
    for {set first 0} {$first < $n} {incr first $chunk} {
        set rows [::store::rows $mk $props $first $chunk]
        set i $first
        foreach r $rows {
            set ctx [dict create _rowid $i]
            foreach p $props v $r { dict set ctx $p $v }
            foreach s $subs { dict set ctx $s [::store::subSize $mk $i $s] }
            if {$where eq "" || [truthy [ev $where $ctx]]} {
                lappend out $ctx
                incr found
                if {$stopAt && $found >= $stopAt} { return $out }
            }
            incr i
        }
        if {$progressHook ne ""} { uplevel #0 $progressHook }
        if {$cancel} { fail "Query cancelled" }
    }
    return $out
}

proc ::mkqlref::execSelect {q defaultDb} {
    variable maxRows
    set from [dict get $q from]
    set items [dict get $q items]
    if {$from eq ""} {
        # SELECT <expr>, ...   (calculator mode)
        bindSetup {} ""
        set cols {} ; set row {}
        foreach it $items {
            lassign $it e alias text
            set b [bindAst $e]
            lappend cols [expr {$alias ne "" ? $alias : $text}]
            if {[hasAgg $b]} { lappend row [ev $b {} [list {}]] } else { lappend row [ev $b {}] }
        }
        return [dict create kind rowset cols $cols types [lrepeat [llength $cols] ""] rows [list $row] \
            rowids {} source "" drill {} truncated 0 editable 0]
    }
    lassign [resolvePath $from $defaultDb] mk tag layout label
    bindSetup $layout $label

    # expand * into explicit items; each entry is {boundExpr name type subName}
    set sel {}
    foreach it $items {
        if {$it eq "star"} {
            foreach c $layout {
                lassign $c n t
                lappend sel [list [bindAst [list col $n {}]] $n $t [expr {$t eq "V" ? $n : ""}]]
            }
        } else {
            lassign $it e alias text
            set b [bindAst $e]
            set type "" ; set sub ""
            if {[lindex $b 0] eq "col"} {
                set cn [lindex $b 1]
                foreach c $layout { if {[lindex $c 0] eq $cn} { set type [lindex $c 1] } }
                if {$cn eq "_rowid"} { set type I }
                if {$type eq "V"} { set sub $cn }
                set name [expr {$alias ne "" ? $alias : $cn}]
            } else {
                set name [expr {$alias ne "" ? $alias : $text}]
            }
            lappend sel [list $b $name $type $sub]
        }
    }
    # aliases available to ORDER BY
    set ::mkql::baliases {}
    foreach s $sel { lappend ::mkql::baliases [string tolower [lindex $s 1]] }

    set where ""
    if {[dict get $q where] ne ""} {
        set where [bindAst [dict get $q where]]
        if {[hasAgg $where]} { fail "Aggregate functions are not allowed in WHERE; use HAVING" }
    }
    set groupBy {}
    foreach g [dict get $q group] { lappend groupBy [bindAst $g] }
    set having ""
    if {[dict get $q having] ne ""} { set having [bindAst [dict get $q having]] }
    set order {}
    foreach o [dict get $q order] {
        set e [lindex $o 0]
        if {[lindex $e 0] eq "num" && [string is integer -strict [lindex $e 1]]} {
            set k [lindex $e 1]
            if {$k < 1 || $k > [llength $sel]} { fail "ORDER BY position $k is out of range (1..[llength $sel])" }
            lappend order [list [list outcol [expr {$k-1}]] [lindex $o 1]]
        } else {
            lappend order [list [bindAst $e 1] [lindex $o 1]]
        }
    }

    set isAgg [expr {[llength $groupBy] > 0 || $having ne ""}]
    foreach s $sel { if {[hasAgg [lindex $s 0]]} { set isAgg 1 } }
    foreach o $order { if {[hasAgg [lindex $o 0]]} { set isAgg 1 } }

    lassign [usedLists $layout] props subs
    set limit [dict get $q limit] ; set offset [dict get $q offset]
    if {$offset eq ""} { set offset 0 }
    set top [dict get $q top]
    if {$limit eq "" && $top ne ""} { set limit $top }
    set distinct [dict get $q distinct]
    set needAll [expr {$isAgg || [llength $order] || $distinct}]
    set stopAt 0
    set truncated 0
    if {!$needAll} {
        set stopAt [expr {$limit ne "" ? $offset + $limit : $maxRows + 1}]
    }
    set ctxs [::mkqlref::scanRows $mk $props $subs $where $stopAt]

    # build output records: {outRow ctx}
    set recs {}
    if {$isAgg} {
        set groups [dict create]
        if {[llength $groupBy]} {
            foreach c $ctxs {
                set key {}
                foreach g $groupBy { lappend key [ev $g $c] }
                dict lappend groups $key $c
            }
        } else {
            dict set groups {} $ctxs
        }
        dict for {key grp} $groups {
            set first [expr {[llength $grp] ? [lindex $grp 0] : [dict create _rowid -1]}]
            if {[llength $grp] == 0} {
                # aggregates over an empty set: plain columns have no value
                foreach p $props { dict set first $p "" }
                foreach p $subs { dict set first $p 0 }
            }
            if {$having ne "" && ![truthy [ev $having $first $grp]]} continue
            set out {}
            foreach s $sel {
                lappend out [ev [lindex $s 0] $first $grp]
            }
            set c2 $first
            set i 0
            foreach s $sel { dict set c2 " [string tolower [lindex $s 1]]" [lindex $out $i] ; incr i }
            lappend recs [list $out $c2 $grp]
        }
    } else {
        foreach c $ctxs {
            set out {}
            foreach s $sel { lappend out [ev [lindex $s 0] $c] }
            if {[llength $order]} {
                set i 0
                foreach s $sel { dict set c " [string tolower [lindex $s 1]]" [lindex $out $i] ; incr i }
            }
            lappend recs [list $out $c {}]
        }
    }

    if {[llength $order]} {
        # Stable multi-key sort: sort by the LAST key first, then each earlier one.
        # Keys are typed up front so Tcl's native lsort does the work (a Tcl
        # comparator per pair is ~100x slower on large results).
        set n [llength $recs]
        set perm {}
        for {set i 0} {$i < $n} {incr i} { lappend perm $i }
        for {set k [expr {[llength $order] - 1}]} {$k >= 0} {incr k -1} {
            set o [lindex $order $k]
            set e [lindex $o 0]
            set kc {}
            foreach r $recs {
                lassign $r out c grp
                if {[lindex $e 0] eq "outcol"} {
                    lappend kc [lindex $out [lindex $e 1]]
                } else {
                    lappend kc [ev $e $c [expr {$isAgg ? $grp : "NOGROUP"}]]
                }
            }
            set perm [sortPerm $perm $kc [expr {[lindex $o 1] eq "desc"}]]
            if {$::mkql::progressHook ne ""} { uplevel #0 $::mkql::progressHook }
        }
        set recs2 {}
        foreach i $perm { lappend recs2 [lindex $recs $i] }
        set recs $recs2
    }

    if {$distinct} {
        set seen [dict create] ; set recs2 {}
        foreach r $recs {
            set k [lindex $r 0]
            if {![dict exists $seen $k]} { dict set seen $k 1 ; lappend recs2 $r }
        }
        set recs $recs2
    }

    set total [llength $recs]
    if {$offset > 0} { set recs [lrange $recs $offset end] }
    if {$limit ne ""} { set recs [lrange $recs 0 [expr {$limit - 1}]] }
    if {$limit eq "" && !$needAll && [llength $recs] > $maxRows} {
        set recs [lrange $recs 0 [expr {$maxRows - 1}]]
        set truncated 1
    }

    set rows {} ; set rowids {} ; set drill {}
    set colNames {} ; set colTypes {}
    set ci 0
    foreach s $sel {
        lappend colNames [lindex $s 1]
        set t [lindex $s 2]
        lappend colTypes $t
        if {[lindex $s 3] ne ""} { dict set drill $ci [lindex $s 3] }
        incr ci
    }
    set plain [expr {!$isAgg && !$distinct}]
    foreach r $recs {
        set out [lindex $r 0]
        if {[dict size $drill]} {
            dict for {i sub} $drill {
                set n [lindex $out $i]
                lset out $i "\u25B8 $n row[expr {$n == 1 ? {} : {s}}]"
            }
        }
        lappend rows $out
        if {$plain} { lappend rowids [dict get [lindex $r 1] _rowid] }
    }
    # tag derived numeric columns so the grid can right-align them
    set ci 0
    foreach t $colTypes {
        if {$t eq ""} {
            set allnum 1 ; set any 0
            foreach r $rows { set v [lindex $r $ci] ; if {$v eq ""} continue ; set any 1 ; if {![isnum $v]} { set allnum 0 ; break } }
            if {$any && $allnum} { lset colTypes $ci N }
        }
        incr ci
    }
    return [dict create kind rowset cols $colNames types $colTypes rows $rows rowids $rowids \
        source [expr {$plain ? $mk : ""}] drill $drill truncated $truncated editable $plain]
}

# Reorder `perm` (a list of record indices) by keys `kc` (indexed by record
# index).  Stable, so earlier sort passes act as tie-breakers.
