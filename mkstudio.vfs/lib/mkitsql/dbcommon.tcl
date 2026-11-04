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
# One column of a view (all its values together) is limited to 2^31-1 bytes whatever the size of the file, and Metakit ENDS THE PROGRAM
# when an edit grows a column past it (there is no way to report an error from the middle of an edit).  With the 2 GiB file limit gone
# nothing else would stop a big table first, so before a row is appended or a cell changed the column is checked.  A column is never
# larger than the file plus what has been written since the last commit, so the check costs nothing until that sum nears the limit; then
# the size of the column is counted once (fixed-width types: rows x width; text and blobs: a pass over the column) and kept up to date
# for the rest of the session (deletes are not subtracted: the count only errs on the safe side).
namespace eval ::mkitsql::db {
    variable guardBase ; variable guardPend ; variable guardCol ; variable guardSlack 4194304
    array set guardBase {} ; array set guardPend {} ; array set guardCol {}
}
# the handle `tag` was opened, committed, rolled back or restructured: size of the file now, nothing pending
proc ::mkitsql::db::guardReset {tag {forget 0}} {
    variable guardBase ; variable guardPend ; variable guardCol
    if {![wideCapable]} return
    set p [expr {[catch {path $tag} x] ? "" : $x}]
    set guardBase($tag) [expr {$p ne "" && [::file exists $p] ? [::file size $p] : 0}]
    set guardPend($tag) 0
    if {$forget} { array unset guardCol [list $tag *] }
}
proc ::mkitsql::db::guardForget {tag} {
    variable guardBase ; variable guardPend ; variable guardCol
    unset -nocomplain guardBase($tag) guardPend($tag)
    array unset guardCol [list $tag *]
}
# `path` is tag.view; `props` the columns about to receive `values`
proc ::mkitsql::db::guardWrite {path props values} {
    variable guardBase ; variable guardPend ; variable guardCol ; variable maxColumnBytes ; variable guardSlack
    set tag [lindex [split $path .] 0]
    if {![info exists guardBase($tag)]} { guardReset $tag }
    set add 0
    foreach v $values { incr add [expr {[string bytelength $v] + 1}] }
    incr guardPend($tag) $add
    if {$guardBase($tag) + $guardPend($tag) + $guardSlack < $maxColumnBytes} return
    if {[string first ! $path] >= 0} return                   ;# a subview of one row: its columns are small by construction
    foreach p $props v $values { guardColumn $path $tag $p [expr {[string bytelength $v] + 1}] }
}
proc ::mkitsql::db::guardColumn {path tag prop add} {
    variable guardCol ; variable maxColumnBytes ; variable guardSlack
    set key [list $tag $path $prop]
    if {![info exists guardCol($key)]} {
        set type S
        foreach c [layout $path] { if {[lindex $c 0] eq $prop} { set type [lindex $c 1] } }
        set rows [mk::view size $path]
        switch -- $type {
            I - F { set total [expr {$rows * 4}] }
            L - D { set total [expr {$rows * 8}] }
            default { set total 0 ; for {set i 0} {$i < $rows} {incr i} { incr total [expr {[string bytelength [mk::get $path!$i $prop]] + 1}] } }
        }
        set guardCol($key) [list $total $type]
    }
    lassign $guardCol($key) total type
    if {$type in {I F}} { set add 4 } elseif {$type in {L D}} { set add 8 }
    if {$total + $add + $guardSlack > $maxColumnBytes} {
        return -code error -errorcode [list MKIT COLUMNFULL $path $prop] "Column $prop of [lindex [split $path .] 1] would grow past the limit of one Metakit column (2 GiB less one byte; $total bytes are used): a database FILE can be larger, one column cannot. Split the table (by year, say) or keep large values outside the database."
    }
    set guardCol($key) [list [expr {$total + $add}] $type]
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
