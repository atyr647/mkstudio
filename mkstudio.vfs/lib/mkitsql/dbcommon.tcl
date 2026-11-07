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
    variable wideCap
    set n [size $path]
    for {set i 0} {$i < $n} {incr i} {
        set v [mk::get $path!$i $from]
        switch -- $type {
            I - L { if {![string is integer -strict $v]} { set v [expr {[string is double -strict $v] ? entier($v) : 0}] } }
            F - D { if {![string is double -strict $v]} { set v 0 } }
        }
        if {$wideCap eq "1"} { guardWrite $path [list $to] [list $v] }
        if {[catch {mk::set $path!$i $to $v} err opts]} { sizeFault $path $err $opts }
    }
}

# ---- reading rows (shared by both back ends) ------------------------------------------------------------
# One cell.  A property name with U+FDD4 in it is a part of a blob (bind.tcl, blobPart):  b<U+FDD4>size  is its length from
# mk::get -size, and  b<U+FDD4>range<U+FDD4>start<U+FDD4>len  is SUBSTR(b, start, len) read through mk::channel.  Neither fetches
# the whole value.
proc ::mkitsql::db::cell {r p} {
    set k [string first "\uFDD4" $p]
    if {$k < 0} { return [mk::get $r $p] }
    set base [string range $p 0 [expr {$k - 1}]]
    set spec [split [string range $p [expr {$k + 1}] end] "\uFDD4"]
    set size [mk::get $r -size $base]
    if {[lindex $spec 0] eq "size"} { return $size }
    lassign $spec _ start len
    set to [expr {min($start + $len - 1, $size)}]
    if {$to < $start} { return "" }
    if {[llength [info commands ::mk::channel]] == 0} { return [string range [mk::get $r $base] [expr {$start - 1}] [expr {$to - 1}]] }
    set ch [mk::channel $r $base r]
    set rc [catch {
        fconfigure $ch -translation binary
        seek $ch [expr {$start - 1}]
        set v [read $ch [expr {$to - $start + 1}]]
    } err opts]
    close $ch
    if {$rc} { return -options $opts $err }
    return $v
}
# rows in the order of `props`, reading only what is needed: parts of blobs (above), and nothing at the positions in `skip`
# (blobs a scan reads later, for the rows its filter lets through: those cells are "" here)
proc ::mkitsql::db::rowsSlow {path props indices skip} {
    set out {}
    set np [llength $props]
    foreach i $indices {
        set r $path!$i ; set row {} ; set k 0
        foreach p $props {
            if {[lsearch -exact $skip $k] >= 0} { lappend row "" } else { lappend row [cell $r $p] }
            incr k
        }
        if {$np && [string index [lindex $row 0] 0] eq "#"} { set row [::mkitsql::rt::sk $row] }
        lappend out $row
    }
    return $out
}
proc ::mkitsql::db::slowProps {props skip} { expr {[llength $skip] || [string first "\uFDD4" $props] >= 0} }

# `count` rows from `first`, as lists of values in the order of `props` (scalar properties only).
proc ::mkitsql::db::rows {path props first count {skip {}}} {
    set out {}
    set n [mk::view size $path]
    set last [expr {min($n, $first + $count) - 1}]
    set np [llength $props]
    if {[slowProps $props $skip]} {
        set idx {} ; for {set i $first} {$i <= $last} {incr i} { lappend idx $i }
        return [rowsSlow $path $props $idx $skip]
    }
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
proc ::mkitsql::db::rowsAt {path props indices {skip {}}} {
    if {[slowProps $props $skip]} { return [rowsSlow $path $props $indices $skip] }
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
# {size S offset H header <8 bytes as hex> wide 0|1} for a Metakit file with the usual header, "" for anything else.  A "wide" file (a
# Metakit built for files over 2 GiB sets bit 0x40 of the fourth header byte, see docs/SQL.md) has 24-byte tails and keeps no usable file
# size in its header: its offset is reported as the file size.
proc ::mkitsql::db::headerInfo {path} {
    if {[catch {set h [open $path rb] ; set d [read $h 8] ; close $h}] || [string length $d] < 8} { return "" }
    set magic [string range $d 0 1]
    if {$magic ne "JL" && $magic ne "LJ"} { return "" }
    if {[string index $d 2] ne "\x1a"} { return "" }
    binary scan $d H* hex
    set wide [wideHeader $d]
    if {$wide} {
        set off [::file size $path]
    } else {
        if {$magic eq "JL"} { binary scan $d x4I off } else { binary scan $d x4i off }
        set off [expr {$off & 0xFFFFFFFF}]
    }
    return [dict create size [::file size $path] offset $off header $hex wide $wide]
}
# is this 8-byte header the header of a wide file?
proc ::mkitsql::db::wideHeader {head8} {
    binary scan [string index $head8 3] c b3
    expr {([string range $head8 0 1] eq "JL" || [string range $head8 0 1] eq "LJ") && ($b3 & 0xC0) == 0x40}
}
proc ::mkitsql::db::isWide {path} {
    if {[catch {set h [open $path rb] ; set d [read $h 8] ; close $h}] || [string length $d] < 8} { return 0 }
    wideHeader $d
}

# Does a valid Metakit footer end exactly at `end` (the state a committed file of that size has)?  The repairs below only cut or restore a
# file when this holds for the state they restore, so a damaged header can never make them throw data away.  `wide`: the 24-byte footer
# of a file over 2 GiB (three tails: skip 0x82, extension 0x83, commit 0x81, all big-endian; src/marks.h of the 64-bit Metakit).
proc ::mkitsql::db::footerOkAt {path end {wide 0}} {
    set n [expr {$wide ? 24 : 16}]
    if {$end < 8 + $n || $end > [::file size $path]} { return 0 }
    if {[catch {set h [open $path rb] ; set head [read $h 2] ; seek $h [expr {$end - $n}] start ; set tail [read $h $n] ; close $h}] || [string length $tail] != $n} { return 0 }
    if {$wide} {
        binary scan $tail cH6IcH6IcH6I t1 z skLo t2 skHi rHi t3 len rLo
        if {($t1 & 0xFF) != 0x82 || $z ne "000000" || ($t2 & 0xFF) != 0x83 || ($t3 & 0xFF) != 0x81} { return 0 }
        set skip [expr {([scan $skHi %x] << 32) + ($skLo & 0xFFFFFFFF)}]
        set root [expr {(($rHi & 0xFFFFFFFF) << 32) + ($rLo & 0xFFFFFFFF)}]
        return [expr {$skip == $end - 24 && $root < $skip}]
    }
    set fmt [expr {$head eq "JL" ? "I" : "i"}]
    binary scan $tail $fmt$fmt$fmt$fmt w0 footPos w2 tocPos
    return [expr {($w0 & 0xFFFFFFFF) == 0x80000000 && (($w2 >> 24) & 0xFF) == 0x80 && ($footPos & 0xFFFFFFFF) == $end - 16 && ($tocPos & 0xFFFFFFFF) < $end - 16}]
}
# is the header given as 16 hex digits (as the commit record keeps it) a wide one?
proc ::mkitsql::db::wideHex {hex} {
    if {[string length $hex] != 16 || ![string is xdigit -strict $hex]} { return 0 }
    wideHeader [binary format H* $hex]
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
            if {![footerOkAt $path $size [wideHex $hex]]} { return "an interrupted commit was found, but the file does not end in a valid footer where it should" }
        }
        return ""
    }
    if {![dict get $info wide] && [dict get $info size] > [dict get $info offset] && ![footerOkAt $path [dict get $info offset]]} {
        return "the file is longer than its header says, and no valid end of a committed file is where the header points"
    }
    return ""
}

# ---- Metakit's 2 GiB ceiling, and the Metakit that has none -------------------------------------------------------------------------
# Stock Metakit keeps file positions in a signed 32-bit word: a file cannot pass 2 GiB (a commit that would fails).  A Metakit built from
# https://github.com/atyr647/metakit (branch with the 64-bit file positions) can: past 2 GiB it writes "wide" tails and flags the header
# (bit 0x40 of its fourth byte); files below 2 GiB are byte for byte what they always were.  A stock Metakit that is given such a file sees
# an EMPTY database (and a commit would hide the data behind new bytes), so
#   - wideCapable asks the loaded library, once, with a small wide file it builds itself (no trust in a version number),
#   - the openers refuse a wide file when the library cannot read it,
#   - the limit that fileHeadroom / nearLimit measure against follows the library.
# One column (or memo) is still limited to 2^31-1 bytes whatever the file size; see the column guard below.
namespace eval ::mkitsql::db {
    variable maxFileBytes 2147483647                  ;# stock Metakit
    variable wideMaxFileBytes [expr {(1 << 56) - 64}] ;# the 64-bit Metakit (positions beyond 2^56 are refused by it)
    variable maxColumnBytes 2147483647
    variable wideCap ""
}
# 1 if the loaded Mk4tcl reads files over 2 GiB (the wide format).  MKIT_WIDE=0 in the environment forces 0 (to test the refusals).
proc ::mkitsql::db::wideCapable {} {
    variable wideCap
    if {$wideCap ne ""} { return $wideCap }
    set cap 0
    if {[info exists ::env(MKIT_WIDE)] && $::env(MKIT_WIDE) eq "0"} {
        set cap 0
    } elseif {[llength [info commands ::mk::file]] && ![catch {probeWide} r] && $r eq "1"} {
        set cap 1
    }
    set wideCap $cap
}
# A standard file made by the library, turned into a wide one (what a 64-bit Metakit writes past 2 GiB): the three wide tails replace the two
# standard ones and the header is flagged.  Used by the probe and by tests/widefile.tcl.  Error unless the data is a small JL file.
proc ::mkitsql::db::wideConvert {data} {
    set n [string length $data]
    if {$n < 40 || [string range $data 0 1] ne "JL" || [string index $data 2] ne "\x1a"} { error "not a standard Metakit file" }
    binary scan [string range $data end-15 end] IIII w0 skip w2 root
    if {($w0 & 0xFFFFFFFF) != 0x80000000 || (($w2 >> 24) & 0xFF) != 0x80 || ($skip & 0xFFFFFFFF) != $n - 16} { error "not a committed Metakit file" }
    set len [expr {$w2 & 0xFFFFFF}]
    set tails [binary format "cH6IcH6IcH6I" 0x82 000000 [expr {$skip & 0xFFFFFFFF}]  0x83 000000 0  0x81 [format %06x $len] [expr {$root & 0xFFFFFFFF}]]
    return [binary format a2cc "JL" 0x1a 0x40][binary format I [expr {$n + 8}]][string range $data 8 end-16]$tails
}
proc ::mkitsql::db::probeWide {} {
    set base [file join [::mkitsql::tmpDir] mkitsql-probe-[pid]-[::mkitsql::randHex 8]]
    set t __mkit_probe_[pid]
    set files [list $base.a $base.b]
    set ok 0
    catch {
        # a standard file with one row, made by the library itself
        set ch [open $base.a {WRONLY CREAT EXCL} 384] ; close $ch
        mk::file open $t $base.a
        mk::view layout $t.p {k:I}
        mk::row append $t.p k 42
        mk::file commit $t
        mk::file close $t
        set ch [open $base.a rb] ; set data [read $ch] ; close $ch
        set ch [open $base.b {WRONLY CREAT EXCL} 384] ; fconfigure $ch -translation binary ; puts -nonewline $ch [wideConvert $data] ; close $ch
        # a library that knows the wide format finds the row, any other one finds no database at all
        mk::file open $t $base.b -readonly
        if {![catch {mk::view size $t.p} n] && $n == 1 && [mk::get $t.p!0 k] == 42} { set ok 1 }
        mk::file close $t
    }
    catch {mk::file close $t}
    foreach f $files { catch {::file delete $f} }
    return $ok
}
# the largest size a file can have with this library
proc ::mkitsql::db::fileLimit {} {
    variable maxFileBytes ; variable wideMaxFileBytes
    expr {[wideCapable] ? $wideMaxFileBytes : $maxFileBytes}
}
# A wide file with a library that cannot read it: why it must not be opened ("" if all is well)
proc ::mkitsql::db::wideRefusal {path} {
    if {![::file exists $path] || ![isWide $path] || [wideCapable]} { return "" }
    return "This file is larger than 2 GiB and uses the wide format of a Metakit built for big files; the Metakit library in use cannot read it (it would show an empty database, and saving would hide the data). Use a Mk4tcl built from https://github.com/atyr647/metakit, or open the file in the program that wrote it.\n$path"
}
# Bytes the file of this handle may still grow by before a commit fails (as of its last commit), and whether it is within `fraction` of the
# limit - for an application to warn, archive or split before a commit has to be undone.
proc ::mkitsql::db::fileHeadroom {tag} {
    if {$tag ni [tags]} { return -code error -errorcode [list MKIT UNKNOWN $tag] "Unknown database '$tag'. Open databases: [join [tags] {, }]" }
    set p [path $tag]
    expr {[fileLimit] - ([::file exists $p] ? [::file size $p] : 0)}
}
proc ::mkitsql::db::nearLimit {tag {fraction 0.9}} {
    if {![string is double -strict $fraction] || $fraction < 0 || $fraction > 1} { return -code error "The fraction must be a number from 0 to 1" }
    set lim [fileLimit]
    expr {[fileHeadroom $tag] <= $lim * (1.0 - $fraction)}
}

# ---- the column guard (the 64-bit Metakit only) ------------------------------------------------------------------------------------
# What fills a column (limit 2^31-1 bytes), from the Metakit source (format.cpp): every value of a text or blob property lives in ONE shared
# column, except that a COMMIT moves each value of more than 10,000 bytes (and, in tables of very many rows, smaller ones) out into a column of
# its own, which has the limit alone.  So the shared column holds
#     everything written since the last commit (whatever the size)   +   the committed values that are small (at most 10,000 bytes).
# A blob column can therefore hold many times 2 GiB as long as it is committed now and then (tests/widebig.tcl writes 2.1 GiB into one);
# the guard counts exactly that and no more:
#   guardPc   per column: bytes written since the last commit        guardPb   the part of them in values over 10,000 bytes (gone at the commit)
#   guardIn   per column: the committed small values, found by one pass over the column the first time it matters, kept up to date after
# A column is never larger than the file plus what has been written since the last commit, so none of this is looked at until that sum nears
# the limit (one counter per file is all that a normal import pays).  The per-column counters are only kept ("tracking") once a transaction has
# written more than 1/16 of the limit, or once a column has been counted; the bytes written before that are known only as a total, which
# bounds every column (guardTrack($tag) is that total, -1 while not tracking).  Deletes are not subtracted: the count errs on the safe side.
namespace eval ::mkitsql::db {
    variable guardBase ; variable guardPend ; variable guardTrack ; variable guardSlack 4194304 ; variable guardSmall 10000
    variable guardPc ; variable guardPb ; variable guardIn ; variable guardTy
    array set guardBase {} ; array set guardPend {} ; array set guardTrack {} ; array set guardPc {} ; array set guardPb {} ; array set guardIn {} ; array set guardTy {}
}
# the handle `tag` was opened, committed, rolled back or restructured: the size of the file now, nothing pending
proc ::mkitsql::db::guardReset {tag {forget 0}} {
    variable guardBase ; variable guardPend ; variable guardTrack ; variable guardPc ; variable guardPb ; variable guardIn ; variable guardTy
    if {![wideCapable]} return
    set p [expr {[catch {path $tag} x] ? "" : $x}]
    set guardBase($tag) [expr {$p ne "" && [::file exists $p] ? [::file size $p] : 0}]
    set guardPend($tag) 0
    if {!$forget && [info exists guardTrack($tag)] && $guardTrack($tag) == 0} {
        # committed, and every write since the last commit was counted per column: the small ones stay in their column, the big ones went to
        # columns of their own
        foreach k [array names guardIn $tag.*] {
            set small [expr {[info exists guardPc($k)] ? $guardPc($k) : 0}]
            if {[info exists guardPb($k)]} { incr small -$guardPb($k) }
            incr guardIn($k) $small
        }
    } else {
        array unset guardIn $tag.*                       ;# opened, rolled back, restructured, or not counted exactly: counted again when it matters
    }
    if {$forget} { array unset guardTy $tag.* }
    array unset guardPc $tag.* ; array unset guardPb $tag.*
    set guardTrack($tag) [expr {[llength [array names guardIn $tag.*]] ? 0 : -1}]      ;# columns that are kept up to date are tracked from the start
}
proc ::mkitsql::db::guardForget {tag} {
    variable guardBase ; variable guardPend ; variable guardTrack ; variable guardPc ; variable guardPb ; variable guardIn ; variable guardTy
    unset -nocomplain guardBase($tag) guardPend($tag) guardTrack($tag)
    array unset guardPc $tag.* ; array unset guardPb $tag.* ; array unset guardIn $tag.* ; array unset guardTy $tag.*
}
# `path` is tag.view (or tag.view!row.sub...); `props` the columns about to receive `values`.  Raises MKIT COLUMNFULL, with nothing counted, when a
# value would not fit; otherwise counts what is written.
proc ::mkitsql::db::guardWrite {path props values} {
    variable guardBase ; variable guardPend ; variable guardTrack ; variable maxColumnBytes ; variable guardSlack
    set tag [lindex [split $path .] 0]
    if {![info exists guardBase($tag)]} { guardReset $tag }
    set add 0
    foreach v $values { incr add [expr {[string bytelength $v] + 1}] }
    set sum [expr {$guardPend($tag) + $add}]
    if {$guardTrack($tag) < 0 && $sum < $maxColumnBytes / 16 && $guardBase($tag) + $sum + $guardSlack < $maxColumnBytes} {
        set guardPend($tag) $sum                                ;# the usual case: that is all there is to do
        return
    }
    guardWriteSlow $path $tag $props $values $add
}
proc ::mkitsql::db::guardWriteSlow {path tag props values add} {
    variable guardBase ; variable guardPend ; variable guardTrack ; variable guardPc ; variable guardPb
    variable maxColumnBytes ; variable guardSlack ; variable guardSmall
    set lens {}
    foreach v $values { lappend lens [expr {[string bytelength $v] + 1}] }
    set sub [expr {[string first ! $path] >= 0}]                ;# a subview of one row: its columns are small by construction
    if {$guardTrack($tag) < 0 && $guardPend($tag) + $add >= $maxColumnBytes / 16} { set guardTrack($tag) $guardPend($tag) }
    if {!$sub && $guardBase($tag) + $guardPend($tag) + $add + $guardSlack >= $maxColumnBytes} {
        foreach p $props n $lens { guardCheck $path $tag $p $n }
    }
    incr guardPend($tag) $add
    if {$sub || $guardTrack($tag) < 0} return
    foreach p $props n $lens {
        incr guardPc($path,$p) $n
        if {$n > $guardSmall + 1} { incr guardPb($path,$p) $n }
    }
}
# would `n` more bytes in column `prop` of `path` still fit?
proc ::mkitsql::db::guardCheck {path tag prop n} {
    variable guardPend ; variable guardTrack ; variable guardPc ; variable guardPb ; variable guardIn ; variable guardTy
    variable maxColumnBytes ; variable guardSlack ; variable guardSmall
    set key $path,$prop
    if {![info exists guardTy($key)]} {
        set type S
        foreach c [layout $path] { if {[lindex $c 0] eq $prop} { set type [lindex $c 1] } }
        set guardTy($key) $type
    }
    set type $guardTy($key)
    set rows [mk::view size $path]
    # what has been written since the last commit and may be in this column: counted per column, or - before tracking began - all of it
    if {$guardTrack($tag) >= 0} {
        set pend [expr {$guardTrack($tag) + ([info exists guardPc($key)] ? $guardPc($key) : 0)}]
    } else {
        set pend $guardPend($tag)
    }
    set why ""
    if {$type in {I F}} { set used [expr {($rows + 1) * 4}] ; set why "$rows rows of 4 bytes" } \
    elseif {$type in {L D}} { set used [expr {($rows + 1) * 8}] ; set why "$rows rows of 8 bytes" } \
    else {
        set inl [expr {$rows * ($guardSmall + 1)}]                    ;# no more than this can be small values that are already in the column ...
        if {$inl + $pend + $n + $guardSlack >= $maxColumnBytes} {     ;# ... and only when that might matter are they counted
            if {![info exists guardIn($key)]} {
                set total 0
                for {set i 0} {$i < $rows} {incr i} {
                    set len [mk::get $path!$i -size $prop]           ;# the size alone: a value is never fetched to be measured
                    if {$len <= $guardSmall} { incr total [expr {$len + 1}] }
                }
                if {$guardTrack($tag) == 0} {
                    # (counted per column from the start of the transaction) the pass also saw the small values written since the last commit,
                    # which `pend` counts as well
                    set small [expr {[info exists guardPc($key)] ? $guardPc($key) : 0}]
                    if {[info exists guardPb($key)]} { incr small -$guardPb($key) }
                    set total [expr {max(0, $total - $small)}]
                } elseif {$guardTrack($tag) < 0 && $guardPend($tag) == 0} {
                    set guardTrack($tag) 0                            ;# nothing written yet: from here on every write is counted per column
                }
                set guardIn($key) $total
            }
            set inl $guardIn($key)
        }
        set used [expr {$inl + $pend + $n}]
        set why "$inl bytes of small values that stay in it, $pend written since the last save"
    }
    if {$used + $guardSlack > $maxColumnBytes} {
        set view [lindex [split $path .] 1]
        return -code error -errorcode [list MKIT COLUMNFULL $path $prop] "Column $prop of $view would grow past the limit of one Metakit column (2 GiB less one byte): it would hold about $used bytes ($why).\n\nMetakit moves each value of more than 10,000 bytes into a place of its own when the database is saved, so SAVE (commit) now and try again. If the column is full of small values, split the table (by year, say) or keep large values outside the database. A database FILE can be larger than 2 GiB, one column of small values cannot."
    }
}
# The Metakit with 64-bit file positions answers an edit that would take ONE column past 2^31-1 bytes with an error (Mk4tcl: "a column would
# grow to N bytes, more than the limit ...") instead of ending the program (before its "size errors", commit 2e2e482, it ended the program).
# That edit was not made, but what it was part of may have been half done, so Metakit marks the storage: it can be looked at and rolled back, and
# every commit fails until it is.  The guard above stops the edits it knows about before they get that far.  `taint` remembers the mark so that a
# commit is refused at once (no commit record, no checksum removed) and rollback clears it.
namespace eval ::mkitsql::db { variable taint ; array set taint {} }
proc ::mkitsql::db::sizeFault {path err opts} {
    if {![string match "a column would grow to *" $err]} { return -options $opts $err }
    set tag [lindex [split $path .!] 0]
    markTaint $tag                                       ;# (each back end keeps the mark where its own commit looks)
    set view [lindex [split [lindex [split $path !] 0] .] 1]
    return -code error -errorcode [list MKIT COLUMNFULL $path ""] "An edit in '$tag' would make one column of '$view' larger than Metakit can hold (2 GiB less one byte). The edit was refused.\n\nAnything this statement had already changed is still pending, so the database cannot be saved now: ROLLBACK returns to the last saved state. A database FILE can be larger than 2 GiB, one column cannot: split the table (by year, say) or keep large values outside the database."
}
proc ::mkitsql::db::taintedError {tag} {
    return -code error -errorcode [list MKIT TAINTED] "'$tag' cannot be committed: an edit was refused because one column would have grown past the limit of a Metakit column (2 GiB less one byte), and what was changed before it cannot be told apart from what was not.\n\nROLLBACK discards the uncommitted changes and returns to the last committed state."
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
