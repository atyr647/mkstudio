# dbcommon.tcl -- storage operations built only from the primitives every storage layer provides (layout, size,
# restructure, ...), so db.tcl (standalone) and db_studio.tcl (MK Studio's ::store) behave identically.  Loaded before either.
namespace eval ::mkitsql::db { variable tmpSeq 0 }

# Rename and/or retype a top-level scalar column, keeping its data.  Metakit identifies a property by
# (name, type), so the new column is added, filled from the old one (coercing numbers) and the old one
# dropped; the rebuilt column ends up last.
proc ::mkitsql::db::rebuildColumn {path oldName newName newType} {
    set layout [layout $path]
    set oldType ""
    foreach c $layout { if {[lindex $c 0] eq $oldName} { set oldType [lindex $c 1] } }
    if {$oldType eq "" || $oldType eq "V"} { error "'$oldName' is not a scalar column." }
    if {$newName ne $oldName} {
        foreach c $layout { if {[lindex $c 0] eq $newName} { error "Column '$newName' already exists." } }
    }
    # a retype keeps the column's name with another type: Metakit cannot do that (see dbcheck.tcl)
    if {$newName eq $oldName && $newType ne $oldType} {
        error "Metakit cannot change the type of column '$oldName' in place; copy the table with CREATE TABLE ... AS SELECT CAST($oldName AS ...)."
    }
    variable tmpSeq
    set tmp __mks_tmp_[pid]_[incr tmpSeq]            ;# never reused: a name that came back with another type would clash
    if {[string first ! $path] < 0} {
        lassign [split $path .] gtag gview
        # the final layout must not give any name a type it has not had: checked BEFORE anything changes
        set final {}
        foreach c $layout { if {[lindex $c 0] ne $oldName} { lappend final $c } }
        typeGuard $gtag $gview [concat $final [list [list $newName $newType {}]]]
    }
    set base {}
    foreach c $layout { if {[lindex $c 0] ne $oldName} { lappend base $c } }
    set T [list $tmp $newType {}]
    set Nw [list $newName $newType {}]
    restructure $path [concat $layout [list $T]]
    copyColumn $path $oldName $tmp $newType
    restructure $path [concat $base [list $T]]
    restructure $path [concat $base [list $T $Nw]]
    copyColumn $path $tmp $newName $newType
    restructure $path [concat $base [list $Nw]]
}
proc ::mkitsql::db::copyColumn {path from to type} {
    set n [size $path]
    for {set i 0} {$i < $n} {incr i} {
        set v [mk::get $path!$i $from]
        switch -- $type {
            I - L { if {![string is integer -strict $v]} { set v [expr {[string is double -strict $v] ? entier($v) : 0}] } }
            F - D { if {![string is double -strict $v]} { set v 0 } }
        }
        mk::set $path!$i $to $v
    }
}

# ---- reading rows (shared by both back ends) ------------------------------------------------------------
# `count` rows from `first`, as lists of values in the order of `props` (scalar properties only).
proc ::mkitsql::db::rows {path props first count} {
    set out {}
    set n [mk::view size $path]
    set last [expr {min($n, $first + $count) - 1}]
    set np [llength $props]
    if {$::mkitsql::listBug} {
        # Tcl 8.5 / 8.6.3 damage the string form of a list whose first element is '#...' text with two or more ] or ", and
        # that is the list a multi-property mk::get returns: read one property at a time (see ::mkitsql::rt::sk)
        # (the check on the first cell is inlined, and one to four properties are unrolled: reading is the bulk of a scan)
        switch -- $np {
            1 { lassign $props p1
                for {set i $first} {$i <= $last} {incr i} {
                    set row [list [mk::get $path!$i $p1]]
                    if {[string index [lindex $row 0] 0] eq "#"} { set row [::mkitsql::rt::sk $row] }
                    lappend out $row } }
            2 { lassign $props p1 p2
                for {set i $first} {$i <= $last} {incr i} {
                    set r $path!$i
                    set row [list [mk::get $r $p1] [mk::get $r $p2]]
                    if {[string index [lindex $row 0] 0] eq "#"} { set row [::mkitsql::rt::sk $row] }
                    lappend out $row } }
            3 { lassign $props p1 p2 p3
                for {set i $first} {$i <= $last} {incr i} {
                    set r $path!$i
                    set row [list [mk::get $r $p1] [mk::get $r $p2] [mk::get $r $p3]]
                    if {[string index [lindex $row 0] 0] eq "#"} { set row [::mkitsql::rt::sk $row] }
                    lappend out $row } }
            4 { lassign $props p1 p2 p3 p4
                for {set i $first} {$i <= $last} {incr i} {
                    set r $path!$i
                    set row [list [mk::get $r $p1] [mk::get $r $p2] [mk::get $r $p3] [mk::get $r $p4]]
                    if {[string index [lindex $row 0] 0] eq "#"} { set row [::mkitsql::rt::sk $row] }
                    lappend out $row } }
            default {
                for {set i $first} {$i <= $last} {incr i} {
                    set r $path!$i ; set row {}
                    foreach p $props { lappend row [mk::get $r $p] }
                    if {[string index [lindex $row 0] 0] eq "#"} { set row [::mkitsql::rt::sk $row] }
                    lappend out $row
                }
            }
        }
        return $out
    }
    for {set i $first} {$i <= $last} {incr i} {
        if {$np == 0} {
            lappend out {}
        } elseif {$np == 1} {
            lappend out [list [mk::get $path!$i [lindex $props 0]]]     ;# a single property comes back unwrapped
        } else {
            lappend out [mk::get $path!$i {*}$props]
        }
    }
    return $out
}


# the given rows (indices) in the order of `props`, like `rows`
proc ::mkitsql::db::rowsAt {path props indices} {
    set out {}
    set np [llength $props]
    if {$np == 0} { foreach i $indices { lappend out {} } ; return $out }
    if {$::mkitsql::listBug} {
        foreach i $indices {
            set r $path!$i ; set row {}
            foreach p $props { lappend row [mk::get $r $p] }
            if {[string index [lindex $row 0] 0] eq "#"} { set row [::mkitsql::rt::sk $row] }
            lappend out $row
        }
        return $out
    }
    if {$np == 1} {
        set p [lindex $props 0]
        foreach i $indices { lappend out [list [mk::get $path!$i $p]] }
        return $out
    }
    foreach i $indices { lappend out [mk::get $path!$i {*}$props] }
    return $out
}

# ---- the frame of a committed Metakit file (shared: the repair of an interrupted commit, and the adapter's guard) ----------
proc ::mkitsql::db::commitRecord {path} { return $path.commit }
# {size S offset H header <8 bytes as hex>} for a Metakit file with the usual header, "" for anything else
proc ::mkitsql::db::headerInfo {path} {
    if {[catch {set h [open $path rb] ; set d [read $h 8] ; close $h}] || [string length $d] < 8} { return "" }
    set magic [string range $d 0 1]
    if {$magic eq "JL"} { binary scan $d x4I off } elseif {$magic eq "LJ"} { binary scan $d x4i off } else { return "" }
    if {[string index $d 2] ne "\x1a"} { return "" }
    binary scan $d H* hex
    return [dict create size [::file size $path] offset [expr {$off & 0xFFFFFFFF}] header $hex]
}

# Does a valid 16-byte Metakit footer end exactly at `end` (the state a committed file of that size has)?  The repairs below only
# cut or restore a file when this holds for the state they restore, so a damaged header can never make them throw data away.
proc ::mkitsql::db::footerOkAt {path end} {
    if {$end < 24 || $end > [::file size $path]} { return 0 }
    if {[catch {set h [open $path rb] ; set head [read $h 2] ; seek $h [expr {$end - 16}] start ; set tail [read $h 16] ; close $h}] || [string length $tail] != 16} { return 0 }
    set fmt [expr {$head eq "JL" ? "I" : "i"}]
    binary scan $tail $fmt$fmt$fmt$fmt w0 footPos w2 tocPos
    return [expr {($w0 & 0xFFFFFFFF) == 0x80000000 && (($w2 >> 24) & 0xFF) == 0x80 && ($footPos & 0xFFFFFFFF) == $end - 16 && ($tocPos & 0xFFFFFFFF) < $end - 16}]
}

# Would the repair of an interrupted commit (MK Studio's, or ours) be SAFE for this file?  "" if there is nothing to repair or the
# state it would restore ends in a valid footer; otherwise why not.  An older MK Studio truncates a file to the size its header
# claims without looking, so a damaged header could make it throw the real data away: the adapter checks first.
proc ::mkitsql::db::repairUnsafe {path} {
    set info [headerInfo $path]
    if {$info eq ""} { return "" }
    set rec [commitRecord $path]
    if {[::file exists $rec]} {
        if {[catch {set h [open $rec r] ; set d [string trim [read $h 200]] ; close $h}]} { return "" }
        lassign [split $d " "] hex size
        if {[string length $hex] == 16 && [string is integer -strict $size] && [::file size $path] >= $size && [dict get $info header] ne $hex} {
            if {![footerOkAt $path $size]} { return "an interrupted commit was found, but the file does not end in a valid footer where it should" }
        }
        return ""
    }
    if {[dict get $info size] > [dict get $info offset] && ![footerOkAt $path [dict get $info offset]]} {
        return "the file is longer than its header says, and no valid end of a committed file is where the header points"
    }
    return ""
}

# ---- Metakit's 2 GiB ceiling (the size of a file is a signed 32-bit offset throughout Metakit: its source refuses a commit past it) ---------------
# Bytes the file of this handle may still grow by before a commit fails (as of its last commit), and whether it is within `fraction` of the
# ceiling - for an application to warn, archive or split before a commit has to be undone.
namespace eval ::mkitsql::db { variable maxFileBytes 2147483647 }
proc ::mkitsql::db::fileHeadroom {tag} {
    variable maxFileBytes
    if {$tag ni [tags]} { return -code error -errorcode [list MKIT UNKNOWN $tag] "Unknown database '$tag'. Open databases: [join [tags] {, }]" }
    set p [path $tag]
    expr {$maxFileBytes - ([::file exists $p] ? [::file size $p] : 0)}
}
proc ::mkitsql::db::nearLimit {tag {fraction 0.9}} {
    variable maxFileBytes
    if {![string is double -strict $fraction] || $fraction < 0 || $fraction > 1} { return -code error "The fraction must be a number from 0 to 1" }
    expr {[fileHeadroom $tag] <= $maxFileBytes * (1.0 - $fraction)}
}

# ---- the checksum file (<file>.sum, MK Studio's format), read safely: shared by both storage layers ------------------------------------
proc ::mkitsql::db::sumPath {path} { return $path.sum }
# The sum file as {crc size mtime sumMtime}, or "" when it is missing, not a plain small file (a FIFO would block, a huge file would be read
# whole) or not in the format.
proc ::mkitsql::db::sumRead {path} {
    set sp [sumPath $path]
    if {[catch {::file lstat $sp st}] || $st(type) ne "file" || $st(size) > 4096} { return "" }
    if {[catch {set h [open $sp r] ; set d [string trim [read $h 200]] ; close $h}]} { return "" }
    if {[catch {llength $d} n] || $n != 3} { return "" }
    lassign $d crc size mtime
    if {![regexp {^[0-9a-fA-F]{8}$} $crc] || ![string is integer -strict $size] || ![string is integer -strict $mtime]} { return "" }
    return [list [string tolower $crc] $size $mtime $st(mtime)]
}
# The sum was written in the same second as the file's last change, so it cannot yet tell another program's write from damage.  Once the file is
# proven intact in a LATER second, stamp the sum file a second after the file's time: from then on a difference is unambiguous.
proc ::mkitsql::db::sumRestamp {path} {
    set r [sumRead $path]
    if {$r eq ""} return
    lassign $r crc size mtime sumMtime
    if {$sumMtime <= $mtime && [clock seconds] > $mtime} { catch {::file mtime [sumPath $path] [expr {$mtime + 1}]} }
}
