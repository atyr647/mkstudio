# exec.tcl -- the streaming executor of mkit-sql.
#
# A plan is run by *pushing* chunks of tuples through a pipeline of stages:
#
#     scan -> filter -> [aggregate] -> [windows] -> project -> [distinct] -> [sort] -> limit -> sink
#
# A stage is a command prefix called with one chunk; it returns 1 when no more input is wanted
# (a satisfied LIMIT, an EXISTS that found its row, a result cap), which stops the scan beneath it.
# Stages that must see all their input (sort, aggregate, distinct, windows, join build sides)
# stay inside ::mkitsql::memBytes and spill to temporary files beyond it (see spill.tcl), so memory
# use does not grow with the size of the table.  Nothing is ever held in memory just because a
# query is large: only the final result handed back to the caller is, and callers can stream it.

namespace eval ::mkitsql {
    variable planSeq
    variable wtable
    variable maxRecursion
    variable maxWorkRows
    variable lookupOff
    array set lookupOff {}
}

# ============================================================================
#  Small stages
# ============================================================================
proc ::mkitsql::stFilter {w outer next chunk} {
    set keep {}
    foreach r $chunk { if {[$w $r $outer] eq "1"} { lappend keep $r } }
    return [emit $next $keep]
}
proc ::mkitsql::filterRows {rows filter outer} {
    if {$filter eq ""} { return $rows }
    set out {}
    foreach r $rows { if {[$filter $r $outer] eq "1"} { lappend out $r } }
    return $out
}
# a sink that appends to a list, optionally stopping after `limit` rows
proc ::mkitsql::colSink {c chunk} {
    variable S
    if {$S($c,limit) > 0} {
        set room [expr {$S($c,limit) - [llength $S($c,rows)]}]
        if {[llength $chunk] >= $room} {
            lappend S($c,rows) {*}[lrange $chunk 0 [expr {$room - 1}]]
            return 1
        }
    }
    lappend S($c,rows) {*}$chunk
    return 0
}
proc ::mkitsql::collectPlan {id outer {limit 0}} {
    variable S
    set c [newId]
    set S($c,rows) {} ; set S($c,limit) $limit
    streamPlan $id $outer [list ::mkitsql::colSink $c]
    set r $S($c,rows)
    array unset S $c,*
    return $r
}
proc ::mkitsql::runPlan {id outer} { return [collectPlan $id $outer] }

# OFFSET / LIMIT
proc ::mkitsql::stLimit {i next chunk} {
    variable S
    if {$S($i,skip) > 0} {
        set n [llength $chunk]
        if {$n <= $S($i,skip)} { incr S($i,skip) -$n ; return 0 }
        set chunk [lrange $chunk $S($i,skip) end]
        set S($i,skip) 0
    }
    set stop 0
    if {$S($i,left) >= 0} {
        if {[llength $chunk] >= $S($i,left)} {
            set chunk [lrange $chunk 0 [expr {$S($i,left) - 1}]]
            set S($i,left) 0 ; set stop 1
        } else {
            incr S($i,left) -[llength $chunk]
        }
    }
    if {[emit $next $chunk]} { return 1 }
    return $stop
}
# remembers that the *consumer* (not an internal LIMIT) asked to stop
proc ::mkitsql::stFinal {i sink chunk} {
    variable S
    if {[emit $sink $chunk]} { set S($i,stopped) 1 ; return 1 }
    return 0
}
proc ::mkitsql::stStrip {nk hasRid next chunk} {
    set out {}
    if {$hasRid} {
        foreach rec $chunk { lappend out [list [lindex $rec $nk] [lindex $rec [expr {$nk + 1}]]] }
    } else {
        foreach rec $chunk { lappend out [lindex $rec $nk] }
    }
    return [emit $next $out]
}
proc ::mkitsql::stKeyEq {ikey okey next chunk} {
    set keep {}
    foreach t $chunk { if {[$ikey $t {}] eq $okey} { lappend keep $t } }
    return [emit $next $keep]
}

# ============================================================================
#  Plans
# ============================================================================
# Run plan `id`, pushing chunks of result rows to `sink`.  With ids=1 a plain single-table
# query pushes {row rowid} pairs.  Returns 1 if the sink asked to stop.
proc ::mkitsql::streamPlan {id outer sink {ids 0}} {
    variable plans
    set p $plans($id)
    switch -- [dict get $p kind] {
        select    { return [selectStream $p $outer $sink $ids] }
        values {
            if {[dict exists $p lits]} { return [emitAll $sink [dict get $p lits]] }
            set out {}
            foreach pr [dict get $p procs] { lappend out [$pr {} $outer] }
            return [emitAll $sink $out]
        }
        setop     { return [setopStream $p $outer $sink] }
        recursive { return [recursiveStream $p $outer $sink] }
        query     { return [queryStream $p $outer $sink] }
    }
    error "streamPlan: [dict get $p kind]"
}

# ---- SELECT ------------------------------------------------------------------
proc ::mkitsql::selectStream {p outer sink ids} {
    variable S
    set order [dict get $p order] ; set nk [llength $order]
    set curPos [dict get $p curPos]
    set hasRid [expr {$ids && $curPos >= 0}]
    set limit [dict get $p limit] ; set offset [dict get $p offset]
    if {$offset eq ""} { set offset 0 }
    set okeys [expr {[dict exists $p okeys] ? [dict get $p okeys] : ""}]

    set fin [newId] ; set S($fin,stopped) 0
    set head [list ::mkitsql::stFinal $fin $sink]
    set flushes {} ; set ids2 [list $fin]

    if {$limit ne "" || $offset > 0} {
        set li [newId] ; lappend ids2 $li
        set S($li,skip) $offset ; set S($li,left) [expr {$limit eq "" ? -1 : $limit}]
        set head [list ::mkitsql::stLimit $li $head]
    }
    if {$nk > 0} {
        set head [list ::mkitsql::stStrip $nk $hasRid $head]
        set top [expr {$limit eq "" ? 0 : $limit + $offset}]
        set si [sortStageNew $order $top] ; lappend ids2 $si
        set flushes [linsert $flushes 0 [list ::mkitsql::sortFlush $si $head]]
        set head [list ::mkitsql::sortAdd $si]
    }
    if {[dict get $p distinct]} {
        set keyIdx [expr {$nk > 0 ? $nk : ($hasRid ? 0 : -1)}]
        set di [distNew $keyIdx $head] ; lappend ids2 $di
        set flushes [linsert $flushes 0 [list ::mkitsql::distFlush $di]]
        set head [list ::mkitsql::distAdd $di]
    }
    set head [list ::mkitsql::stProject [dict get $p items] $okeys $order $nk $hasRid $curPos $outer $head]
    if {[dict exists $p windows]} {
        set wi [winStageNew [dict get $p windows]] ; lappend ids2 $wi
        set flushes [linsert $flushes 0 [list ::mkitsql::winFlush $wi $outer $head]]
        set head [list ::mkitsql::winAdd $wi]
    }
    set w [dict get $p where]
    set countAll ""
    if {[dict exists $p agg]} {
        if {[dict exists $p having]} { set head [list ::mkitsql::stFilter [dict get $p having] $outer $head] }
        # SELECT COUNT(*) FROM table  with nothing else to decide: Metakit knows the row count
        set a [dict get $p agg] ; set src [dict get $p src]
        if {$w eq "" && [dict get $a ng] == 0 && [llength [dict get $a specs]] == 1 && [lindex [dict get $a specs] 0 0] eq "cstar" \
                && [dict get $src kind] eq "scan" && [dict get $src filter] eq "" && [dict get $src lookup] eq ""} {
            set countAll [::mkitsql::db::size [dict get $src path]]
        } else {
            set ai [aggNew $a] ; lappend ids2 $ai
            set flushes [linsert $flushes 0 [list ::mkitsql::aggFlush $ai $outer $head]]
            set head [list ::mkitsql::aggAdd $ai $outer]
        }
    }
    if {$w ne ""} { set head [list ::mkitsql::stFilter $w $outer $head] }

    if {$countAll ne ""} {
        set stopped [emit $head [list [list $countAll]]]
    } else {
        set stopped [srcStream [dict get $p src] $outer $head]
    }
    if {!$stopped} {
        foreach f $flushes { if {[{*}$f]} break }
    }
    set result $S($fin,stopped)
    foreach i $ids2 { stageFree $i }
    return $result
}
proc ::mkitsql::stageFree {i} {
    variable S
    if {[info exists S($i,sorter)]} { sorterFree $S($i,sorter) }
    if {[info exists S($i,spool)]} { spoolFree $S($i,spool) }
    if {[info exists S($i,dsorter)]} { sorterFree $S($i,dsorter) }
    if {[info exists S($i,asorter)]} { sorterFree $S($i,asorter) }
    if {[info exists S($i,subs)]} { foreach sub $S($i,subs) { stageFree $sub } }
    if {[info exists S($i,cbSort)] && $S($i,cbSort) ne ""} { sorterFree $S($i,cbSort) }
    catch {namespace delete ::mkitsql::agg::A$i}
    array unset S $i,*
}

# projection: one output tuple per input row, with sort keys and row id when needed
proc ::mkitsql::stProject {items okeys order nk hasRid curPos outer next chunk} {
    set recs {}
    if {$nk == 0 && !$hasRid} {
        foreach r $chunk { lappend recs [$items $r $outer] }
    } elseif {$nk == 0} {
        foreach r $chunk { lappend recs [list [$items $r $outer] [lindex [split [lindex $r $curPos] !] end]] }
    } else {
        foreach r $chunk {
            set out [$items $r $outer]
            if {$okeys ne ""} { set ek [$okeys $r $outer] } else { set ek {} }
            set rec {}
            foreach o $order {
                if {[lindex $o 0] eq "out"} { lappend rec [lindex $out [lindex $o 1]] } else { lappend rec [lindex $ek [lindex $o 1]] }
            }
            lappend rec $out
            if {$hasRid} { lappend rec [lindex [split [lindex $r $curPos] !] end] }
            lappend recs $rec
        }
    }
    return [emit $next $recs]
}

# ---- sort / top-N -----------------------------------------------------------
proc ::mkitsql::sortStageNew {spec top} {
    variable S
    set i [newId]
    set S($i,spec) $spec ; set S($i,top) $top ; set S($i,buf) {}
    if {$top > 100000} { set S($i,top) 0 }
    if {$S($i,top) == 0} { set S($i,sorter) [sorterNew $spec] }
    return $i
}
proc ::mkitsql::sortAdd {i chunk} {
    variable S
    if {$S($i,top) > 0} {
        lappend S($i,buf) {*}$chunk
        set top $S($i,top)
        if {[llength $S($i,buf)] > [expr {max(2 * $top, $top + 2000)}]} {
            set S($i,buf) [lrange [sortRecs $S($i,buf) $S($i,spec)] 0 [expr {$top - 1}]]
        }
    } else {
        sorterAdd $S($i,sorter) $chunk
    }
    return 0
}
proc ::mkitsql::sortFlush {i next} {
    variable S
    if {$S($i,top) > 0} {
        set recs [lrange [sortRecs $S($i,buf) $S($i,spec)] 0 [expr {$S($i,top) - 1}]]
        set S($i,buf) {}
        return [emitAll $next $recs]
    }
    return [sorterDrain $S($i,sorter) $next]
}

# ---- DISTINCT: streaming, spilling rows whose first sighting does not fit --------------
proc ::mkitsql::distNew {keyIdx next} {
    variable S ; variable memBytes
    set i [newId]
    set S($i,key) $keyIdx ; set S($i,next) $next ; set S($i,seen) [dict create]
    set S($i,bytes) 0 ; set S($i,over) 0
    return $i
}
proc ::mkitsql::distAdd {i chunk} {
    variable S ; variable memBytes
    set keyIdx $S($i,key)
    set fresh {} ; set spill {}
    foreach rec $chunk {
        if {$keyIdx < 0} { set k [::mkitsql::rt::sk $rec] } else { set k [lindex $rec $keyIdx] }
        if {[dict exists $S($i,seen) $k]} continue
        if {$S($i,over)} { lappend spill [list $k $rec] ; continue }
        dict set S($i,seen) $k 1
        incr S($i,bytes) [expr {3 * [string length $k] + 160}]
        lappend fresh $rec
        if {$S($i,bytes) > $memBytes} {
            set S($i,over) 1
            set S($i,dsorter) [sorterNew {{key 0 asc "" text}}]
        }
    }
    if {[llength $spill]} { sorterAdd $S($i,dsorter) $spill }
    return [emit $S($i,next) $fresh]
}
proc ::mkitsql::distFlush {i} {
    variable S
    if {!$S($i,over)} { return 0 }
    set r [sorterReader $S($i,dsorter)]
    set stop 0 ; set out {}
    while {[llength [set g [readerGroup $r]]]} {
        lappend out [lindex $g 1 0 1]
        if {[llength $out] >= 2000} { if {[emit $S($i,next) $out]} { set stop 1 ; break } ; set out {} }
    }
    if {!$stop && [llength $out]} { set stop [emit $S($i,next) $out] }
    readerFree $r
    return $stop
}

# ============================================================================
#  Sources
# ============================================================================
proc ::mkitsql::srcStream {node outer sink} {
    switch -- [dict get $node kind] {
        one { return [emit $sink [list {}]] }
        scan { return [scanStream [dict get $node path] $node $outer $sink] }
        lateralouter {
            set cur [lindex [lindex $outer [expr {[dict get $node level] - 1}]] [dict get $node pos]]
            return [scanStream $cur.[dict get $node sub] $node $outer $sink]
        }
        derived {
            set f [dict get $node filter]
            if {$f ne ""} { set sink [list ::mkitsql::stFilter $f $outer $sink] }
            return [streamPlan [dict get $node sub] $outer $sink]
        }
        info { return [emitAll $sink [filterRows [infoRows [dict get $node which]] [dict get $node filter] $outer]] }
        wref {
            variable wtable
            return [emitAll $sink [filterRows $wtable([dict get $node tid]) [dict get $node filter] $outer]]
        }
        join { return [joinStream $node $outer $sink] }
        latderived { fail "A LATERAL subquery must come after another FROM item (use JOIN LATERAL or a comma)" }
    }
    error "srcStream: [dict get $node kind]"
}

# ---- table scans ---------------------------------------------------------------
# Plain scan: read the view in chunks, filter, push.
proc ::mkitsql::scanPlain {path node outer filter sink} {
    variable chunk ; variable progressHook ; variable cancel ; variable M
    set props [dict get $node props] ; set subs [dict get $node subs] ; set dcols [dict get $node dcols]
    set n [::mkitsql::db::size $path]
    # Conditions Metakit can decide itself (see pushSpec): it returns the candidate rows, and only those are read.
    # The complete filter below still runs on them.  Any trouble with the shortcut falls back to the full scan.
    variable pushMin
    set push [expr {[dict exists $node push] ? [dict get $node push] : ""}]
    if {$push ne "" && $n >= $pushMin && ![catch {pushCandidates $path $push} cand]} {
        return [scanCandidates $path $node $outer $filter $sink $cand]
    }
    for {set first 0} {$first < $n} {incr first $chunk} {
        if {$cancel} { fail "Cancelled" }
        if {$progressHook ne ""} { {*}$progressHook }
        set data [::mkitsql::db::rows $path $props $first $chunk]
        if {[string first $M [::mkitsql::rt::flat $data]] >= 0} { set data [cleanRows $data] }
        if {[llength $dcols] && [string first -0 [::mkitsql::rt::flat $data]] >= 0} { set data [fixNegZero $data $dcols] }
        set i $first
        set out {}
        if {$filter eq ""} {
            foreach r $data {
                foreach sp $subs { lappend r [::mkitsql::db::subSize $path $i $sp] }
                lappend r $path!$i
                incr i
                lappend out [::mkitsql::rt::sk $r]
            }
        } else {
            foreach r $data {
                foreach sp $subs { lappend r [::mkitsql::db::subSize $path $i $sp] }
                lappend r $path!$i
                incr i
                if {[$filter $r $outer] eq "1"} { lappend out [::mkitsql::rt::sk $r] }
            }
        }
        if {[llength $out] && [emit $sink $out]} { return 1 }
    }
    return 0
}

# row indices (ascending) that can match the pushed conditions
proc ::mkitsql::pushCandidates {path push} {
    lassign $push conds in
    if {$in eq ""} { return [::mkitsql::db::select $path $conds] }
    set all {}
    foreach pc [lindex $in 1] { lappend all {*}[::mkitsql::db::select $path [concat $pc $conds]] }
    return [lsort -integer -unique $all]
}
# the same pipeline as scanPlain, over a list of candidate row indices
proc ::mkitsql::scanCandidates {path node outer filter sink cand} {
    variable chunk ; variable progressHook ; variable cancel ; variable M ; variable pushScans
    incr pushScans
    set props [dict get $node props] ; set subs [dict get $node subs] ; set dcols [dict get $node dcols]
    set total [llength $cand]
    for {set k 0} {$k < $total} {incr k $chunk} {
        if {$cancel} { fail "Cancelled" }
        if {$progressHook ne ""} { {*}$progressHook }
        set idxs [lrange $cand $k [expr {$k + $chunk - 1}]]
        set data [::mkitsql::db::rowsAt $path $props $idxs]
        if {[string first $M [::mkitsql::rt::flat $data]] >= 0} { set data [cleanRows $data] }
        if {[llength $dcols] && [string first -0 [::mkitsql::rt::flat $data]] >= 0} { set data [fixNegZero $data $dcols] }
        set out {}
        foreach r $data i $idxs {
            foreach sp $subs { lappend r [::mkitsql::db::subSize $path $i $sp] }
            lappend r $path!$i
            if {$filter eq "" || [$filter $r $outer] eq "1"} { lappend out [::mkitsql::rt::sk $r] }
        }
        if {[llength $out] && [emit $sink $out]} { return 1 }
    }
    return 0
}

# floating-point cells that are -0.0 (written by another program) read as 0.0
proc ::mkitsql::fixNegZero {rows dcols} {
    set out {}
    foreach r $rows {
        foreach p $dcols { if {[lindex $r $p] eq "-0.0"} { lset r $p 0.0 } }
        lappend out $r
    }
    return $out
}

# Sinks that build an in-memory copy of a scan; they give up (return 1, set over) past the budget.
proc ::mkitsql::cacheSink {st chunk} {
    variable S ; variable memBytes
    lappend S($st,rows) {*}$chunk
    incr S($st,bytes) [bytesOf $chunk]
    if {$S($st,bytes) > $memBytes} { set S($st,over) 1 ; return 1 }
    return 0
}
proc ::mkitsql::lookupSink {st ikey chunk} {
    variable S ; variable memBytes ; variable N
    foreach t $chunk {
        set k [$ikey $t {}]
        if {[lsearch -exact $k $N] < 0} { dict lappend S($st,idx) $k $t }
    }
    incr S($st,bytes) [bytesOf $chunk]
    if {$S($st,bytes) > $memBytes} { set S($st,over) 1 ; return 1 }
    return 0
}

proc ::mkitsql::scanStream {path node outer sink} {
    variable N ; variable scanCache ; variable scanRuns ; variable lookupIdx ; variable lookupOff ; variable S
    set lk [expr {[dict exists $node lookup] ? [dict get $node lookup] : ""}]
    if {$lk ne ""} {
        # inner.col = <outer expression>: a hash index, built once per statement
        set lid [dict get $lk lid]
        set okey [[dict get $lk okey] {} $outer]
        if {[lsearch -exact $okey $N] >= 0} { return 0 }
        if {![info exists lookupIdx($lid)] && ![info exists lookupOff($lid)]} {
            set st [newId] ; set S($st,idx) [dict create] ; set S($st,bytes) 0 ; set S($st,over) 0
            scanPlain $path $node {} [dict get $node sfilter] [list ::mkitsql::lookupSink $st [dict get $lk ikey]]
            if {$S($st,over)} { set lookupOff($lid) 1 } else { set lookupIdx($lid) $S($st,idx) }
            array unset S $st,*
        }
        if {[info exists lookupIdx($lid)]} {
            if {![dict exists $lookupIdx($lid) $okey]} { return 0 }
            return [emit $sink [filterRows [dict get $lookupIdx($lid) $okey] [dict get $node dfilter] $outer]]
        }
        # the table is too big to index within the budget: scan and compare keys row by row
        return [scanPlain $path $node $outer [dict get $node filter] [list ::mkitsql::stKeyEq [dict get $lk ikey] $okey $sink]]
    }
    if {[dict exists $node sid]} {
        # a scan that repeats (inside a correlated subquery) reads Metakit once and filters the copy
        set sid [dict get $node sid]
        if {![info exists scanRuns($sid)]} { set scanRuns($sid) 0 }
        if {[incr scanRuns($sid)] >= 3 && ![info exists lookupOff(c$sid)]} {
            if {![info exists scanCache($sid)]} {
                set st [newId] ; set S($st,rows) {} ; set S($st,bytes) 0 ; set S($st,over) 0
                scanPlain $path $node {} [dict get $node sfilter] [list ::mkitsql::cacheSink $st]
                if {$S($st,over)} { set lookupOff(c$sid) 1 } else { set scanCache($sid) $S($st,rows) }
                array unset S $st,*
            }
            if {[info exists scanCache($sid)]} {
                return [emitAll $sink [filterRows $scanCache($sid) [dict get $node dfilter] $outer]]
            }
        }
    }
    return [scanPlain $path $node $outer [dict get $node filter] $sink]
}

# ============================================================================
#  Joins
# ============================================================================
proc ::mkitsql::joinStream {node outer sink} {
    set post [dict get $node post]
    if {$post ne ""} { set sink [list ::mkitsql::stFilter $post $outer $sink] }
    if {[dict get $node lateral]} {
        return [srcStream [dict get $node left] $outer [list ::mkitsql::stLateral $node $outer $sink]]
    }
    if {[dict get $node lkey] ne ""} { return [keyedJoin $node $outer $sink] }
    return [nestedJoin $node $outer $sink]
}

# JOIN to a subview or LATERAL subquery: run the right side once per left row
proc ::mkitsql::stLateral {node outer sink chunk} {
    variable N
    set cap [set ::mkitsql::chunk]
    set type [dict get $node type] ; set wr [dict get $node wr] ; set resid [dict get $node resid]
    set rn [dict get $node right] ; set latDerived [dict get $node latderived]
    if {!$latDerived} { set curPos [dict get $node curPos] ; set sub [dict get $rn sub] }
    set nullR [::mkitsql::rep $wr $N]
    set out {}
    foreach l $chunk {
        if {$latDerived} {
            set R [filterRows [collectPlan [dict get $rn sub] [linsert $outer 0 $l]] [dict get $rn filter] $outer]
        } else {
            set c [newId] ; set ::mkitsql::S($c,rows) {}
            scanPlain [lindex $l $curPos].$sub $rn $outer [dict get $rn filter] [list ::mkitsql::collectSink $c]
            set R $::mkitsql::S($c,rows) ; array unset ::mkitsql::S $c,*
        }
        set hit 0
        foreach r $R {
            set t [::mkitsql::rt::sk [list {*}$l {*}$r]]
            if {$resid ne "" && [$resid $t $outer] ne "1"} continue
            lappend out $t ; set hit 1
        }
        if {!$hit && $type eq "left"} { lappend out [::mkitsql::rt::sk [list {*}$l {*}$nullR]] }
        if {[llength $out] >= $cap} { if {[emit $sink $out]} { return 1 } ; set out {} }
    }
    return [emit $sink $out]
}
proc ::mkitsql::collectSink {c chunk} { variable S ; lappend S($c,rows) {*}$chunk ; return 0 }
proc ::mkitsql::spoolSink {i chunk} { spoolAdd $i $chunk ; return 0 }

# equality join: hash join in memory, sort-merge join when the right side exceeds the budget
proc ::mkitsql::keyedJoin {node outer sink} {
    variable S ; variable N
    set bs [spoolNew]
    srcStream [dict get $node right] $outer [list ::mkitsql::spoolSink $bs]
    if {[spoolSpilled $bs]} {
        set r [mergeJoin $node $outer $sink $bs]
        spoolFree $bs
        return $r
    }
    set rows [spoolList $bs] ; spoolFree $bs
    set j [newId]
    set rkey [dict get $node rkey]
    set ht [dict create] ; set ri 0
    foreach r $rows {
        set k [$rkey $r $outer]
        if {[lsearch -exact $k $N] < 0} { dict lappend ht $k $ri }
        incr ri
    }
    set S($j,ht) $ht ; set S($j,rows) $rows ; set S($j,matched) [dict create]
    set stop [srcStream [dict get $node left] $outer [list ::mkitsql::stProbe $j $node $outer $sink]]
    if {!$stop && [dict get $node type] in {right full}} {
        set nullL [::mkitsql::rep [dict get $node wl] $N] ; set out {} ; set ri 0
        foreach r $rows {
            if {![dict exists $S($j,matched) $ri]} { lappend out [::mkitsql::rt::sk [list {*}$nullL {*}$r]] }
            incr ri
        }
        set stop [emitAll $sink $out]
    }
    array unset S $j,*
    return $stop
}
proc ::mkitsql::stProbe {j node outer sink chunk} {
    variable S ; variable N
    set type [dict get $node type] ; set resid [dict get $node resid] ; set lkey [dict get $node lkey]
    set nullR [::mkitsql::rep [dict get $node wr] $N]
    set rows $S($j,rows) ; set out {} ; set cap [set ::mkitsql::chunk]
    foreach l $chunk {
        set k [$lkey $l $outer]
        set hit 0
        if {[lsearch -exact $k $N] < 0 && [dict exists $S($j,ht) $k]} {
            foreach ri [dict get $S($j,ht) $k] {
                set t [::mkitsql::rt::sk [list {*}$l {*}[lindex $rows $ri]]]
                if {$resid ne "" && [$resid $t $outer] ne "1"} continue
                lappend out $t ; set hit 1
                dict set S($j,matched) $ri 1
            }
        }
        if {!$hit && $type in {left full}} { lappend out [::mkitsql::rt::sk [list {*}$l {*}$nullR]] }
        if {[llength $out] >= $cap} { if {[emit $sink $out]} { return 1 } ; set out {} }
    }
    return [emit $sink $out]
}

# keyed record for the external sorts: {keystring tuple}
proc ::mkitsql::stKeyRec {kproc outer sorter chunk} {
    set recs {}
    foreach t $chunk { lappend recs [list [$kproc $t $outer] $t] }
    sorterAdd $sorter $recs
    return 0
}
proc ::mkitsql::stKeyRecSpool {kproc outer sorter chunk} { return [stKeyRec $kproc $outer $sorter $chunk] }

proc ::mkitsql::mergeJoin {node outer sink bs} {
    variable N
    set type [dict get $node type] ; set resid [dict get $node resid]
    set nullR [::mkitsql::rep [dict get $node wr] $N] ; set nullL [::mkitsql::rep [dict get $node wl] $N]
    set spec {{key 0 asc "" text}}
    set rs [sorterNew $spec] ; set ls [sorterNew $spec]
    spoolEach $bs [list ::mkitsql::stKeyRec [dict get $node rkey] $outer $rs]
    srcStream [dict get $node left] $outer [list ::mkitsql::stKeyRec [dict get $node lkey] $outer $ls]
    set lr [sorterReader $ls] ; set rr [sorterReader $rs]
    set lg [readerGroup $lr] ; set rg [readerGroup $rr]
    set stop 0 ; set out {}
    set flush {
        if {[llength $out] >= 2000} { if {[emit $sink $out]} { set stop 1 } ; set out {} }
    }
    while {!$stop && ([llength $lg] || [llength $rg])} {
        set lk [expr {[llength $lg] ? [lindex $lg 0] : ""}] ; set rk [expr {[llength $rg] ? [lindex $rg 0] : ""}]
        set lnull [expr {[llength $lg] && [lsearch -exact $lk $N] >= 0}]
        set rnull [expr {[llength $rg] && [lsearch -exact $rk $N] >= 0}]
        if {[llength $lg] && [llength $rg] && !$lnull && !$rnull && $lk eq $rk} {
            set Ls {} ; foreach rec [lindex $lg 1] { lappend Ls [lindex $rec 1] }
            set Rs {} ; foreach rec [lindex $rg 1] { lappend Rs [lindex $rec 1] }
            set rhit [dict create] ; set ri0 0
            foreach l $Ls {
                set hit 0 ; set ri 0
                foreach r $Rs {
                    set t [::mkitsql::rt::sk [list {*}$l {*}$r]]
                    if {$resid eq "" || [$resid $t $outer] eq "1"} { lappend out $t ; set hit 1 ; dict set rhit $ri 1 }
                    incr ri
                }
                if {!$hit && $type in {left full}} { lappend out [::mkitsql::rt::sk [list {*}$l {*}$nullR]] }
                if {[llength $out] >= 2000} { if {[emit $sink $out]} { set stop 1 ; break } ; set out {} }
            }
            if {$type in {right full}} {
                set ri 0
                foreach r $Rs { if {![dict exists $rhit $ri]} { lappend out [::mkitsql::rt::sk [list {*}$nullL {*}$r]] } ; incr ri }
            }
            set lg [readerGroup $lr] ; set rg [readerGroup $rr]
        } else {
            # which side comes first?  NULL-keyed groups never match anything
            if {![llength $rg]} { set takeLeft 1
            } elseif {![llength $lg]} { set takeLeft 0
            } elseif {$lnull} { set takeLeft 1
            } elseif {$rnull} { set takeLeft 0
            } else { set takeLeft [expr {[string compare $lk $rk] < 0}] }
            if {$takeLeft} {
                if {$type in {left full}} { foreach rec [lindex $lg 1] { lappend out [::mkitsql::rt::sk [list {*}[lindex $rec 1] {*}$nullR]] } }
                set lg [readerGroup $lr]
            } else {
                if {$type in {right full}} { foreach rec [lindex $rg 1] { lappend out [::mkitsql::rt::sk [list {*}$nullL {*}[lindex $rec 1]]] } }
                set rg [readerGroup $rr]
            }
        }
        eval $flush
    }
    if {!$stop} { set stop [emit $sink $out] }
    readerFree $lr ; readerFree $rr ; sorterFree $ls ; sorterFree $rs
    return $stop
}

# joins without an equality condition: block nested loop over a (possibly spilled) right side
proc ::mkitsql::nestedJoin {node outer sink} {
    variable S ; variable N
    set bs [spoolNew]
    srcStream [dict get $node right] $outer [list ::mkitsql::spoolSink $bs]
    set j [newId]
    set S($j,bs) $bs ; set S($j,rmatched) [dict create]
    set stop [srcStream [dict get $node left] $outer [list ::mkitsql::stNested $j $node $outer $sink]]
    if {!$stop && [dict get $node type] in {right full}} {
        set S($j,rc) 0
        set stop [spoolEach $bs [list ::mkitsql::stRightRest $j $node $sink]]
    }
    spoolFree $bs ; array unset S $j,*
    return $stop
}
proc ::mkitsql::stNested {j node outer sink chunk} {
    variable S ; variable N
    set type [dict get $node type]
    set S($j,l) $chunk ; set S($j,lm) [dict create] ; set S($j,rc) 0
    set stop [spoolEach $S($j,bs) [list ::mkitsql::stNestedInner $j $node $outer $sink]]
    if {!$stop && $type in {left full}} {
        set nullR [::mkitsql::rep [dict get $node wr] $N] ; set out {} ; set i 0
        foreach l $chunk { if {![dict exists $S($j,lm) $i]} { lappend out [::mkitsql::rt::sk [list {*}$l {*}$nullR]] } ; incr i }
        set stop [emit $sink $out]
    }
    return $stop
}
proc ::mkitsql::stNestedInner {j node outer sink rchunk} {
    variable S
    variable cancel ; variable progressHook
    if {$cancel} { fail "Cancelled" }
    if {$progressHook ne ""} { {*}$progressHook }
    set resid [dict get $node resid] ; set out {} ; set cap [set ::mkitsql::chunk]
    set track [expr {[dict get $node type] in {right full}}]
    foreach r $rchunk {
        set i 0 ; set rc $S($j,rc)
        foreach l $S($j,l) {
            set t [::mkitsql::rt::sk [list {*}$l {*}$r]]
            if {$resid eq "" || [$resid $t $outer] eq "1"} {
                lappend out $t ; dict set S($j,lm) $i 1
                if {$track} { dict set S($j,rmatched) $rc 1 }
                if {[llength $out] >= $cap} { if {[emit $sink $out]} { return 1 } ; set out {} }
            }
            incr i
        }
        incr S($j,rc)
    }
    return [emit $sink $out]
}
proc ::mkitsql::stRightRest {j node sink rchunk} {
    variable S ; variable N
    set nullL [::mkitsql::rep [dict get $node wl] $N] ; set out {}
    foreach r $rchunk {
        if {![dict exists $S($j,rmatched) $S($j,rc)]} { lappend out [::mkitsql::rt::sk [list {*}$nullL {*}$r]] }
        incr S($j,rc)
    }
    return [emit $sink $out]
}

# ============================================================================
#  Aggregation (hash table; partial results spill and are merged by key)
# ============================================================================
# One aggregator per query.  Groups live in a hash table; when the table reaches its limit the
# partial state of every group is written to a sorter keyed by the group key and the table is
# emptied.  At the end the partials are merged key by key.  DISTINCT aggregates keep their value
# sets, so they merge too.
proc ::mkitsql::aggNew1 {a} {
    variable S ; variable memBytes
    set i [newId]
    namespace eval ::mkitsql::agg {}
    namespace eval ::mkitsql::agg::A$i {}
    set S($i,a) $a ; set S($i,groups) [dict create] ; set S($i,order) {} ; set S($i,n) 0
    set S($i,limit) [expr {max(2, $memBytes / 700)}]
    set S($i,fast) [expr {$::mkitsql::fastAgg && [aggFastOk [dict get $a specs]]}]
    set S($i,spill) ""
    return $i
}
# Can the specs be folded a whole chunk at a time?  COUNT, SUM, AVG, MIN, MAX over numbers (not DISTINCT, not intervals, not text MIN/MAX).
proc ::mkitsql::aggFastOk {specs} {
    foreach spec $specs {
        lassign $spec kind distinct ai sepIdx sortKind
        if {$kind eq "cstar"} continue
        if {$kind in {count sum avg} && $distinct} { return 0 }
        if {$kind eq "count"} continue
        if {$kind in {sum avg min max} && $sortKind eq "n"} continue
        return 0
    }
    return 1
}
# The same folding as aggAdd1 + aggStepRow + aggFold, but per chunk: the rows are grouped by key first, and each group's values for a
# spec are summed / counted / compared with one C-speed command instead of one proc call per row and spec.  (Sums are added chunk by
# chunk, as partial sums already are when an aggregation spills.)
namespace eval ::mkitsql { variable fastAgg 1 }          ;# 0 = fold row by row (the tests compare the two)
proc ::mkitsql::aggAddFast {i outer chunk} {
    variable S ; variable N
    upvar #0 ::mkitsql::agg::A${i}::ST ST
    set a $S($i,a)
    set ng [dict get $a ng] ; set gkey [dict get $a gkey] ; set aargs [dict get $a aargs] ; set specs [dict get $a specs]
    set limit $S($i,limit)
    if {$ng} {
        set byKey [dict create]
        foreach r $chunk { dict lappend byKey [$gkey $r $outer] [$aargs $r $outer] }
    } else {
        set av {}
        foreach r $chunk { lappend av [$aargs $r $outer] }
        set byKey [dict create "" $av]
    }
    dict for {key avs} $byKey {
        if {![dict exists $S($i,groups) $key]} {
            if {$S($i,n) >= $limit} { aggDump $i }
            set gi $S($i,n) ; incr S($i,n)
            dict set S($i,groups) $key $gi ; lappend S($i,order) $key
            aggInitGroup $i $gi
        } else { set gi [dict get $S($i,groups) $key] }
        set k 0
        foreach spec $specs {
            lassign $spec kind distinct ai
            if {$kind eq "cstar"} { incr ST($gi,$k) [llength $avs] ; incr k ; continue }
            set col {}
            foreach av $avs { lappend col [lindex $av $ai] }
            if {[lsearch -exact $col $N] >= 0} { set col [lsearch -all -inline -not -exact $col $N] }
            set n [llength $col]
            if {$n} {
                switch -- $kind {
                    count { incr ST($gi,$k) $n }
                    sum   { aggFold $i $gi $k sum n [::tcl::mathop::+ {*}$col] }
                    avg   { set ST($gi,$k) [expr {$ST($gi,$k) + [::tcl::mathop::+ {*}$col]}] ; incr ST(c,$gi,$k) $n }
                    min   { aggFold $i $gi $k min n [::tcl::mathfunc::min {*}$col] }
                    max   { aggFold $i $gi $k max n [::tcl::mathfunc::max {*}$col] }
                }
            }
            incr k
        }
    }
    return 0
}
proc ::mkitsql::aggAdd1 {i outer chunk} {
    variable S ; variable N ; variable cancel
    if {$S($i,fast)} { return [aggAddFast $i $outer $chunk] }
    set a $S($i,a)
    set ng [dict get $a ng] ; set gkey [dict get $a gkey] ; set aargs [dict get $a aargs] ; set specs [dict get $a specs]
    set limit $S($i,limit)
    foreach r $chunk {
        if {$ng} { set key [$gkey $r $outer] } else { set key "" }
        if {![dict exists $S($i,groups) $key]} {
            if {$S($i,n) >= $limit} { aggDump $i }
            set gi $S($i,n) ; incr S($i,n)
            dict set S($i,groups) $key $gi ; lappend S($i,order) $key
            aggInitGroup $i $gi
        } else { set gi [dict get $S($i,groups) $key] }
        aggStepRow $i $gi $specs [$aargs $r $outer]
    }
    return 0
}
proc ::mkitsql::aggInitGroup {i gi} {
    variable S ; variable N
    upvar #0 ::mkitsql::agg::A${i}::ST ST
    set k 0
    foreach spec [dict get $S($i,a) specs] {
        lassign $spec kind distinct ai sepIdx sortKind
        switch -- $kind {
            cstar - count { set ST($gi,$k) 0 }
            avg { set ST($gi,$k) [expr {$sortKind eq "i" ? $N : 0}] ; set ST(c,$gi,$k) 0 }
            string_agg { set ST($gi,$k) {} }
            default { set ST($gi,$k) $N }
        }
        if {$distinct && $kind in {count sum avg string_agg}} { set ST(dv,$gi,$k) {} }
        incr k
    }
}
# fold one row's argument values into group gi
proc ::mkitsql::aggStepRow {i gi specs av} {
    variable N
    upvar #0 ::mkitsql::agg::A${i}::ST ST
    set k 0
    foreach spec $specs {
        lassign $spec kind distinct ai sepIdx sortKind
        if {$kind eq "cstar"} { incr ST($gi,$k) ; incr k ; continue }
        set v [lindex $av $ai]
        if {$v eq $N} { incr k ; continue }
        if {$distinct && $kind in {count sum avg string_agg}} {
            if {![info exists ST(s,$gi,$k,$v)]} {
                set ST(s,$gi,$k,$v) 1 ; lappend ST(dv,$gi,$k) $v
                if {$kind eq "string_agg" && $sepIdx >= 0} { set ST(sep,$gi,$k) [lindex $av $sepIdx] }
                aggFold $i $gi $k $kind $sortKind $v
            }
        } else {
            aggFold $i $gi $k $kind $sortKind $v
            if {$kind eq "string_agg" && $sepIdx >= 0 && ![info exists ST(sep,$gi,$k)]} { set ST(sep,$gi,$k) [lindex $av $sepIdx] }
        }
        incr k
    }
}
proc ::mkitsql::aggFold {i gi k kind sortKind v} {
    variable N
    upvar #0 ::mkitsql::agg::A${i}::ST ST
    # sortKind "i": the values are intervals (added with iv_add, compared by their length of time)
    switch -- $kind {
        count { incr ST($gi,$k) }
        sum   {
            if {$ST($gi,$k) eq $N} { set ST($gi,$k) $v } elseif {$sortKind eq "i"} { set ST($gi,$k) [::mkitsql::rt::iv_add $ST($gi,$k) $v] } else { set ST($gi,$k) [expr {$ST($gi,$k) + $v}] }
        }
        avg   {
            if {$sortKind eq "i"} {
                if {$ST($gi,$k) eq $N} { set ST($gi,$k) $v } else { set ST($gi,$k) [::mkitsql::rt::iv_add $ST($gi,$k) $v] }
            } else { set ST($gi,$k) [expr {$ST($gi,$k) + $v}] }
            incr ST(c,$gi,$k)
        }
        min {
            if {$ST($gi,$k) eq $N || ($sortKind eq "n" ? $v < $ST($gi,$k) : ($sortKind eq "i" ? [ivTotal $v] < [ivTotal $ST($gi,$k)] : [string compare $v $ST($gi,$k)] < 0))} { set ST($gi,$k) $v }
        }
        max {
            if {$ST($gi,$k) eq $N || ($sortKind eq "n" ? $v > $ST($gi,$k) : ($sortKind eq "i" ? [ivTotal $v] > [ivTotal $ST($gi,$k)] : [string compare $v $ST($gi,$k)] > 0))} { set ST($gi,$k) $v }
        }
        string_agg { lappend ST($gi,$k) $v }
    }
}
# the finished value of spec k of group gi
proc ::mkitsql::aggResult {i gi k kind} {
    variable N ; variable S
    upvar #0 ::mkitsql::agg::A${i}::ST ST
    switch -- $kind {
        avg {
            if {$ST(c,$gi,$k) == 0} { return $N }
            if {[lindex [lindex [dict get $S($i,a) specs] $k] 4] eq "i"} { return [::mkitsql::rt::iv_div $ST($gi,$k) $ST(c,$gi,$k)] }
            return [expr {double($ST($gi,$k)) / $ST(c,$gi,$k)}]
        }
        string_agg {
            if {![llength $ST($gi,$k)]} { return $N }
            set sep [expr {[info exists ST(sep,$gi,$k)] ? $ST(sep,$gi,$k) : ","}]
            return [join $ST($gi,$k) $sep]
        }
    }
    return $ST($gi,$k)
}
# partial state of group gi as a record {key partials}
proc ::mkitsql::aggPartial {i gi key} {
    variable S
    upvar #0 ::mkitsql::agg::A${i}::ST ST
    set parts {} ; set k 0
    foreach spec [dict get $S($i,a) specs] {
        lassign $spec kind distinct
        set sep [expr {[info exists ST(sep,$gi,$k)] ? [::mkitsql::rt::sk [list $ST(sep,$gi,$k)]] : {}}]
        if {$distinct && $kind in {count sum avg string_agg}} {
            lappend parts [::mkitsql::rt::sk [list [::mkitsql::rt::sk $ST(dv,$gi,$k)] $sep]]
        } else {
            switch -- $kind {
                avg { lappend parts [list $ST($gi,$k) $ST(c,$gi,$k)] }
                string_agg { lappend parts [::mkitsql::rt::sk [list [::mkitsql::rt::sk $ST($gi,$k)] $sep]] }
                default { lappend parts $ST($gi,$k) }
            }
        }
        incr k
    }
    return [list $key [::mkitsql::rt::sk $parts]]
}
proc ::mkitsql::aggDump {i} {
    variable S
    if {$S($i,spill) eq ""} { set S($i,spill) [sorterNew {{key 0 asc "" text}}] }
    set recs {} ; set gi 0
    foreach key $S($i,order) { lappend recs [aggPartial $i $gi $key] ; incr gi }
    sorterAdd $S($i,spill) $recs
    # empty the table
    array unset ::mkitsql::agg::A${i}::ST
    set S($i,groups) [dict create] ; set S($i,order) {} ; set S($i,n) 0
}
# fold a partial record into group gi
proc ::mkitsql::aggMerge {i gi parts} {
    variable S ; variable N
    upvar #0 ::mkitsql::agg::A${i}::ST ST
    set k 0
    foreach spec [dict get $S($i,a) specs] p $parts {
        lassign $spec kind distinct ai sepIdx sortKind
        if {$distinct && $kind in {count sum avg string_agg}} {
            lassign $p vals sep
            if {[llength $sep]} { set ST(sep,$gi,$k) [lindex $sep 0] }
            foreach v $vals {
                if {![info exists ST(s,$gi,$k,$v)]} {
                    set ST(s,$gi,$k,$v) 1 ; lappend ST(dv,$gi,$k) $v
                    aggFold $i $gi $k $kind $sortKind $v
                }
            }
        } else {
            switch -- $kind {
                cstar - count { incr ST($gi,$k) $p }
                sum { if {$p ne $N} { aggFold $i $gi $k sum $sortKind $p } }
                avg {
                    set p0 [lindex $p 0]
                    if {$sortKind eq "i"} {
                        if {$p0 ne $N} { if {$ST($gi,$k) eq $N} { set ST($gi,$k) $p0 } else { set ST($gi,$k) [::mkitsql::rt::iv_add $ST($gi,$k) $p0] } }
                    } else { set ST($gi,$k) [expr {$ST($gi,$k) + $p0}] }
                    incr ST(c,$gi,$k) [lindex $p 1]
                }
                min - max { if {$p ne $N} { aggFold $i $gi $k $kind $sortKind $p } }
                string_agg {
                    lappend ST($gi,$k) {*}[lindex $p 0]
                    if {[llength [lindex $p 1]]} { set ST(sep,$gi,$k) [lindex $p 1 0] }
                }
            }
        }
        incr k
    }
}
proc ::mkitsql::aggFlush1 {i outer next} {
    variable S ; variable N
    set a $S($i,a) ; set specs [dict get $a specs] ; set ng [dict get $a ng]
    set out {} ; set stop 0
    if {$S($i,spill) eq ""} {
        # everything fit: one pass over the table, in first-seen order
        if {$ng == 0 && $S($i,n) == 0} {
            set S($i,groups) [dict create "" 0] ; set S($i,order) [list ""] ; set S($i,n) 1
            aggInitGroup $i 0
        }
        set gi 0
        foreach key $S($i,order) {
            set t $key ; set k 0
            foreach spec $specs { lappend t [aggResult $i $gi $k [lindex $spec 0]] ; incr k }
            lappend out [::mkitsql::rt::sk $t]
            incr gi
            if {[llength $out] >= 2000} { if {[emit $next $out]} { return 1 } ; set out {} }
        }
        return [emit $next $out]
    }
    # spilled: dump what is left, then merge the partials of each key
    aggDump $i
    set r [sorterReader $S($i,spill)]
    while {[llength [set g [readerGroup $r]]]} {
        array unset ::mkitsql::agg::A${i}::ST
        aggInitGroup $i 0
        foreach rec [lindex $g 1] { aggMerge $i 0 [lindex $rec 1] }
        set t [lindex $g 0] ; set k 0
        foreach spec $specs { lappend t [aggResult $i 0 $k [lindex $spec 0]] ; incr k }
        lappend out [::mkitsql::rt::sk $t]
        if {[llength $out] >= 2000} { if {[emit $next $out]} { set stop 1 ; break } ; set out {} }
    }
    readerFree $r
    if {!$stop} { set stop [emit $next $out] }
    return $stop
}

# ---- DISTINCT aggregates ---------------------------------------------------------------------------
# COUNT(DISTINCT x), SUM(DISTINCT x), AVG(DISTINCT x), STRING_AGG(DISTINCT x ..) need "have I seen this
# (group, value) before?".  Keeping those sets in the hash table would make a single group with a million
# distinct values cost a million entries, so such a query is split into BRANCHES:
#
#   main branch      every non-DISTINCT aggregate, as above
#   one branch per   rows {group key, value} -> a spill-capable DISTINCT stage (distNew: hash set that
#   DISTINCT aggregate  overflows into a sorter) -> an ordinary aggregator that sees every pair once
#
# Each branch finishes into a COMBINER that lines the per-group results up again: a dict while it is
# small (so output keeps first-seen order), a sorter keyed by group key once it outgrows memBytes.
proc ::mkitsql::dbKey  {r outer} { lindex $r 0 }
proc ::mkitsql::dbArgs {r outer} { lrange $r 1 end }

proc ::mkitsql::aggNew {a} {
    variable S
    set specs [dict get $a specs]
    set dIdx {} ; set k 0
    foreach spec $specs {
        lassign $spec kind distinct
        if {$distinct && $kind in {count sum avg string_agg}} { lappend dIdx $k }
        incr k
    }
    if {![llength $dIdx]} { return [aggNew1 $a] }
    set i [newId]
    set S($i,multi) 1 ; set S($i,a) $a ; set ng [dict get $a ng]
    set mainSpecs {} ; set mainIdx {} ; set k 0
    foreach spec $specs {
        if {$k ni $dIdx} { lappend mainSpecs $spec ; lappend mainIdx $k }
        incr k
    }
    set am $a ; dict set am specs $mainSpecs
    set S($i,main) [aggNew1 $am] ; set S($i,mainIdx) $mainIdx
    set subs [list $S($i,main)] ; set S($i,dist) {}
    foreach k $dIdx {
        lassign [lindex $specs $k] kind distinct ai sepIdx sortKind
        set sepSlot -1
        if {$sepIdx >= 0} { set sepSlot 1 }
        set sub [dict create ng $ng gkey ::mkitsql::dbKey aargs ::mkitsql::dbArgs specs [list [list $kind 0 0 $sepSlot $sortKind]]]
        set ag [aggNew1 $sub]
        set di [distNew -1 [list ::mkitsql::aggAdd $ag {}]]
        lappend S($i,dist) [list $k $ai $sepIdx $di $ag]
        lappend subs $ag $di
    }
    set S($i,subs) $subs
    set S($i,cbMem) [dict create] ; set S($i,cbBytes) 0 ; set S($i,cbSort) ""
    return $i
}
proc ::mkitsql::aggAdd {i outer chunk} {
    variable S ; variable N
    if {![info exists S($i,multi)]} { return [aggAdd1 $i $outer $chunk] }
    set a $S($i,a) ; set ng [dict get $a ng] ; set gkey [dict get $a gkey] ; set aargs [dict get $a aargs]
    aggAdd1 $S($i,main) $outer $chunk
    set n 0
    foreach d $S($i,dist) { set L($n) {} ; incr n }
    foreach r $chunk {
        set av [$aargs $r $outer]
        if {$ng} { set key [$gkey $r $outer] } else { set key "" }
        set n 0
        foreach d $S($i,dist) {
            lassign $d k ai sepIdx
            set v [lindex $av $ai]
            if {$v ne $N} {
                if {$sepIdx >= 0} { set rec [list $key $v [lindex $av $sepIdx]] } else { set rec [list $key $v] }
                lappend L($n) $rec
            }
            incr n
        }
    }
    set n 0
    foreach d $S($i,dist) {
        if {[llength $L($n)]} { distAdd [lindex $d 3] $L($n) }
        incr n
    }
    return 0
}
# a branch delivers its finished rows {group values..., results...}; slots = the aggregate positions they fill
proc ::mkitsql::aggComb {i slots chunk} {
    variable S ; variable memBytes
    set ng [dict get $S($i,a) ng]
    foreach t $chunk {
        set key [::mkitsql::rt::sk [lrange $t 0 [expr {$ng - 1}]]]
        set sd {}
        foreach sl $slots v [lrange $t $ng end] { lappend sd $sl $v }
        if {$S($i,cbSort) eq ""} {
            if {[dict exists $S($i,cbMem) $key]} {
                dict set S($i,cbMem) $key [concat [dict get $S($i,cbMem) $key] $sd]
            } else {
                dict set S($i,cbMem) $key $sd
            }
            incr S($i,cbBytes) [expr {4 * [string length [::mkitsql::rt::flat $t]] + 200}]
            if {$S($i,cbBytes) > $memBytes} {
                set sr [sorterNew {{key 0 asc "" text}}]
                set recs {}
                dict for {k v} $S($i,cbMem) { lappend recs [list $k $v] }
                sorterAdd $sr $recs
                set S($i,cbSort) $sr ; set S($i,cbMem) [dict create]
            }
        } else {
            sorterAdd $S($i,cbSort) [list [list $key $sd]]
        }
    }
    return 0
}
proc ::mkitsql::aggFlush {i outer next} {
    variable S ; variable N
    if {![info exists S($i,multi)]} { return [aggFlush1 $i $outer $next] }
    set a $S($i,a) ; set specs [dict get $a specs] ; set ng [dict get $a ng]
    aggFlush1 $S($i,main) $outer [list ::mkitsql::aggComb $i $S($i,mainIdx)]
    foreach d $S($i,dist) {
        lassign $d k ai sepIdx di ag
        distFlush $di
        aggFlush1 $ag {} [list ::mkitsql::aggComb $i [list $k]]
    }
    # what a group that a branch never saw gets: the aggregate of no rows
    set defaults {}
    foreach spec $specs {
        if {[lindex $spec 0] in {cstar count}} { lappend defaults 0 } else { lappend defaults $N }
    }
    set out {} ; set stop 0
    if {$S($i,cbSort) eq ""} {
        dict for {key sd} $S($i,cbMem) {
            lappend out [aggAssemble $key $sd $defaults]
            if {[llength $out] >= 2000} { if {[emit $next $out]} { return 1 } ; set out {} }
        }
        return [emit $next $out]
    }
    set r [sorterReader $S($i,cbSort)]
    while {[llength [set g [readerGroup $r]]]} {
        set sd {}
        foreach rec [lindex $g 1] { set sd [concat $sd [lindex $rec 1]] }
        lappend out [aggAssemble [lindex $g 0] $sd $defaults]
        if {[llength $out] >= 2000} { if {[emit $next $out]} { set stop 1 ; break } ; set out {} }
    }
    readerFree $r
    if {!$stop} { set stop [emit $next $out] }
    return $stop
}
proc ::mkitsql::aggAssemble {key sd defaults} {
    set t $key
    set k 0
    foreach d $defaults {
        if {[dict exists $sd $k]} { lappend t [dict get $sd $k] } else { lappend t $d }
        incr k
    }
    return [::mkitsql::rt::sk $t]
}

# ============================================================================
#  Window functions: in memory when the input fits, otherwise one sorted pass per window
# ============================================================================
proc ::mkitsql::winStageNew {specs} {
    variable S
    set i [newId]
    set S($i,specs) $specs ; set S($i,spool) [spoolNew]
    return $i
}
proc ::mkitsql::winAdd {i chunk} { variable S ; spoolAdd $S($i,spool) $chunk ; return 0 }
proc ::mkitsql::winFlush {i outer next} {
    variable S
    set sp $S($i,spool)
    if {![spoolSpilled $sp]} {
        return [emitAll $next [runWindows $S($i,specs) [spoolList $sp] $outer]]
    }
    # large input: one pass per window call.  Rows are sorted by that window's PARTITION BY key, so each
    # partition arrives together and only one partition is in memory at a time.
    set cur $sp
    foreach w $S($i,specs) {
        set out [spoolNew]
        set sr [sorterNew {{key 0 asc "" text}}]
        spoolEach $cur [list ::mkitsql::stWinKey $w $outer $sr]
        if {$cur ne $sp} { spoolFree $cur }
        set rd [sorterReader $sr]
        while {[llength [set g [readerGroup $rd]]]} {
            set rows {}
            foreach rec [lindex $g 1] { lappend rows [lindex $rec 1] }
            spoolAdd $out [runWindows [list $w] $rows $outer]
        }
        readerFree $rd ; sorterFree $sr
        set cur $out
    }
    set S($i,spool) $cur
    set stop [spoolEach $cur $next]
    if {$cur ne $sp} { spoolFree $sp }
    return $stop
}
proc ::mkitsql::stWinKey {w outer sorter chunk} {
    set np [dict get $w np] ; set pr [dict get $w proc] ; set recs {}
    foreach r $chunk { lappend recs [list [::mkitsql::rt::sk [lrange [$pr $r $outer] 0 [expr {$np - 1}]]] $r] }
    sorterAdd $sorter $recs
    return 0
}

# ============================================================================
#  Set operations, recursion, ORDER BY over a set operation
# ============================================================================
proc ::mkitsql::setopStream {p outer sink} {
    set op [dict get $p op] ; set all [dict get $p all]
    set left [dict get $p left] ; set right [dict get $p right]
    if {$op eq "union"} {
        if {$all} {
            if {[streamPlan $left $outer $sink]} { return 1 }
            return [streamPlan $right $outer $sink]
        }
        set fin [newId] ; set ::mkitsql::S($fin,stopped) 0
        set di [distNew -1 [list ::mkitsql::stFinal $fin $sink]]
        set stop [streamPlan $left $outer [list ::mkitsql::distAdd $di]]
        if {!$stop} { set stop [streamPlan $right $outer [list ::mkitsql::distAdd $di]] }
        if {!$stop} { distFlush $di }
        set res $::mkitsql::S($fin,stopped)
        stageFree $di ; array unset ::mkitsql::S $fin,*
        return $res
    }
    # INTERSECT / EXCEPT: sort both sides and compare the groups of equal rows
    set spec {{key 0 asc "" text}}
    set ls [sorterNew $spec] ; set rs [sorterNew $spec]
    streamPlan $left $outer [list ::mkitsql::stRowRec $ls]
    streamPlan $right $outer [list ::mkitsql::stRowRec $rs]
    set lr [sorterReader $ls] ; set rr [sorterReader $rs]
    set lg [readerGroup $lr] ; set rg [readerGroup $rr]
    set out {} ; set stop 0
    while {!$stop && [llength $lg]} {
        set lk [lindex $lg 0]
        while {[llength $rg] && [string compare [lindex $rg 0] $lk] < 0} { set rg [readerGroup $rr] }
        set cl [llength [lindex $lg 1]]
        set cr [expr {[llength $rg] && [lindex $rg 0] eq $lk ? [llength [lindex $rg 1]] : 0}]
        if {$op eq "intersect"} { set n [expr {$all ? min($cl, $cr) : ($cl > 0 && $cr > 0 ? 1 : 0)}]
        } else { set n [expr {$all ? max($cl - $cr, 0) : ($cr == 0 ? 1 : 0)}] }
        for {set c 0} {$c < $n} {incr c} { lappend out $lk }
        if {[llength $out] >= 2000} { if {[emit $sink $out]} { set stop 1 } ; set out {} }
        set lg [readerGroup $lr]
    }
    if {!$stop} { set stop [emit $sink $out] }
    readerFree $lr ; readerFree $rr ; sorterFree $ls ; sorterFree $rs
    return $stop
}
proc ::mkitsql::stRowRec {sorter chunk} {
    set recs {}
    foreach r $chunk { lappend recs [list $r] }
    sorterAdd $sorter $recs
    return 0
}

proc ::mkitsql::recursiveStream {p outer sink} {
    variable wtable ; variable maxRecursion ; variable cancel ; variable progressHook ; variable maxWorkRows
    set tid [dict get $p tid] ; set all [dict get $p all]
    set seen [dict create] ; set total 0
    set rows [collectPlan [dict get $p anchor] $outer]
    set iter 0
    while {[llength $rows]} {
        if {!$all} {
            set fresh {}
            foreach r $rows { set sr [::mkitsql::rt::sk $r] ; if {![dict exists $seen $sr]} { dict set seen $sr 1 ; lappend fresh $r } }
            set rows $fresh
            if {[dict size $seen] > $maxWorkRows} {
                catch {unset wtable($tid)}
                fail "Recursive query produced more than $maxWorkRows distinct rows.  Add a stop condition (WHERE ...)"
            }
        }
        if {[emitAll $sink $rows]} { catch {unset wtable($tid)} ; return 1 }
        if {![llength $rows]} break
        if {[incr iter] > $maxRecursion} {
            catch {unset wtable($tid)}
            fail "Recursive query stopped after $maxRecursion rounds.  Add a stop condition (WHERE ...) or raise ::mkitsql::maxRecursion"
        }
        if {$cancel} { fail "Cancelled" }
        if {$progressHook ne ""} { {*}$progressHook }
        set wtable($tid) $rows
        # answers of subqueries that read the working table (or anything else) belong to ONE round: forget them
        variable subCache ; variable memo ; variable memoCount ; variable memoUsed
        array unset subCache ; array unset memo ; set memoCount 0 ; set memoUsed 0
        set rows [collectPlan [dict get $p step] $outer]
    }
    catch {unset wtable($tid)}
    return 0
}

# a set operation / VALUES query with its own ORDER BY, LIMIT, OFFSET
proc ::mkitsql::queryStream {p outer sink} {
    variable S
    set order [dict get $p order]
    set limit [dict get $p limit] ; set offset [dict get $p offset]
    if {$offset eq ""} { set offset 0 }
    set fin [newId] ; set S($fin,stopped) 0
    set head [list ::mkitsql::stFinal $fin $sink]
    set ids2 [list $fin] ; set flushes {}
    if {$limit ne "" || $offset > 0} {
        set li [newId] ; lappend ids2 $li
        set S($li,skip) $offset ; set S($li,left) [expr {$limit eq "" ? -1 : $limit}]
        set head [list ::mkitsql::stLimit $li $head]
    }
    if {[llength $order]} {
        set spec {} ; set idxs {}
        foreach o $order { lappend spec [list out [lindex $o 0] [lindex $o 1] [lindex $o 2] [lindex $o 3]] ; lappend idxs [lindex $o 0] }
        set nk [llength $order]
        set head [list ::mkitsql::stStrip $nk 0 $head]
        set top [expr {$limit eq "" ? 0 : $limit + $offset}]
        set si [sortStageNew $spec $top] ; lappend ids2 $si
        set flushes [list [list ::mkitsql::sortFlush $si $head]]
        set head [list ::mkitsql::stKeyOut $idxs [list ::mkitsql::sortAdd $si]]
    }
    set stopped [streamPlan [dict get $p body] $outer $head]
    if {!$stopped} { foreach f $flushes { if {[{*}$f]} break } }
    set res $S($fin,stopped)
    foreach i $ids2 { stageFree $i }
    return $res
}
proc ::mkitsql::stKeyOut {idxs next chunk} {
    set recs {}
    foreach out $chunk {
        set rec {}
        foreach i $idxs { lappend rec [lindex $out $i] }
        lappend rec $out
        lappend recs $rec
    }
    return [emit $next $recs]
}

# ============================================================================
#  Sorting (in memory; spilled sorts call this on each run)
# ============================================================================
proc ::mkitsql::wideCmp {a b} { expr {$a < $b ? -1 : ($a > $b ? 1 : 0)} }
# recs: each {key1 .. keyN payload ...}.  spec: list of {kind idx dir nulls type}.
# Multi-key sort = successive stable sorts from the last key to the first.
proc ::mkitsql::sortRecs {recs spec} {
    variable N
    for {set k [expr {[llength $spec] - 1}]} {$k >= 0} {incr k -1} {
        lassign [lindex $spec $k] kind idx dir nulls type
        set nullRecs {} ; set valRecs {}
        foreach r $recs {
            if {[lindex $r $k] eq $N} { lappend nullRecs $r } else { lappend valRecs $r }
        }
        if {$type eq "interval"} {
            # sort by length of time (then months), not by the internal text form: a string key that orders correctly as text
            set tmp {}
            foreach r $valRecs { lset r $k [ivSortKey [lindex $r $k]] ; lappend tmp $r }
            set valRecs $tmp
            set type text
        }
        set mode [expr {$type in {int} ? "-integer" : ($type in {real bool} ? "-real" : "-ascii")}]
        set dirflag [expr {$dir eq "desc" ? "-decreasing" : "-increasing"}]
        if {[catch {lsort $mode $dirflag -index $k $valRecs} sorted]} {
            # (whole numbers beyond a machine word: Tcl 8.5 on 64-bit Windows has a 32-bit long, so -integer refuses them; doubles would
            # make 9223372036854775806 and ...807 equal, so compare them as the whole numbers they are)
            if {$mode eq "-integer"} {
                set sorted [lsort -command ::mkitsql::wideCmp $dirflag -index $k $valRecs]
            } else {
                set sorted [lsort -real $dirflag -index $k $valRecs]
            }
        }
        # NULLs sort as the smallest value unless NULLS FIRST / LAST says otherwise
        if {$nulls eq ""} { set nullsFirst [expr {$dir ne "desc"}] } else { set nullsFirst [expr {$nulls eq "first"}] }
        if {$nullsFirst} { set recs [concat $nullRecs $sorted] } else { set recs [concat $sorted $nullRecs] }
    }
    return $recs
}
