# bind.tcl -- catalog access and the binder for mkit-sql.
#
# The binder turns the parser's AST into a *bound* tree:
#   - table names are resolved against the open Metakit files (via ::store)
#   - every column reference becomes {ref LEVEL SRC NAME TYPE}
#       LEVEL 0 = the query's own FROM clause, 1 = the enclosing query, ...
#   - `*` is expanded, parameters are substituted, ORDER BY / GROUP BY
#     ordinals and aliases are resolved
#   - every column that is actually used is recorded in ::mkitsql::needed so the
#     scan only reads those columns from Metakit.
#
# All data access goes through the ::store API of MK Studio (store.tcl).

namespace eval ::mkitsql {
    variable srcSeq 0
    variable needed            ;# needed(srcId,lowername) = 1
    variable bindCount 0 ; variable maxBinds 4000
    variable derivedBq         ;# derivedBq(srcId) = the bound query of a derived table or CTE
    array set derivedBq {}
    variable scopes {}         ;# stack of scopes (innermost first); scope = list of source dicts
    variable ctes {}           ;# stack of {name cols query} visible CTEs (innermost first)
    variable refLog {}         ;# stack of lists of {level srcId} (outer references)
    variable params {}         ;# dict: 1-based index or name -> value
    variable curWindows {}     ;# named windows (WINDOW clause) of the SELECT being bound
    variable recSeq 0
    variable recUsed
    array set recUsed {}
    variable defaultDb ""
    variable fromSoFar {}      ;# sources bound so far in the FROM clause being bound
    variable curCol "%cur"     ;# hidden column holding a row's cursor path
    array set needed {}
}

# ============================================================================
#  Catalog
# ============================================================================
proc ::mkitsql::dbNames {} { return [::mkitsql::db::tags] }

proc ::mkitsql::findTag {name} {
    foreach t [::mkitsql::db::tags] { if {[string equal -nocase $t $name]} { return $t } }
    return ""
}

# Case-insensitive view lookup in one database.  Exact match wins.
proc ::mkitsql::findView {tag name} {
    set views [::mkitsql::db::views $tag]
    if {[lsearch -exact $views $name] >= 0} { return $name }
    set hits {}
    foreach v $views { if {[string equal -nocase $v $name]} { lappend hits $v } }
    if {[llength $hits] == 1} { return [lindex $hits 0] }
    if {[llength $hits] > 1} {
        fail "Table name '$name' is ambiguous in '$tag': [join $hits {, }] differ only by case.  Use \"[lindex $hits 0]\" in quotes."
    }
    return ""
}

# Resolve a (possibly db-qualified) table name to {tag view}.
proc ::mkitsql::resolveTable {parts} {
    variable defaultDb
    set tags [::mkitsql::db::tags]
    if {![llength $tags]} { fail "No database is open." }
    if {[llength $parts] == 2} {
        set tag [findTag [lindex $parts 0]]
        if {$tag eq ""} {
            fail "Unknown database '[lindex $parts 0]'. Open databases: [join $tags {, }]"
        }
        set v [findView $tag [lindex $parts 1]]
        if {$v eq ""} {
            fail "Database '$tag' has no table '[lindex $parts 1]'.  Tables: [join [::mkitsql::db::views $tag] {, }]"
        }
        return [list $tag $v]
    }
    set name [lindex $parts 0]
    if {$defaultDb ne "" && [lsearch -exact $tags $defaultDb] >= 0} {
        set v [findView $defaultDb $name]
        if {$v ne ""} { return [list $defaultDb $v] }
    }
    set hits {}
    foreach t $tags {
        set v [findView $t $name]
        if {$v ne ""} { lappend hits [list $t $v] }
    }
    if {[llength $hits] == 1} { return [lindex $hits 0] }
    if {[llength $hits] > 1} {
        set tl {}
        foreach h $hits { lappend tl [lindex $h 0] }
        fail "Table '$name' exists in several databases ([join $tl {, }]).  Qualify it, e.g. [lindex $tl 0].$name"
    }
    set avail {}
    foreach t $tags { foreach v [::mkitsql::db::views $t] { lappend avail $v } }
    fail "Unknown table '$name'.  Tables: [expr {[llength $avail] ? [join $avail {, }] : {(none)}}]"
}

# Walk a [n].sub path below a table.  Returns {path layout label}.
proc ::mkitsql::walkSubs {path layout label subs} {
    foreach s $subs {
        lassign $s idx sub
        set n [::mkitsql::db::size $path]
        if {$idx >= $n} { fail "Row $idx does not exist in '$label' (it has $n rows)" }
        set found ""
        foreach c $layout {
            if {[string equal -nocase [lindex $c 0] $sub] && [lindex $c 1] eq "V"} { set found $c }
        }
        if {$found eq ""} { fail "'$label' has no subview named '$sub'" }
        append path !$idx.[lindex $found 0]
        set layout [lindex $found 2]
        append label \[$idx\].[lindex $found 0]
    }
    return [list $path $layout $label]
}

# Turn a Metakit layout into the binder's column list.
#   col = {name type letter isSub subLayout}
proc ::mkitsql::layoutCols {layout} {
    set cols {}
    foreach c $layout {
        lassign $c n l sub
        if {$l eq "V"} {
            lappend cols [list $n int V 1 $sub]
        } else {
            lappend cols [list $n [typeOfLetter $l] $l 0 {}]
        }
    }
    return $cols
}

# ============================================================================
#  Sources
# ============================================================================
proc ::mkitsql::newSource {kind alias cols args} {
    variable srcSeq
    set d [dict create id [incr srcSeq] kind $kind alias [string tolower $alias] \
        display $alias cols $cols hidden {}]
    foreach {k v} $args { dict set d $k $v }
    return $d
}

# A derived table / CTE source.  Its bound query is kept in `derivedBq` (by source id), NOT inside the source dict: the source
# dict is copied into the select's `srcs` and into its FROM tree, so a bound query stored in it would be stored twice per
# nesting level and the size of every bound tree would double with each level of subquery.
proc ::mkitsql::newDerived {alias cols bq args} {
    variable derivedBq
    set src [newSource derived $alias $cols {*}$args]
    set derivedBq([dict get $src id]) $bq
    return $src
}

# a derived table cannot have two columns of the same name (a reference to either one could not be told apart)
proc ::mkitsql::checkDistinctNames {names what} {
    set seen {}
    foreach n $names {
        set l [string tolower $n]
        if {[lsearch -exact $seen $l] >= 0} { fail "$what has two columns named '$n'; give one of them a different name (AS ...)" }
        lappend seen $l
    }
}

# Two columns of a derived table may have the same name (SELECT * FROM (SELECT a.id, b.id FROM a, b) x); only a REFERENCE to that name is
# an error.  derivedCols renames every column of such a name to  name<U+FDD1>k  (k = 1, 2, ...); visibleName shows it as it was.
proc ::mkitsql::visibleName {n} { set k [string first "\uFDD1" $n] ; expr {$k > 0 ? [string range $n 0 [expr {$k - 1}]] : $n} }
proc ::mkitsql::srcColIndex {src name} {
    set i 0 ; set dup 0
    foreach c [dict get $src cols] {
        set cn [lindex $c 0]
        if {[string equal -nocase $cn $name]} { return $i }
        if {[string first "\uFDD1" $cn] > 0 && [string equal -nocase [visibleName $cn] $name]} { set dup 1 }
        incr i
    }
    if {$dup} { fail "Column reference '$name' is ambiguous: '[dict get $src display]' has more than one column with that name.  Give them different names (AS ...) in the subquery" }
    return -1
}

# Pull in every column of a source (used by SELECT *).
proc ::mkitsql::needAll {src} {
    variable needed
    foreach c [dict get $src cols] { set needed([dict get $src id],[string tolower [lindex $c 0]]) 1 }
}

# ============================================================================
#  Binding the FROM clause
# ============================================================================
# Returns the bound tree:   {src SOURCE}  |  {join TYPE L R ONBOUND USINGPAIRS}
proc ::mkitsql::bindFrom {node} {
    variable fromSoFar
    switch -- [lindex $node 0] {
        table - derived {
            set src [bindSource $node]
            foreach s $fromSoFar {
                if {[dict get $s alias] eq [dict get $src alias]} {
                    fail "Table name '[dict get $src display]' is used more than once in FROM.  Give one an alias."
                }
            }
            lappend fromSoFar $src
            return [list src $src]
        }
        join {
            lassign $node _ type l r on using
            set bl [bindFrom $l]
            set br [bindFrom $r]
            set bon {} ; set pairs {}
            if {$using eq "NATURAL"} {
                # all column names common to the left and right sides
                set lcols [treeCols $bl] ; set rcols [treeCols $br]
                set using {}
                # a column name that a derived table has twice cannot be joined on
                foreach lc $lcols { foreach rc $rcols {
                    set ln [lindex $lc 1] ; set rn [lindex $rc 1]
                    if {[string equal -nocase [visibleName $ln] [visibleName $rn]] && ([string first "\uFDD1" $ln] > 0 || [string first "\uFDD1" $rn] > 0)} {
                        fail "NATURAL JOIN on '[visibleName $ln]' is ambiguous: a derived table has two columns of that name"
                    }
                } }
                foreach lc $lcols {
                    foreach rc $rcols {
                        if {[string equal -nocase [lindex $lc 1] [lindex $rc 1]]} { lappend using [lindex $lc 1] ; break }
                    }
                }
                if {![llength $using] && $type ne "cross"} {
                    set type cross
                }
            }
            if {[llength $using]} {
                foreach u $using {
                    set lref [findInTree $bl $u "left"]
                    set rref [findInTree $br $u "right"]
                    lappend pairs [list $lref $rref]
                    set eq [list bin = [lindex $lref 0] [lindex $rref 0]]
                    if {$bon eq ""} { set bon $eq } else { set bon [list bin and $bon $eq] }
                    # hide the right-hand copy from SELECT *, and remember that the left one stands for both: with a RIGHT or FULL join the merged
                    # column is COALESCE(left, right), because a row that exists only on the right has no left value
                    markHidden [lindex $rref 1] $u
                    markMerged [lindex $lref 1] $u [lindex $rref 1] $type
                }
            } elseif {$on ne ""} {
                variable scopes
                set savedScopes $scopes
                set scopes [linsert $scopes 0 $fromSoFar]
                set rc [catch {bx $on} bon opts]
                set scopes $savedScopes
                if {$rc} { return -options $opts $bon }
                if {[hasAgg $bon]} { fail "Aggregate functions are not allowed in JOIN conditions" }
                if {[hasWin $bon]} { fail "Window functions are not allowed in JOIN conditions" }
            }
            return [list join $type $bl $br $bon]
        }
    }
    error "bindFrom: [lindex $node 0]"
}

# hide column `u` of source (by id) from `*`
proc ::mkitsql::markHidden {srcId u} {
    variable fromSoFar
    set i 0
    foreach s $fromSoFar {
        if {[dict get $s id] == $srcId} {
            dict lappend s hidden [string tolower $u]
            set fromSoFar [lreplace $fromSoFar $i $i $s]
            return
        }
        incr i
    }
}

# the column `u` of source `srcId` is the merged column of a USING / NATURAL join with source `rid` (join type `type`)
proc ::mkitsql::markMerged {srcId u rid type} {
    variable fromSoFar
    set i 0
    foreach s $fromSoFar {
        if {[dict get $s id] == $srcId} {
            dict lappend s merged [list [string tolower $u] $rid $type]
            set fromSoFar [lreplace $fromSoFar $i $i $s]
            return
        }
        incr i
    }
}
# {rightSrcId} when column `lname` of source `s` is merged with a right-hand column under a RIGHT / FULL join, else ""
proc ::mkitsql::mergedWith {s lname} {
    if {![dict exists $s merged]} { return "" }
    foreach m [dict get $s merged] {
        lassign $m n rid type
        if {$n eq $lname && $type in {right full}} { return $rid }
    }
    return ""
}
# the expression a merged column stands for: COALESCE(left, right)
proc ::mkitsql::mergedExpr {srcs s col rid} {
    set rs [findSrc $srcs $rid]
    set rci [srcColIndex $rs [lindex $col 0]]
    set rcol [lindex [dict get $rs cols] $rci]
    noteRef 0 [dict get $s id] [lindex $col 0]
    noteRef 0 $rid [lindex $rcol 0]
    return [list func COALESCE 0 [list [list ref 0 [dict get $s id] [lindex $col 0] [lindex $col 1]] [list ref 0 $rid [lindex $rcol 0] [lindex $rcol 1]]]]
}

# {srcId name} pairs for all columns under a bound FROM tree
proc ::mkitsql::treeCols {t} {
    if {[lindex $t 0] eq "src"} {
        set s [lindex $t 1] ; set out {}
        foreach c [dict get $s cols] { lappend out [list [dict get $s id] [lindex $c 0]] }
        return $out
    }
    return [concat [treeCols [lindex $t 2]] [treeCols [lindex $t 3]]]
}
# Find column `name` in a subtree -> {boundRef srcId}
proc ::mkitsql::findInTree {t name side} {
    variable fromSoFar
    foreach p [treeCols $t] {
        lassign $p sid cname
        if {[string equal -nocase $cname $name]} {
            foreach s $fromSoFar {
                if {[dict get $s id] == $sid} {
                    set ci [srcColIndex $s $cname]
                    set col [lindex [dict get $s cols] $ci]
                    noteRef 0 $sid $cname
                    return [list [list ref 0 $sid $cname [lindex $col 1]] $sid]
                }
            }
        }
    }
    fail "USING column '$name' not found on the $side side of the join"
}

proc ::mkitsql::bindSource {node} {
    variable fromSoFar ; variable ctes ; variable curCol ; variable scopes
    switch -- [lindex $node 0] {
        derived {
            lassign $node _ q alias cols outerok
            # LATERAL with nothing to its left is just an ordinary subquery
            if {$outerok eq "lateral" && ![llength $fromSoFar]} { set outerok "" }
            # a subquery in FROM cannot see its siblings (no LATERAL); only the internal
            # row-IN rewrite is allowed to see the enclosing query
            if {$outerok eq "outerok"} {
                set bq [bindQuery $q]
            } elseif {$outerok eq "lateral"} {
                # LATERAL: the subquery sees the FROM items to its left (they become scope level 1)
                set bq [withScopes [linsert $scopes 0 $fromSoFar] {bindQuery $q}]
            } else {
                set bq [withScopes [list] {bindQuery $q}]
            }
            set outNames [dict get $bq outNames] ; set outTypes [dict get $bq outTypes]
            if {[llength $cols]} {
                if {[llength $cols] != [llength $outNames]} {
                    fail "Subquery '$alias' returns [llength $outNames] columns but [llength $cols] names were given"
                }
                set outNames $cols
            }
            if {[llength $cols]} { checkDistinctNames $outNames "Subquery '$alias'" }
            return [newDerived $alias [derivedCols $outNames $outTypes $bq] $bq outerok [expr {$outerok eq "outerok"}] lateralq [expr {$outerok eq "lateral"}]]
        }
        table {
            lassign $node _ parts subs alias
            set p0 [lindex $parts 0]
            # ---- CTE?
            if {[llength $parts] == 1 && ![llength $subs]} {
                set ci -1
                foreach c $ctes {
                    incr ci
                    lassign $c cname ccols cq crec
                    if {[string equal -nocase $cname $p0]} {
                        if {[lindex $c 4] eq "wref"} {
                            # the recursive reference inside a recursive CTE: reads the working table
                            lassign [lrange $c 5 7] tid rnames rtypes
                            recordRecUse $tid
                            return [newSource wref [pickName $alias $cname] [derivedCols $rnames $rtypes ""] tid $tid]
                        }
                        if {$crec} {
                            set bq [bindRecursiveCte $ci $cname $ccols $cq]
                        } else {
                            # a CTE sees only the ones defined before it (never itself)
                            set savedCtes $ctes
                            set ctes [lrange $ctes [expr {$ci + 1}] end]
                            set rc [catch {withScopes [list] {bindQuery $cq}} bq opts]
                            set ctes $savedCtes
                            if {$rc} { return -options $opts $bq }
                        }
                        set outNames [dict get $bq outNames]
                        if {[llength $ccols]} {
                            if {[llength $ccols] != [llength $outNames]} {
                                fail "CTE '$cname' returns [llength $outNames] columns but [llength $ccols] names were given"
                            }
                            set outNames $ccols
                        }
                        if {[llength $ccols]} { checkDistinctNames $outNames "CTE '$cname'" }
                        return [newDerived [pickName $alias $cname] [derivedCols $outNames [dict get $bq outTypes] $bq] $bq]
                    }
                }
            }
            # ---- alias.subview  (lateral unnest of a subview column)
            if {[llength $parts] == 2 && ![llength $subs]} {
                foreach s $fromSoFar {
                    if {[dict get $s alias] eq [string tolower $p0]} {
                        set sub [lindex $parts 1]
                        set ci [srcColIndex $s $sub]
                        if {$ci < 0 || ![lindex [dict get $s cols] $ci 3]} {
                            fail "'[dict get $s display]' has no subview column '$sub'"
                        }
                        set col [lindex [dict get $s cols] $ci]
                        noteRef 0 [dict get $s id] $curCol
                        return [newSource lateral [pickName $alias [lindex $col 0]] \
                            [layoutCols [lindex $col 4]] parent [dict get $s id] sub [lindex $col 0] \
                            layout [lindex $col 4]]
                    }
                }
                # a subview of a table in an ENCLOSING query:  WHERE (SELECT COUNT(*) FROM d.files) > 5
                set k 0
                foreach scope $scopes {
                    foreach s $scope {
                        if {[dict get $s alias] ne [string tolower $p0] || [dict get $s kind] ni {table lateral}} continue
                        set sub [lindex $parts 1]
                        set ci [srcColIndex $s $sub]
                        if {$ci < 0 || ![lindex [dict get $s cols] $ci 3]} continue
                        set col [lindex [dict get $s cols] $ci]
                        noteRef [expr {$k + 1}] [dict get $s id] $curCol
                        return [newSource lateral [pickName $alias [lindex $col 0]] \
                            [layoutCols [lindex $col 4]] parent [dict get $s id] sub [lindex $col 0] \
                            layout [lindex $col 4] plevel [expr {$k + 1}]]
                    }
                    incr k
                }
                if {[string equal -nocase $p0 information_schema]} {
                    return [infoSource [lindex $parts 1] $alias]
                }
            }
            # ---- a real table
            lassign [resolveTable $parts] tag view
            set path $tag.$view
            set layout [::mkitsql::db::layout $path]
            set label $view
            if {[llength $subs]} {
                lassign [walkSubs $path $layout $label $subs] path layout label
            }
            set name [pickName $alias [lindex [split $label .] 0]]
            if {$alias eq "" && [llength $subs]} { set name [lindex $subs end 1] }
            return [newSource table $name [layoutCols $layout] path $path tag $tag layout $layout label $label]
        }
    }
    error "bindSource"
}

# NOTE: never route data or names through  expr {c ? $a : $b}  -- expr rewrites numeric-looking
# strings ("007" -> 7, "1e3" -> 1000.0).  These helpers use plain `if`.
proc ::mkitsql::pickName {alias default} { if {$alias ne ""} { return $alias } ; return $default }
proc ::mkitsql::drillName {col} { if {[lindex $col 3]} { return [lindex $col 0] } ; return 0 }

# ---- recursive CTEs --------------------------------------------------------
proc ::mkitsql::recordRecUse {tid} { variable recUsed ; set recUsed($tid) 1 }

# Bind  WITH RECURSIVE name AS (anchor UNION [ALL] recursive-part).  `ci` is the CTE's
# position in the visible-CTE list: the anchor must not see the CTE itself, the
# recursive part sees it as the working table.
proc ::mkitsql::bindRecursiveCte {ci cname ccols cq} {
    variable ctes ; variable recUsed ; variable recSeq
    set body [dict get $cq body]
    set plain [expr {[dict get $body type] ne "setop" || [dict get $body op] ne "union"}]
    if {$plain} { return [withScopes [list] {bindQuery $cq}] }
    if {[llength [dict get $cq order]] || [dict get $cq limit] ne "" || [dict get $cq offset] ne ""} {
        fail "ORDER BY / LIMIT inside the definition of recursive query '$cname' is not supported"
    }
    set saved $ctes
    set visible [lrange $ctes [expr {$ci + 1}] end]
    set ctes $visible
    set rc [catch {withScopes [list] {bindBody [dict get $body left]}} anchor opts]
    set ctes $saved
    if {$rc} { return -options $opts $anchor }
    set names [dict get $anchor outNames] ; set types [dict get $anchor outTypes]
    if {[llength $ccols]} {
        if {[llength $ccols] != [llength $names]} {
            fail "Recursive query '$cname' returns [llength $names] columns but [llength $ccols] names were given"
        }
        set names $ccols
    }
    set tid [incr recSeq]
    set ctes [linsert $visible 0 [list $cname {} {} 0 wref $tid $names $types]]
    set rc [catch {withScopes [list] {bindBody [dict get $body right]}} step opts]
    set ctes $saved
    if {$rc} { return -options $opts $step }
    if {![info exists recUsed($tid)]} {
        # no self-reference: an ordinary UNION
        return [withScopes [list] {bindQuery $cq}]
    }
    if {[llength [dict get $step outNames]] != [llength $names]} {
        fail "Each branch of recursive query '$cname' must have the same number of columns"
    }
    set rt {}
    foreach a $types b [dict get $step outTypes] { lappend rt [unify $a $b] }
    return [dict create kind recursive anchor $anchor step $step all [dict get $body all] tid $tid \
        outNames $names outTypes $rt outLetters [::mkitsql::rep [llength $names] ""] outDrill [::mkitsql::rep [llength $names] 0]]
}

proc ::mkitsql::derivedCols {names types bq} {
    set count [dict create] ; set total [dict create]
    foreach n $names { dict incr total [string tolower $n] }
    set cols {} ; set i 0
    foreach n $names {
        set l [string tolower $n]
        if {[dict get $total $l] > 1} { dict incr count $l ; set n "$n\uFDD1[dict get $count $l]" }
        lappend cols [list $n [lindex $types $i] "" 0 {}]
        incr i
    }
    return $cols
}

# information_schema.tables / columns
proc ::mkitsql::infoSource {which alias} {
    set which [string tolower $which]
    switch -- $which {
        tables {
            set cols {{table_catalog text "" 0 {}} {table_name text "" 0 {}} {table_type text "" 0 {}} {row_count int "" 0 {}}}
        }
        columns {
            set cols {{table_catalog text "" 0 {}} {table_name text "" 0 {}} {column_name text "" 0 {}}
                      {ordinal_position int "" 0 {}} {data_type text "" 0 {}} {metakit_type text "" 0 {}}}
        }
        default { fail "Unknown information_schema table '$which'.  Available: tables, columns" }
    }
    return [newSource info [pickName $alias $which] $cols which $which]
}

# ============================================================================
#  Scope handling
# ============================================================================
proc ::mkitsql::withScopes {scopeList script} {
    variable scopes
    set saved $scopes
    set scopes $scopeList
    set rc [catch {uplevel 1 $script} res opts]
    set scopes $saved
    return -options $opts $res
}

proc ::mkitsql::noteRef {level srcId name} {
    variable needed ; variable refLog
    set needed($srcId,[string tolower $name]) 1
    if {[llength $refLog]} {
        lset refLog end [concat [lindex $refLog end] [list [list $level $srcId [string tolower $name]]]]
    }
}

# ============================================================================
#  Names -> bound references
# ============================================================================
proc ::mkitsql::availableCols {srcs} {
    set l {}
    foreach s $srcs {
        foreach c [dict get $s cols] { lappend l [visibleName [lindex $c 0]] }
    }
    return [join $l {, }]
}

proc ::mkitsql::bindCol {q name} {
    variable scopes ; variable curCol
    set level 0
    set q [string tolower [lindex [split $q .] end]]
    set lname [string tolower $name]
    foreach scope $scopes {
        if {$q ne ""} {
            foreach s $scope {
                if {[dict get $s alias] ne $q} continue
                if {$lname eq "_rowid"} {
                    if {[dict get $s kind] ni {table lateral}} { fail "_rowid is only available on tables" }
                    noteRef $level [dict get $s id] $curCol
                    return [list func ROWID_ 0 [list [list ref $level [dict get $s id] $curCol text]]]
                }
                set ci [srcColIndex $s $name]
                if {$ci < 0} {
                    fail "Unknown column '$name' in '[dict get $s display]'.  Available: [availableCols [list $s]]"
                }
                set col [lindex [dict get $s cols] $ci]
                noteRef $level [dict get $s id] [lindex $col 0]
                return [list ref $level [dict get $s id] [lindex $col 0] [lindex $col 1]]
            }
        } else {
            if {$lname eq "_rowid"} {
                set cand {}
                foreach s $scope { if {[dict get $s kind] in {table lateral}} { lappend cand $s } }
                if {[llength $cand] == 1} {
                    set s [lindex $cand 0]
                    noteRef $level [dict get $s id] $curCol
                    return [list func ROWID_ 0 [list [list ref $level [dict get $s id] $curCol text]]]
                } elseif {[llength $cand] > 1} {
                    fail "Column reference '_rowid' is ambiguous.  Qualify it, e.g. [dict get [lindex $cand 0] display]._rowid"
                }
            }
            set hits {}
            foreach s $scope {
                set ci [srcColIndex $s $name]
                if {$ci >= 0} { lappend hits [list $s [lindex [dict get $s cols] $ci]] }
            }
            # the right-hand copy of a USING / NATURAL column is hidden: the name means the merged column
            if {[llength $hits] > 1} {
                set vis {}
                foreach h $hits { if {[lsearch -exact [dict get [lindex $h 0] hidden] $lname] < 0} { lappend vis $h } }
                if {[llength $vis] == 1} {
                    lassign [lindex $vis 0] s col
                    set rid [mergedWith $s $lname]
                    if {$rid ne "" && $level == 0} { return [mergedExpr $scope $s $col $rid] }
                    set hits $vis
                }
            }
            if {[llength $hits] > 1} {
                set owners {}
                foreach h $hits { lappend owners [dict get [lindex $h 0] display] }
                fail "Column reference '$name' is ambiguous.  It exists in: [join $owners {, }].  Qualify it, e.g. [lindex $owners 0].$name"
            }
            if {[llength $hits] == 1} {
                lassign [lindex $hits 0] s col
                noteRef $level [dict get $s id] [lindex $col 0]
                return [list ref $level [dict get $s id] [lindex $col 0] [lindex $col 1]]
            }
        }
        incr level
    }
    if {$q ne ""} {
        fail "Unknown table or alias '$q' in reference '$q.$name'"
    }
    set all {}
    foreach scope $scopes { foreach s $scope { lappend all $s } }
    fail "Unknown column '$name'.  Available: [availableCols $all]"
}

# ============================================================================
#  Binding expressions
# ============================================================================
proc ::mkitsql::inferType {v} {
    variable N
    if {$v eq $N} { return null }
    # canonical numbers only: "08" or " 5" stay text (they compare numerically against numbers anyway)
    if {[regexp {^-?(0|[1-9]\d*)$} $v] && [string is wideinteger -strict $v]} { return int }
    if {[regexp {^-?(0|[1-9]\d*)?\.?\d*([eE][-+]?\d+)?$} $v] && [string is double -strict $v]} { return real }
    return text
}

proc ::mkitsql::bx {node} {
    variable params ; variable N
    switch -- [lindex $node 0] {
        lit { return $node }
        param {
            set k [lindex $node 1]
            if {![dict exists $params $k]} {
                fail "No value was supplied for parameter [expr {[string is integer $k] ? "#$k" : ":$k"}]"
            }
            set v [dict get $params $k]
            return [list lit [inferType $v] $v]
        }
        col { return [bindCol [lindex $node 1] [lindex $node 2]] }
        star { fail "'*' is only allowed in the select list or COUNT(*)" }
        collate { fail "COLLATE is only supported on the operands of comparisons, IN, BETWEEN and LIKE, in ORDER BY, in GROUP BY and in the select list" }
        un { return [list un [lindex $node 1] [bx [lindex $node 2]]] }
        bin { return [list bin [lindex $node 1] [bx [lindex $node 2]] [bx [lindex $node 3]]] }
        isnull { return [list isnull [bx [lindex $node 1]] [lindex $node 2]] }
        istf { return [list istf [bx [lindex $node 1]] [lindex $node 2] [lindex $node 3]] }
        isdist { return [list isdist [bx [lindex $node 1]] [bx [lindex $node 2]] [lindex $node 3]] }
        between {
            lassign $node _ e lo hi neg
            return [list between [bx $e] [bx $lo] [bx $hi] $neg]
        }
        like {
            lassign $node _ e pat esc neg ci
            return [list like [bx $e] [bx $pat] [expr {$esc eq "" ? "" : [bx $esc]}] $neg $ci]
        }
        in {
            lassign $node _ e items neg
            set bi {}
            foreach it $items { lappend bi [bx $it] }
            return [list in [bx $e] $bi $neg]
        }
        insub {
            lassign $node _ e q neg
            set be [bx $e]
            lassign [bindSubquery $q] bq refs
            if {[llength [dict get $bq outNames]] != 1} { fail "A subquery used with IN must return exactly one column" }
            return [list insub $be $bq $neg $refs]
        }
        row { fail "A row value (a, b) can only be used in a comparison or with IN" }
        quant {
            lassign $node _ op kind e q
            set be [bx $e]
            lassign [bindSubquery $q] bq refs
            if {[llength [dict get $bq outNames]] != 1} { fail "A subquery used with [string toupper $kind] must return exactly one column" }
            return [list quant $op $kind $be $bq $refs [lindex [dict get $bq outTypes] 0]]
        }
        exists {
            lassign [bindSubquery [lindex $node 1]] bq refs
            return [list exists $bq $refs]
        }
        sub {
            lassign [bindSubquery [lindex $node 1]] bq refs
            if {[llength [dict get $bq outNames]] != 1} { fail "A scalar subquery must return exactly one column" }
            return [list sub $bq $refs [lindex [dict get $bq outTypes] 0]]
        }
        case {
            lassign $node _ operand whens else
            set bw {}
            foreach w $whens { lappend bw [list [bx [lindex $w 0]] [bx [lindex $w 1]]] }
            return [list case [expr {$operand eq "" ? "" : [bx $operand]}] $bw [bx $else]]
        }
        cast { return [list cast [bx [lindex $node 1]] [lindex $node 2]] }
        win { return [bindWindow $node] }
        func {
            lassign $node _ name distinct args
            variable aggs
            if {[lsearch -exact $aggs $name] >= 0 && [lindex $args 0 0] ne "star"} {
                set max [expr {$name in {STRING_AGG GROUP_CONCAT} ? 2 : 1}]
                if {[llength $args] < 1 || [llength $args] > $max} {
                    fail "Function ${name}() takes [expr {$max == 2 ? {1 or 2} : 1}] argument[expr {$max == 2 ? {s} : {}}], not [llength $args]"
                }
            }
            set ba {}
            foreach a $args {
                if {[lindex $a 0] eq "star"} { lappend ba $a } else { lappend ba [bx $a] }
            }
            return [list func $name $distinct $ba]
        }
    }
    error "bx: unknown node [lindex $node 0]"
}

# Bind a nested query.  Returns {boundQuery outerRefs}; outerRefs are the
# references the subquery makes to *enclosing* scopes, with LEVEL relative to
# the subquery's own scope (>= 1).
proc ::mkitsql::bindSubquery {q} {
    variable refLog ; variable scopes ; variable fromSoFar
    lappend refLog {}
    set savedFrom $fromSoFar
    # `scopes` already starts with the enclosing SELECT's own sources
    set rc [catch {bindQuery $q} bq opts]
    set log [lindex $refLog end]
    set refLog [lrange $refLog 0 end-1]
    set fromSoFar $savedFrom
    if {$rc} { return -options $opts $bq }
    set outer {}
    foreach r $log {
        lassign $r lvl sid
        if {$lvl >= 1} { lappend outer $r }
    }
    # references that reach beyond our parent are outer references of the parent too
    foreach r $outer {
        lassign $r lvl sid rname
        if {$lvl >= 2 && [llength $refLog]} {
            lset refLog end [concat [lindex $refLog end] [list [list [expr {$lvl - 1}] $sid $rname]]]
        }
    }
    return [list $bq $outer]
}

# ---- window functions -------------------------------------------------------
# argument count limits  {min max}
proc ::mkitsql::winArity {name} {
    switch -- $name {
        ROW_NUMBER - RANK - DENSE_RANK - PERCENT_RANK - CUME_DIST { return {0 0} }
        NTILE - FIRST_VALUE - LAST_VALUE - COUNT - SUM - AVG - MIN - MAX { return {1 1} }
        LAG - LEAD { return {1 3} }
        NTH_VALUE { return {2 2} }
        STRING_AGG - GROUP_CONCAT { return {1 2} }
    }
    return {0 0}
}

proc ::mkitsql::winType {node} {
    lassign $node _ name distinct args spec
    switch -- $name {
        ROW_NUMBER - RANK - DENSE_RANK - NTILE - COUNT { return int }
        PERCENT_RANK - CUME_DIST { return real }
        AVG { return [expr {[dryType [lindex $args 0]] eq "interval" ? "interval" : "real"}] }
        SUM {
            set t [dryType [lindex $args 0]]
            return [expr {$t in {int bool} ? "int" : ($t eq "interval" ? "interval" : "real")}]
        }
        STRING_AGG - GROUP_CONCAT { return text }
    }
    return [dryType [lindex $args 0]]
}

# Merge a named window into a spec (parser form) and return the effective spec.
proc ::mkitsql::resolveWindowSpec {spec {depth 0}} {
    variable curWindows
    set base [dict get $spec base]
    if {$base eq ""} { return $spec }
    if {$depth > 10} { fail "Window definitions refer to each other in a loop" }
    set key [string tolower $base]
    if {![info exists curWindows] || ![dict exists $curWindows $key]} {
        fail "Unknown window '$base'.  Define it with WINDOW $base AS (...)"
    }
    set def [resolveWindowSpec [dict get $curWindows $key] [expr {$depth + 1}]]
    if {[llength [dict get $spec partition]]} { fail "Window '$base' already defines PARTITION BY" }
    if {[llength [dict get $spec order]] && [llength [dict get $def order]]} { fail "Window '$base' already defines ORDER BY" }
    if {[llength [dict get $spec frame]] && [llength [dict get $def frame]]} { fail "Window '$base' already defines a frame" }
    set out $def
    if {[llength [dict get $spec order]]} { dict set out order [dict get $spec order] }
    if {[llength [dict get $spec frame]]} { dict set out frame [dict get $spec frame] }
    set ex [specGet $spec exclude ""]
    if {$ex ne ""} {
        if {[specGet $def exclude ""] ne ""} { fail "Window '$base' already defines EXCLUDE" }
        dict set out exclude $ex
    }
    dict set out ignorenulls [specGet $spec ignorenulls 0]            ;# belongs to the call, not to the window
    dict set out base ""
    return $out
}

proc ::mkitsql::specGet {spec key default} { expr {[dict exists $spec $key] ? [dict get $spec $key] : $default} }

proc ::mkitsql::bindFrameBound {b mode} {
    set kind [lindex $b 0]
    if {$kind in {preceding following}} {
        set e [bx [lindex $b 1]]
        if {[lindex $e 0] ne "lit" || [lindex $e 1] ni {int real} || [lindex $e 2] < 0} {
            fail "A window frame offset must be a non-negative number"
        }
        if {$mode in {rows groups} && ![string is integer -strict [lindex $e 2]]} {
            fail "A ROWS / GROUPS frame offset must be a whole number"
        }
        return [list $kind [lindex $e 2]]
    }
    return [list $kind {}]
}

proc ::mkitsql::bindWindow {node} {
    variable aggs ; variable winFuncs
    lassign $node _ name distinct args spec
    if {$distinct && $name ni {COUNT SUM AVG MIN MAX STRING_AGG GROUP_CONCAT}} { fail "DISTINCT is only allowed in aggregate window functions" }
    lassign [winArity $name] mn mx
    set na [llength $args]
    if {[lindex $args 0 0] eq "star"} {
        if {$name ne "COUNT"} { fail "'*' is only allowed in COUNT(*)" }
    } elseif {$na < $mn || $na > $mx} {
        fail "Window function ${name}() takes [expr {$mn == $mx ? $mn : "$mn to $mx"}] argument[expr {$mx == 1 ? {} : {s}}], not $na"
    }
    set ba {}
    foreach a $args { lappend ba [expr {[lindex $a 0] eq "star" ? $a : [bx $a]}] }
    foreach a $ba { if {[lindex $a 0] ne "star" && [hasWin $a]} { fail "Window function calls cannot be nested" } }
    set spec [resolveWindowSpec $spec]
    set part {}
    foreach e [dict get $spec partition] {
        set b [bx $e]
        if {[hasWin $b]} { fail "Window function calls cannot be nested" }
        lappend part $b
    }
    set ord {}
    foreach o [dict get $spec order] {
        lassign $o e dir nulls
        set b [bx $e]
        if {[hasWin $b]} { fail "Window function calls cannot be nested" }
        lappend ord [list $b $dir $nulls]
    }
    set frame [dict get $spec frame]
    if {[llength $frame]} {
        lassign $frame mode b1 b2
        set b1 [bindFrameBound $b1 $mode] ; set b2 [bindFrameBound $b2 $mode]
        # start cannot come after end
        set rank {unbounded_preceding 0 preceding 1 current 2 following 3 unbounded_following 4}
        if {[dict get $rank [lindex $b1 0]] > [dict get $rank [lindex $b2 0]] ||
            [lindex $b1 0] eq "unbounded_following" || [lindex $b2 0] eq "unbounded_preceding"} {
            fail "Invalid window frame: the start must not come after the end"
        }
        if {$mode eq "range" && ([lindex $b1 0] in {preceding following} || [lindex $b2 0] in {preceding following})} {
            if {[llength $ord] != 1} { fail "A RANGE frame with an offset needs exactly one ORDER BY column" }
        }
        set frame [list $mode $b1 $b2]
    }
    set exclude [specGet $spec exclude ""]
    if {$exclude ne "" && ![llength $frame]} { fail "EXCLUDE needs a frame (ROWS, RANGE or GROUPS ...)" }
    if {$distinct && [lindex $ba 0 0] eq "star"} { fail "COUNT(DISTINCT *) is not valid" }
    return [list win $name $distinct $ba [dict create base "" partition $part order $ord frame $frame exclude $exclude ignorenulls [specGet $spec ignorenulls 0]]]
}

# ---- tree utilities --------------------------------------------------------
proc ::mkitsql::hasAgg {node} {
    variable aggs
    switch -- [lindex $node 0] {
        func {
            if {[lsearch -exact $aggs [lindex $node 1]] >= 0} { return 1 }
            foreach a [lindex $node 3] { if {[lindex $a 0] ne "star" && [hasAgg $a]} { return 1 } }
            return 0
        }
        lit - ref - slot - insub - exists - sub - star - quant {
            if {[lindex $node 0] eq "insub"} { return [hasAgg [lindex $node 1]] }
            if {[lindex $node 0] eq "quant"} { return [hasAgg [lindex $node 3]] }
            return 0
        }
        win {
            foreach c [exprChildren $node] { if {[hasAgg $c]} { return 1 } }
            return 0
        }
        un { return [hasAgg [lindex $node 2]] }
        bin { return [expr {[hasAgg [lindex $node 2]] || [hasAgg [lindex $node 3]]}] }
        isnull - cast { return [hasAgg [lindex $node 1]] }
        istf { return [hasAgg [lindex $node 1]] }
        isdist { return [expr {[hasAgg [lindex $node 1]] || [hasAgg [lindex $node 2]]}] }
        between { return [expr {[hasAgg [lindex $node 1]] || [hasAgg [lindex $node 2]] || [hasAgg [lindex $node 3]]}] }
        like {
            lassign $node _ e pat esc
            return [expr {[hasAgg $e] || [hasAgg $pat] || ($esc ne "" && [hasAgg $esc])}]
        }
        in {
            if {[hasAgg [lindex $node 1]]} { return 1 }
            foreach a [lindex $node 2] { if {[hasAgg $a]} { return 1 } }
            return 0
        }
        case {
            lassign $node _ operand whens else
            if {$operand ne "" && [hasAgg $operand]} { return 1 }
            foreach w $whens { if {[hasAgg [lindex $w 0]] || [hasAgg [lindex $w 1]]} { return 1 } }
            return [hasAgg $else]
        }
    }
    return 0
}

# Rebuild `node` with `fn` applied to every immediate child expression.
# (Subquery nodes are not descended into; only IN's left operand is mapped.)
proc ::mkitsql::mapChildren {node fn} {
    switch -- [lindex $node 0] {
        win {
            lassign $node t name distinct args spec
            set na {}
            foreach a $args { lappend na [expr {[lindex $a 0] eq "star" ? $a : [{*}$fn $a]}] }
            set np {}
            foreach e [dict get $spec partition] { lappend np [{*}$fn $e] }
            set no {}
            foreach o [dict get $spec order] { lappend no [lreplace $o 0 0 [{*}$fn [lindex $o 0]]] }
            dict set spec partition $np
            dict set spec order $no
            return [list $t $name $distinct $na $spec]
        }
        lit - ref - slot - exists - sub { return $node }
        un { return [list un [lindex $node 1] [{*}$fn [lindex $node 2]]] }
        bin { return [list bin [lindex $node 1] [{*}$fn [lindex $node 2]] [{*}$fn [lindex $node 3]]] }
        isnull { return [lreplace $node 1 1 [{*}$fn [lindex $node 1]]] }
        istf { return [lreplace $node 1 1 [{*}$fn [lindex $node 1]]] }
        cast { return [lreplace $node 1 1 [{*}$fn [lindex $node 1]]] }
        isdist { return [lreplace [lreplace $node 1 1 [{*}$fn [lindex $node 1]]] 2 2 [{*}$fn [lindex $node 2]]] }
        between {
            lassign $node t e lo hi neg
            return [list $t [{*}$fn $e] [{*}$fn $lo] [{*}$fn $hi] $neg]
        }
        like {
            lassign $node t e pat esc neg ci
            return [list $t [{*}$fn $e] [{*}$fn $pat] [expr {$esc eq "" ? "" : [{*}$fn $esc]}] $neg $ci]
        }
        in {
            lassign $node t e items neg
            set ni {}
            foreach it $items { lappend ni [{*}$fn $it] }
            return [list $t [{*}$fn $e] $ni $neg]
        }
        insub {
            return [lreplace $node 1 1 [{*}$fn [lindex $node 1]]]
        }
        quant {
            return [lreplace $node 3 3 [{*}$fn [lindex $node 3]]]
        }
        case {
            lassign $node t operand whens else
            set nw {}
            foreach w $whens { lappend nw [list [{*}$fn [lindex $w 0]] [{*}$fn [lindex $w 1]]] }
            return [list $t [expr {$operand eq "" ? "" : [{*}$fn $operand]}] $nw [{*}$fn $else]]
        }
        func {
            lassign $node t name distinct args
            set na {}
            foreach a $args { lappend na [expr {[lindex $a 0] eq "star" ? $a : [{*}$fn $a]}] }
            return [list $t $name $distinct $na]
        }
    }
    error "mapChildren: [lindex $node 0]"
}

# Does the expression contain a window function call?  (subqueries are not entered)
proc ::mkitsql::hasWin {node} {
    if {[lindex $node 0] eq "win"} { return 1 }
    foreach c [exprChildren $node] { if {[hasWin $c]} { return 1 } }
    return 0
}

# The immediate child expressions of a bound node (subqueries are not entered).
proc ::mkitsql::exprChildren {node} {
    switch -- [lindex $node 0] {
        win {
            set l {}
            foreach a [lindex $node 3] { if {[lindex $a 0] ne "star"} { lappend l $a } }
            set spec [lindex $node 4]
            foreach e [dict get $spec partition] { lappend l $e }
            foreach o [dict get $spec order] { lappend l [lindex $o 0] }
            return $l
        }
        un { return [list [lindex $node 2]] }
        bin { return [list [lindex $node 2] [lindex $node 3]] }
        isnull - istf - cast - insub { return [list [lindex $node 1]] }
        quant { return [list [lindex $node 3]] }
        isdist { return [list [lindex $node 1] [lindex $node 2]] }
        between { return [list [lindex $node 1] [lindex $node 2] [lindex $node 3]] }
        like {
            lassign $node _ e pat esc
            return [expr {$esc eq "" ? [list $e $pat] : [list $e $pat $esc]}]
        }
        in { return [concat [list [lindex $node 1]] [lindex $node 2]] }
        case {
            lassign $node _ operand whens else
            set l {}
            if {$operand ne ""} { lappend l $operand }
            foreach w $whens { lappend l [lindex $w 0] [lindex $w 1] }
            lappend l $else
            return $l
        }
        func {
            set l {}
            foreach a [lindex $node 3] { if {[lindex $a 0] ne "star"} { lappend l $a } }
            return $l
        }
    }
    return {}
}

# Source ids of the *current* scope that an expression refers to.
proc ::mkitsql::localSrcs {node} {
    switch -- [lindex $node 0] {
        ref { return [expr {[lindex $node 1] == 0 ? [list [lindex $node 2]] : {}}] }
        lit - slot { return {} }
        exists { return [outerSrcsAt1 [lindex $node 2]] }
        sub { return [outerSrcsAt1 [lindex $node 2]] }
        insub { return [concat [localSrcs [lindex $node 1]] [outerSrcsAt1 [lindex $node 4]]] }
        quant { return [concat [localSrcs [lindex $node 3]] [outerSrcsAt1 [lindex $node 5]]] }
    }
    set out {}
    foreach c [exprChildren $node] { set out [concat $out [localSrcs $c]] }
    return [lsort -unique $out]
}
proc ::mkitsql::outerSrcsAt1 {refs} {
    set out {}
    foreach r $refs { if {[lindex $r 0] == 1} { lappend out [lindex $r 1] } }
    return [lsort -unique $out]
}

# ============================================================================
#  Binding queries
# ============================================================================
# A bound query is a dict:
#   kind        select | setop | values | query
#   outNames    output column names     outTypes  static types
#   outLetters  Metakit letters ("" if not a plain column)    outDrill (list of 0/1)
#   order limit offset   (kind-specific bodies below)
proc ::mkitsql::bindQuery {q} {
    variable ctes ; variable bindCount ; variable maxBinds
    # a CTE is bound again at every reference, so a chain of CTEs that each use the previous one twice doubles the work at
    # every level: stop a statement that expands to an absurd number of subqueries instead of hanging
    if {[incr bindCount] > $maxBinds} {
        fail "The statement expands to more than $maxBinds subqueries (a CTE or view that is referenced several times in a chain of CTEs is expanded at every reference); simplify it or put an intermediate result in a table"
    }
    set savedCtes $ctes
    foreach c [dict get $q with] {
        lassign $c cname ccols cq crec
        set ctes [linsert $ctes 0 [list $cname $ccols $cq $crec]]
    }
    set rc [catch {bindQueryBody $q} res opts]
    set ctes $savedCtes
    return -options $opts $res
}

proc ::mkitsql::bindQueryBody {q} {
    set body [dict get $q body]
    set order [dict get $q order]
    set limit [dict get $q limit] ; set offset [dict get $q offset]
    set isSelect [expr {[dict get $body type] eq "select"}]
    if {$isSelect} {
        set b [bindSelect $body $order]
        set order {}
    } else {
        set b [bindBody $body]
    }
    # ORDER BY on a set operation / VALUES: output columns only
    set bo {}
    if {[llength $order]} {
        set names [dict get $b outNames]
        foreach o $order {
            lassign $o e dir nulls
            set idx [outColIndex $e $names]
            if {$idx < 0} { fail "ORDER BY on a UNION / VALUES query must name an output column or position" }
            lappend bo [list [list outcol $idx] $dir $nulls]
        }
    }
    set blimit "" ; set boffset ""
    if {$limit ne ""} { set blimit [bindConst $limit "LIMIT"] }
    if {$offset ne ""} { set boffset [bindConst $offset "OFFSET"] }
    if {$isSelect} {
        dict set b limit $blimit
        dict set b offset $boffset
        return $b
    }
    return [dict create kind query body $b order $bo limit $blimit offset $boffset \
        outNames [dict get $b outNames] outTypes [dict get $b outTypes] \
        outLetters [dict get $b outLetters] outDrill [dict get $b outDrill]]
}

proc ::mkitsql::bindConst {e what} {
    variable scopes
    set b [withScopes {} {bx $e}]
    if {[lindex $b 0] ne "lit"} { fail "$what must be a constant number" }
    if {[lindex $b 2] eq $::mkitsql::N || ![string is wideinteger -strict [lindex $b 2]] || [lindex $b 2] < 0} {
        fail "$what must be a non-negative whole number"
    }
    return [lindex $b 2]
}

# returns the 0-based output column an ORDER BY term refers to, or -1
proc ::mkitsql::outColIndex {e names} {
    if {[lindex $e 0] eq "lit" && [lindex $e 1] eq "int"} {
        set n [lindex $e 2]
        if {$n < 1 || $n > [llength $names]} { fail "ORDER BY position $n is out of range (1 to [llength $names])" }
        return [expr {$n - 1}]
    }
    if {[lindex $e 0] eq "col" && [lindex $e 1] eq ""} {
        set i 0
        foreach n $names {
            if {[string equal -nocase $n [lindex $e 2]]} { return $i }
            incr i
        }
    }
    return -1
}

proc ::mkitsql::bindBody {body} {
    switch -- [dict get $body type] {
        select { return [bindSelect $body {}] }
        query  { return [bindQuery $body] }
        values {
            set rows {}
            set ncol [llength [lindex [dict get $body rows] 0]]
            set types [::mkitsql::rep $ncol null]
            foreach r [dict get $body rows] {
                set br {} ; set i 0
                foreach e $r {
                    set b [withScopes {} {bx $e}]
                    lappend br $b
                    lset types $i [unify [lindex $types $i] [dryType $b]]
                    incr i
                }
                lappend rows $br
            }
            set names {} ; set i 0
            foreach t $types { lappend names column[incr i] }
            set types [lmap_ $types {t {expr {$t eq "null" ? "text" : $t}}}]
            return [dict create kind values rows $rows outNames $names outTypes $types \
                outLetters [::mkitsql::rep $ncol ""] outDrill [::mkitsql::rep $ncol 0]]
        }
        setop {
            set l [bindBody [dict get $body left]]
            set r [bindBody [dict get $body right]]
            if {[llength [dict get $l outNames]] != [llength [dict get $r outNames]]} {
                fail "Each [string toupper [dict get $body op]] query must have the same number of columns ([llength [dict get $l outNames]] vs [llength [dict get $r outNames]])"
            }
            set types {}
            foreach a [dict get $l outTypes] b [dict get $r outTypes] { lappend types [unify $a $b] }
            return [dict create kind setop op [dict get $body op] all [dict get $body all] \
                left $l right $r outNames [dict get $l outNames] outTypes $types \
                outLetters [::mkitsql::rep [llength $types] ""] outDrill [::mkitsql::rep [llength $types] 0]]
        }
    }
    error "bindBody"
}

# map over a list with a lambda-ish {var body}
proc ::mkitsql::lmap_ {list spec} {
    lassign $spec var body
    set out {}
    foreach $var $list { lappend out [uplevel 1 [list apply [list $var $body] [set $var]]] }
    return $out
}

# Static type of a bound expression, computed without generating real code.
# Aggregates are replaced by typed placeholders first.
proc ::mkitsql::dryType {b} {
    set n [replaceAggs $b]
    return [lindex [cg $n [dict create maps {} dry 1]] 1]
}
proc ::mkitsql::aggType {node} {
    lassign $node _ name distinct args
    switch -- $name {
        COUNT { return int }
        SUM {
            set t [dryType [lindex $args 0]]
            return [expr {$t in {int bool} ? "int" : ($t eq "interval" ? "interval" : "real")}]
        }
        AVG { return [expr {[dryType [lindex $args 0]] eq "interval" ? "interval" : "real"}] }
        MIN - MAX { return [dryType [lindex $args 0]] }
    }
    return text
}
proc ::mkitsql::replaceAggs {node} {
    variable aggs
    if {[lindex $node 0] eq "func" && [lsearch -exact $aggs [lindex $node 1]] >= 0} {
        return [list lit [aggType $node] x]
    }
    if {[lindex $node 0] eq "win"} { return [list lit [winType $node] x] }
    return [mapChildren $node ::mkitsql::replaceAggs]
}

# ---- SELECT ----------------------------------------------------------------
# `order` (parser terms) is bound together with the select so ORDER BY can use
# output aliases and pre-projection expressions.
proc ::mkitsql::bindSelect {sel order} {
    variable scopes ; variable fromSoFar ; variable refLog
    set savedFrom $fromSoFar
    set fromSoFar {}
    set rc [catch {bindSelectInner $sel $order} res opts]
    set fromSoFar $savedFrom
    return -options $opts $res
}

proc ::mkitsql::bindSelectInner {sel order} {
    variable scopes ; variable fromSoFar
    # FROM
    set from [dict get $sel from]
    set bfrom {}
    if {$from ne ""} { set bfrom [bindFrom $from] }
    set srcs $fromSoFar
    set bfrom [refreshTree $bfrom $srcs]
    # names visible while binding expressions: this SELECT's sources + enclosing scopes
    set saved $scopes
    set scopes [linsert $scopes 0 $srcs]
    set rc [catch {bindSelectExprs $sel $order $srcs $bfrom} res opts]
    set scopes $saved
    return -options $opts $res
}

# the FROM tree holds copies of source dicts that markHidden may have updated
proc ::mkitsql::refreshTree {t srcs} {
    if {[lindex $t 0] eq "src"} {
        set id [dict get [lindex $t 1] id]
        foreach s $srcs { if {[dict get $s id] == $id} { return [list src $s] } }
        return $t
    }
    if {[lindex $t 0] eq "join"} {
        return [lreplace [lreplace $t 2 2 [refreshTree [lindex $t 2] $srcs]] 3 3 [refreshTree [lindex $t 3] $srcs]]
    }
    return $t
}

proc ::mkitsql::bindSelectExprs {sel order srcs bfrom} {
    variable curWindows
    set savedWindows $curWindows
    set curWindows [expr {[dict exists $sel windows] ? [dict get $sel windows] : [dict create]}]
    set rc [catch {bindSelectExprs2 $sel $order $srcs $bfrom} res opts]
    set curWindows $savedWindows
    return -options $opts $res
}

proc ::mkitsql::bindSelectExprs2 {sel order srcs bfrom} {
    # items (with * expansion)
    set items {} ; set names {} ; set types {} ; set letters {} ; set drills {}
    foreach it [dict get $sel items] {
        lassign $it e alias text
        if {[lindex $e 0] eq "star"} {
            set q [string tolower [lindex [split [lindex $e 1] .] end]]
            set matched 0
            foreach s $srcs {
                if {$q ne "" && [dict get $s alias] ne $q} continue
                set matched 1
                foreach c [dict get $s cols] {
                    if {[lsearch -exact [dict get $s hidden] [string tolower [lindex $c 0]]] >= 0 && $q eq ""} continue
                    set rid [expr {$q eq "" ? [mergedWith $s [string tolower [lindex $c 0]]] : ""}]
                    if {$rid ne ""} {
                        lappend items [mergedExpr $srcs $s $c $rid]
                        lappend names [visibleName [lindex $c 0]]
                        lappend types [lindex $c 1] ; lappend letters "" ; lappend drills 0
                        continue
                    }
                    noteRef 0 [dict get $s id] [lindex $c 0]
                    lappend items [list ref 0 [dict get $s id] [lindex $c 0] [lindex $c 1]]
                    lappend names [visibleName [lindex $c 0]]
                    lappend types [lindex $c 1]
                    lappend letters [lindex $c 2]
                    lappend drills [drillName $c]
                }
            }
            if {!$matched} {
                if {$q ne ""} { fail "Unknown table or alias '$q' in '[lindex $e 1].*'" }
                fail "SELECT * needs a FROM clause"
            }
            continue
        }
        set b [bx $e]
        lappend items $b
        set nm $alias
        if {$nm eq ""} { if {[lindex $e 0] eq "col"} { set nm [lindex $e 2] } else { set nm $text } }
        lappend names $nm
        lappend types "?"
        if {[lindex $b 0] eq "ref"} {
            set s [findSrc $srcs [lindex $b 2]]
            set ci [expr {$s eq "" ? -1 : [srcColIndex $s [lindex $b 3]]}]
            if {$ci >= 0} {
                set col [lindex [dict get $s cols] $ci]
                lappend letters [lindex $col 2] ; lappend drills [drillName $col]
            } else { lappend letters "" ; lappend drills 0 }
        } else { lappend letters "" ; lappend drills 0 }
    }
    if {![llength $items]} { fail "The select list is empty" }
    set types {}
    foreach b $items { lappend types [dryType $b] }

    # WHERE
    set where [dict get $sel where]
    set bwhere ""
    if {$where ne ""} {
        set bwhere [bx $where]
        if {[hasAgg $bwhere]} { fail "Aggregate functions are not allowed in WHERE; use HAVING" }
        if {[hasWin $bwhere]} { fail "Window functions are not allowed in WHERE" }
    }
    # GROUP BY (ordinals and output aliases allowed)
    set group {}
    foreach g [dict get $sel group] {
        if {[lindex $g 0] eq "lit" && [lindex $g 1] eq "int"} {
            set n [lindex $g 2]
            if {$n < 1 || $n > [llength $items]} { fail "GROUP BY position $n is out of range" }
            lappend group [lindex $items [expr {$n - 1}]]
            continue
        }
        if {[lindex $g 0] eq "col" && [lindex $g 1] eq ""} {
            set resolved 1
            if {[catch {bx $g} bg]} { set resolved 0 }
            if {!$resolved} {
                set idx [outColIndex $g $names]
                if {$idx >= 0} { lappend group [lindex $items $idx] ; continue }
                fail $bg
            }
            lappend group $bg ; continue
        }
        set bg [bx $g]
        if {[hasAgg $bg]} { fail "Aggregate functions are not allowed in GROUP BY" }
        if {[hasWin $bg]} { fail "Window functions are not allowed in GROUP BY" }
        lappend group $bg
    }
    # HAVING
    set having [dict get $sel having]
    set bhaving ""
    if {$having ne ""} {
        set bhaving [bx $having]
        if {[hasWin $bhaving]} { fail "Window functions are not allowed in HAVING" }
    }
    # ORDER BY
    set border {}
    foreach o $order {
        lassign $o e dir nulls
        set idx [outColIndex $e $names]
        if {$idx >= 0} {
            lappend border [list [list outcol $idx] $dir $nulls]
        } else {
            lappend border [list [bx $e] $dir $nulls]
        }
    }
    set isAgg [expr {[llength $group] > 0}]
    foreach b $items { if {[hasAgg $b]} { set isAgg 1 } }
    if {$bhaving ne "" && [hasAgg $bhaving]} { set isAgg 1 }
    foreach o $border { if {[lindex $o 0 0] ne "outcol" && [hasAgg [lindex $o 0]]} { set isAgg 1 } }
    if {$bhaving ne "" && !$isAgg} {
        set isAgg 1   ;# HAVING without GROUP BY: one group
    }
    return [dict create kind select srcs $srcs from $bfrom where $bwhere items $items \
        group $group having $bhaving order $border distinct [dict get $sel distinct] \
        isAgg $isAgg outNames $names outTypes $types outLetters $letters outDrill $drills \
        limit "" offset ""]
}

proc ::mkitsql::findSrc {srcs id} {
    foreach s $srcs { if {[dict get $s id] == $id} { return $s } }
    return ""
}
