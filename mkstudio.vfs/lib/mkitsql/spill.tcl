# spill.tcl -- bounded-memory building blocks for mkit-sql.
#
# Every blocking operator (sort, aggregate, distinct, join, window, set operation, and the
# data-changing statements) keeps at most ::mkitsql::memBytes of rows in memory and spills
# the rest to temporary files.  Rows travel through the engine in *chunks* (lists of tuples);
# a "sink" is a command prefix called with one chunk that returns 1 to say "stop sending".
#
#   spool    an append-only list of tuples that moves to a file when it gets big
#   sorter   external merge sort of records (sorted runs on disk, k-way merge)
#   reader   walks sorted records group by group (equal first element)
#
# Temporary files live in a PRIVATE folder that this process creates inside ::mkitsql::tempDir
# (mkitsql-<user>-<pid>-<random>, mode 0700, owned by the caller, never a symbolic link); every file is
# created exclusively with mode 0600.  They are removed at the end of every statement, successful or not,
# and folders left behind by a crashed process are removed by the next run (see cleanTemp).

namespace eval ::mkitsql {
    variable memBytes 33554432       ;# working-memory budget per blocking operator, ~32 MB (an estimate, see bytesOf)
    variable tempDir ""              ;# where spill files go ("" = TMPDIR, TEMP, TMP, /tmp, ...)
    variable spillSeq 0
    variable spillDir ""             ;# this process's private folder (made on first use)
    variable tempCleaned 0           ;# the stale-folder sweep runs once per process
    variable spillFiles {}
    variable spillChans {}
    variable spillN ; variable spillG ; variable spillEnd   ;# per channel: tuples written / read so far, trailer seen
    array set spillN {} ; array set spillG {} ; array set spillEnd {}
    variable sidSeq 0
    variable S
    array set S {}
}

proc ::mkitsql::newId {} { variable sidSeq ; return [incr sidSeq] }

# Estimated memory held by a chunk of tuples.  Tcl objects cost far more than their text: measured on
# real data, a narrow row of 43 characters takes ~700 bytes and a wide one ~4 bytes per character, so
# this charges 8 per character plus 150 per row.  It is deliberately a little pessimistic for wide rows.
proc ::mkitsql::bytesOf {chunk} { expr {8 * [string length [::mkitsql::rt::flat $chunk]] + 150 * [llength $chunk]} }

# 1 if the sink asked to stop; sinks may return "" or 0 to continue
proc ::mkitsql::emit {sink chunk} {
    if {![llength $chunk]} { return 0 }
    if {[{*}$sink $chunk] eq "1"} { return 1 }
    return 0
}
# send a long list to a sink in chunks of the standard size
proc ::mkitsql::emitAll {sink rows} {
    variable chunk
    set n [llength $rows]
    if {$n <= $chunk} { return [emit $sink $rows] }
    for {set i 0} {$i < $n} {incr i $chunk} {
        if {[emit $sink [lrange $rows $i [expr {$i + $chunk - 1}]]]} { return 1 }
    }
    return 0
}

# ---- temporary files -------------------------------------------------------
proc ::mkitsql::tmpDir {} {
    variable tempDir
    if {$tempDir ne ""} {
        if {![file isdirectory $tempDir] || ![file writable $tempDir]} {
            fail "The folder for temporary files, '$tempDir', does not exist or is not writable.  Set ::mkitsql::tempDir to a writable folder (or to \"\" to choose one automatically)"
        }
        return $tempDir
    }
    set cands {}
    foreach v {TMPDIR TEMP TMP} { if {[info exists ::env($v)]} { lappend cands $::env($v) } }
    lappend cands /tmp /var/tmp .
    foreach c $cands {
        if {$c ne "" && [file isdirectory $c] && [file writable $c]} { set tempDir $c ; return $c }
    }
    fail "No writable folder for temporary files.  Set ::mkitsql::tempDir"
}
# ---- the private folder ----------------------------------------------------------------------
proc ::mkitsql::randHex {n} {
    if {![catch {set h [open /dev/urandom rb] ; set b [read $h $n] ; close $h}] && [string length $b] == $n} {
        binary scan $b H* hex
        return $hex
    }
    # no /dev/urandom (Windows): mix what is available; the folder is created exclusively and is private anyway
    set hex ""
    while {[string length $hex] < 2 * $n} {
        append hex [format %08x [expr {(entier(rand() * 4294967296) ^ ([clock clicks -microseconds] & 0xffffffff) ^ ([pid] * 2654435761)) & 0xffffffff}]]
    }
    return [string range $hex 0 [expr {2 * $n - 1}]]
}
# The PID namespace this process lives in ("0" where unknown).  Containers can share a folder such as /tmp while
# each has its own pid numbering, so a pid in a folder name only means something to processes of the same namespace.
proc ::mkitsql::pidNs {} {
    if {[catch {::file readlink /proc/self/ns/pid} l] || ![regexp {\[(\d+)\]} $l -> n]} { return 0 }
    return $n
}
proc ::mkitsql::userTag {} {
    set u [expr {[info exists ::tcl_platform(user)] ? $::tcl_platform(user) : "user"}]
    regsub -all {[^A-Za-z0-9_]} $u _ u
    return [string range $u 0 20]
}
# Is a process alive?  (stale-lock and stale-folder detection)
proc ::mkitsql::pidAlive {pid} {
    if {![string is integer -strict $pid] || $pid <= 0} { return 0 }
    if {$pid == [pid]} { return 1 }
    if {$::tcl_platform(platform) eq "windows"} {
        if {[catch {exec tasklist /FI "PID eq $pid" /NH /FO CSV} out]} { return 0 }
        return [expr {[string first "\"$pid\"" $out] >= 0}]
    }
    if {[file isdirectory /proc/self]} {
        if {![file isdirectory /proc/$pid]} { return 0 }
        # a killed process that nobody has reaped yet (zombie) is dead
        if {![catch {set h [open /proc/$pid/stat r] ; set d [read $h] ; close $h}]} {
            if {[string index $d [expr {[string last ")" $d] + 2}]] eq "Z"} { return 0 }
        }
        return 1
    }
    # kill -0 says "not permitted" for a live process of another user: that process exists
    if {[catch {exec kill -0 $pid} msg]} { return [expr {[string match -nocase "*not permitted*" $msg] || [string match -nocase "*EPERM*" $msg]}] }
    return 1
}
# The folder for this process's spill files, created on first use.  Any trouble is reported, not ignored:
# a spill file in a folder somebody else could write to would be a security hole.
proc ::mkitsql::spillDir {} {
    variable spillDir
    if {$spillDir ne "" && [file isdirectory $spillDir]} { return $spillDir }
    set base [tmpDir]
    cleanTemp
    for {set try 0} {$try < 50} {incr try} {
        set d [file join $base mkitsql-[userTag]-[pid]-[pidNs]-[randHex 8]]
        if {![catch {file lstat $d x}]} continue            ;# exists (even as a link): pick another name
        if {[catch {file mkdir $d} msg]} { fail "Cannot create a folder for temporary files in '$base' ($msg).  Set ::mkitsql::tempDir to a writable folder" }
        if {$::tcl_platform(platform) ne "windows"} {
            if {[catch {file attributes $d -permissions u=rwx,go=} msg]} { catch {file delete $d} ; fail "Cannot restrict the temporary folder '$d' ($msg)" }
            if {[file type $d] ne "directory" || ![file owned $d]} { fail "The temporary folder '$d' is not ours; refusing to use it" }
            file attributes $d -permissions u=rwx,go=
            if {([file attributes $d -permissions] & 63) != 0} { fail "The temporary folder '$d' is not private; refusing to use it" }
        }
        set spillDir $d
        return $d
    }
    fail "Cannot find an unused name for the temporary folder in '$base'"
}
# Remove what crashed runs left in the temporary area: folders mkitsql-<user>-<pid>-<random> (and the
# mkitsql_<pid>_<n>.spill files of older versions) that belong to the caller, are real folders / files (never
# links), whose process no longer exists and that belong to this PID namespace.  A folder of a running process is never touched,
# however old.  Returns the count.
proc ::mkitsql::cleanTemp {{base ""}} {
    variable tempCleaned ; variable spillDir
    if {$base eq ""} {
        if {$tempCleaned} { return 0 }
        set tempCleaned 1
        if {[catch {tmpDir} base]} { return 0 }
    }
    set removed 0 ; set now [clock seconds]
    foreach p [glob -nocomplain -directory $base mkitsql-* mkitsql_*] {
        set tail [file tail $p]
        if {[catch {file lstat $p st}]} continue
        if {$st(type) ni {directory file}} continue                  ;# never touch links or specials
        if {![file owned $p]} continue
        set isDir [expr {$st(type) eq "directory"}]
        set ns [pidNs]
        if {$isDir && [regexp {^mkitsql-[A-Za-z0-9_]*-(\d+)-(\d+)-[0-9a-f]{16}$} $tail -> pid fns]} {
            # made by a process of another PID namespace (a container sharing this folder): its pid means nothing here, so
            # whether it is still running cannot be known - never touch it
            if {$fns != $ns} continue
        } elseif {$isDir && [regexp {^mkitsql-[A-Za-z0-9_]*-(\d+)-[0-9a-f]{16}$} $tail -> pid]} {
        } elseif {!$isDir && [regexp {^mkitsql_(\d+)_\d+\.spill$} $tail -> pid]} {
        } else continue
        if {$p eq $spillDir || $pid == [pid]} continue
        # a process that is still running owns its folder, however old it is (a long statement may hold spill files for hours)
        if {[pidAlive $pid]} continue
        if {$isDir} {
            # only if it holds nothing but our spill files
            set ok 1 ; set inside [glob -nocomplain -directory $p * .*]
            foreach f $inside {
                if {[file tail $f] in {. ..}} continue
                if {![regexp {^(\d+\.spill|verify_child\.tcl)$} [file tail $f]] || [catch {file lstat $f fs}] || $fs(type) ne "file"} { set ok 0 }
            }
            if {!$ok} continue
            foreach f $inside { if {[file tail $f] ni {. ..}} { catch {file delete $f} } }
            if {![catch {file delete $p}]} { incr removed }
        } else {
            if {![catch {file delete $p}]} { incr removed }
        }
    }
    return $removed
}
proc ::mkitsql::spillNewPath {} {
    variable spillFiles ; variable spillSeq
    set p [file join [spillDir] [format %06d [incr spillSeq]].spill]
    lappend spillFiles $p
    return $p
}
proc ::mkitsql::spillOpenW {path} {
    variable spillChans ; variable spillN
    # exclusive: fails if anything (a file, a link) is already there; private: 0600 = 384 decimal (Tcl 9 does not read 0600 as octal)
    if {[catch {open $path {WRONLY CREAT EXCL} 384} ch]} { fail "Cannot create a temporary file ($ch).  Set ::mkitsql::tempDir to a writable folder" }
    fconfigure $ch -translation lf -encoding utf-8 -buffering full -buffersize 131072 -eofchar {}
    lappend spillChans $ch
    set spillN($ch) 0
    return $ch
}
proc ::mkitsql::spillOpenR {path} {
    variable spillChans ; variable spillG ; variable spillEnd
    if {[catch {open $path r} ch]} { fail "Cannot read back a temporary file ($ch)" }
    fconfigure $ch -translation lf -encoding utf-8 -buffersize 131072 -eofchar {}
    lappend spillChans $ch
    set spillG($ch) 0 ; set spillEnd($ch) 0
    return $ch
}
# Closes a spill file.  A file being written gets its trailer line (`\E<number of tuples>`: data lines can never start with a
# backslash followed by E, because every backslash in the data is doubled) and the close is checked - a full disk shows up
# here, at the last buffered write, and must not be ignored.  A file being read must have shown its trailer.
proc ::mkitsql::spillClose {ch} {
    variable spillChans ; variable spillN ; variable spillG ; variable spillEnd
    set err ""
    if {[info exists spillN($ch)]} {
        if {[catch { puts $ch "\\E$spillN($ch)" ; close $ch } msg]} { set err "Writing a temporary file failed ($msg).  The disk may be full; set ::mkitsql::tempDir to a folder with more room" }
        unset spillN($ch)
    } else {
        catch {close $ch}
    }
    unset -nocomplain spillG($ch) spillEnd($ch)
    set i [lsearch -exact $spillChans $ch]
    if {$i >= 0} { set spillChans [lreplace $spillChans $i $i] }
    if {$err ne ""} { fail $err }
}
# close without caring about errors (cleanup after a failed statement)
proc ::mkitsql::spillAbandon {ch} { catch {spillClose $ch} }
# End of every statement (also after an error or a cancel): close and delete the spill files and drop
# all operator state, so a failed statement leaves nothing behind.
proc ::mkitsql::spillCleanup {} {
    variable spillFiles ; variable spillChans ; variable S ; variable spillN ; variable spillG ; variable spillEnd
    foreach ch $spillChans { catch {close $ch} }
    array unset spillN ; array unset spillG ; array unset spillEnd
    array set spillN {} ; array set spillG {} ; array set spillEnd {}
    foreach f $spillFiles { catch {file delete $f} }
    set spillFiles {} ; set spillChans {}
    variable spillDir
    if {$spillDir ne ""} {
        # the folder is ours and holds only spill files; remove it so nothing outlives the statement
        foreach f [glob -nocomplain -directory $spillDir *] { catch {file delete $f} }
        catch {file delete $spillDir}
        set spillDir ""
    }
    array unset S
    array set S {}
    catch {namespace delete ::mkitsql::agg}
}
# one tuple per line; backslash, newline and carriage return are escaped
proc ::mkitsql::spillWrite {ch rows} {
    variable spillN
    if {[catch {
        foreach t $rows { puts $ch [string map {\\ \\\\ \n \\n \r \\r} [::mkitsql::rt::sk $t]] }
        incr spillN($ch) [llength $rows]
    } msg]} { fail "Writing a temporary file failed ($msg).  The disk may be full; set ::mkitsql::tempDir to a folder with more room" }
}
proc ::mkitsql::spillUnesc {line} { return [string map {\\\\ \\ \\n \n \\r \r} $line] }
# read up to n tuples from an open channel
proc ::mkitsql::spillReadBlock {ch n} {
    variable spillG ; variable spillEnd
    set out {}
    if {$spillEnd($ch)} { return {} }
    while {$n > 0} {
        if {[catch {gets $ch line} got]} { fail "Reading a temporary file failed ($got)" }
        if {$got < 0} { fail "A temporary file ended early (the disk may be full, or something else removed or changed the file); the statement was stopped" }
        if {[string index $line 0] eq "\\" && [string index $line 1] eq "E"} {
            if {[string range $line 2 end] ne $spillG($ch)} { fail "A temporary file is damaged (it holds $spillG($ch) records, it should hold [string range $line 2 end]); the statement was stopped" }
            set spillEnd($ch) 1
            break
        }
        lappend out [string map {\\\\ \\ \\n \n \\r \r} $line]
        incr spillG($ch)
        incr n -1
    }
    return $out
}
# feed a file to a sink in chunks; returns 1 if the sink stopped
proc ::mkitsql::spillRead {path sink} {
    variable chunk
    set ch [spillOpenR $path]
    set stop 0
    while {1} {
        set blk [spillReadBlock $ch $chunk]
        if {![llength $blk]} break
        if {[emit $sink $blk]} { set stop 1 ; break }
    }
    spillClose $ch
    return $stop
}

# ---- spool: a list of tuples that spills to disk ---------------------------
proc ::mkitsql::spoolNew {} {
    variable S
    set i [newId]
    set S($i,mem) {} ; set S($i,bytes) 0 ; set S($i,path) "" ; set S($i,ch) "" ; set S($i,n) 0
    return $i
}
proc ::mkitsql::spoolAdd {i rows} {
    variable S ; variable memBytes
    incr S($i,n) [llength $rows]
    if {$S($i,ch) ne ""} { spillWrite $S($i,ch) $rows ; return }
    lappend S($i,mem) {*}$rows
    incr S($i,bytes) [bytesOf $rows]
    if {$S($i,bytes) > $memBytes} {
        set S($i,path) [spillNewPath]
        set S($i,ch) [spillOpenW $S($i,path)]
        spillWrite $S($i,ch) $S($i,mem)
        set S($i,mem) {}
    }
}
proc ::mkitsql::spoolSpilled {i} { variable S ; return [expr {$S($i,path) ne ""}] }
proc ::mkitsql::spoolCount {i} { variable S ; return $S($i,n) }
# make the spool readable (flush its file)
proc ::mkitsql::spoolSeal {i} {
    variable S
    if {$S($i,ch) ne ""} { spillClose $S($i,ch) ; set S($i,ch) "" }
}
# feed everything to a sink in chunks; returns 1 if the sink stopped
proc ::mkitsql::spoolEach {i sink} {
    variable S
    spoolSeal $i
    if {$S($i,path) ne ""} { return [spillRead $S($i,path) $sink] }
    return [emitAll $sink $S($i,mem)]
}
# all tuples as one list (only for spools known to be small)
proc ::mkitsql::spoolList {i} {
    variable S
    spoolSeal $i
    if {$S($i,path) eq ""} { return $S($i,mem) }
    set ch [spillOpenR $S($i,path)]
    set out {}
    while {[llength [set blk [spillReadBlock $ch 5000]]]} { lappend out {*}$blk }
    spillClose $ch
    return $out
}
proc ::mkitsql::spoolFree {i} {
    variable S
    if {[info exists S($i,ch)] && $S($i,ch) ne ""} { spillAbandon $S($i,ch) }
    if {[info exists S($i,path)] && $S($i,path) ne ""} { catch {file delete $S($i,path)} }
    array unset S $i,*
}

# ---- sorter: external merge sort -------------------------------------------
# Records are lists whose first nk elements are the sort keys; spec is the list of
# {kind idx dir nulls type} entries that ::mkitsql::sortRecs understands.
proc ::mkitsql::sorterNew {spec} {
    variable S
    set i [newId]
    set S($i,spec) $spec ; set S($i,buf) {} ; set S($i,bytes) 0 ; set S($i,runs) {} ; set S($i,n) 0 ; set S($i,recBytes) 0
    return $i
}
proc ::mkitsql::sorterAdd {i rows} {
    variable S ; variable memBytes
    incr S($i,n) [llength $rows]
    lappend S($i,buf) {*}$rows
    incr S($i,bytes) [bytesOf $rows]
    if {$S($i,bytes) > $memBytes} { sorterSpill $i }
}
proc ::mkitsql::sorterSpill {i} {
    variable S
    if {![llength $S($i,buf)]} return
    set S($i,recBytes) [expr {max(1, $S($i,bytes) / [llength $S($i,buf)])}]
    set recs [sortRecs $S($i,buf) $S($i,spec)]
    set path [spillNewPath]
    set ch [spillOpenW $path]
    spillWrite $ch $recs
    spillClose $ch
    lappend S($i,runs) $path
    set S($i,buf) {} ; set S($i,bytes) 0
}
proc ::mkitsql::sorterSpilled {i} { variable S ; return [expr {[llength $S($i,runs)] > 0}] }
# emit every record in order; returns 1 if the sink stopped
proc ::mkitsql::sorterDrain {i sink} {
    variable S
    if {![llength $S($i,runs)]} {
        set recs [sortRecs $S($i,buf) $S($i,spec)]
        set S($i,buf) {}
        return [emitAll $sink $recs]
    }
    sorterSpill $i
    return [mergeRuns $S($i,runs) $S($i,spec) $S($i,recBytes) $sink]
}
proc ::mkitsql::sorterFree {i} {
    variable S
    foreach r $S($i,runs) { catch {file delete $r} }
    array unset S $i,*
}

# k-way merge of sorted run files using only the native sort.
#   Each round reads one block from every run that has no unconsumed "boundary" record,
#   sorts the pool together with what was carried over, and releases everything up to the
#   smallest boundary (the last record of some run's block): nothing unread can sort before it.
#   Records carry two trailing tags: the run number and a boundary mark.
proc ::mkitsql::mergeRuns {runs spec recBytes sink} {
    variable memBytes ; variable chunk
    set k [llength $runs]
    set blk [expr {max(1, $memBytes / ($recBytes * 2 * $k + 1))}]
    set chs {} ; set eof {} ; set outstanding {}
    foreach r $runs { lappend chs [spillOpenR $r] ; lappend eof 0 ; lappend outstanding 0 }
    set carry {}
    set stop 0
    while {1} {
        set fresh {}
        for {set r 0} {$r < $k} {incr r} {
            if {[lindex $eof $r] || [lindex $outstanding $r]} continue
            set block [spillReadBlock [lindex $chs $r] $blk]
            if {[llength $block] < $blk} { lset eof $r 1 }
            if {![llength $block]} continue
            set last [expr {[llength $block] - 1}]
            set i 0
            foreach rec $block {
                lappend rec $r [expr {$i == $last && ![lindex $eof $r] ? 1 : 0}]
                lappend fresh $rec
                incr i
            }
            if {![lindex $eof $r]} { lset outstanding $r 1 }
        }
        set pool [concat $carry $fresh]
        if {![llength $pool]} break
        set sorted [sortRecs $pool $spec]
        set idx [lsearch -index end -exact $sorted 1]
        if {$idx < 0} {
            set release $sorted ; set carry {}
        } else {
            set release [lrange $sorted 0 $idx]
            set carry [lrange $sorted [expr {$idx + 1}] end]
            lset outstanding [lindex $sorted $idx end-1] 0
        }
        set out {}
        foreach rec $release { lappend out [lrange $rec 0 end-2] }
        if {[emitAll $sink $out]} { set stop 1 ; break }
        if {$idx < 0} break
    }
    foreach ch $chs { spillClose $ch }
    return $stop
}

# ---- reader: groups of records with an equal first element -------------------
# src is {list <records>} or {file <path>}; the first element of every record is a key string and
# the records are sorted by it.
proc ::mkitsql::readerNew {src} {
    variable S
    set i [newId]
    set S($i,kind) [lindex $src 0] ; set S($i,have) 0 ; set S($i,done) 0 ; set S($i,peek) ""
    if {$S($i,kind) eq "list"} {
        set S($i,recs) [lindex $src 1] ; set S($i,pos) 0
    } else {
        set S($i,ch) [spillOpenR [lindex $src 1]] ; set S($i,buf) {} ; set S($i,pos) 0
    }
    return $i
}
proc ::mkitsql::readerFill {i} {
    variable S
    if {$S($i,have) || $S($i,done)} return
    if {$S($i,kind) eq "list"} {
        if {$S($i,pos) >= [llength $S($i,recs)]} { set S($i,done) 1 ; return }
        set S($i,peek) [lindex $S($i,recs) $S($i,pos)] ; incr S($i,pos)
    } else {
        if {$S($i,pos) >= [llength $S($i,buf)]} {
            set S($i,buf) [spillReadBlock $S($i,ch) 2000] ; set S($i,pos) 0
            if {![llength $S($i,buf)]} { set S($i,done) 1 ; spillClose $S($i,ch) ; return }
        }
        set S($i,peek) [lindex $S($i,buf) $S($i,pos)] ; incr S($i,pos)
    }
    set S($i,have) 1
}
# next group as {key {records...}}, or {} at the end
proc ::mkitsql::readerGroup {i} {
    variable S
    readerFill $i
    if {!$S($i,have)} { return {} }
    set first $S($i,peek) ; set key [lindex $first 0] ; set recs [list $first]
    set S($i,have) 0
    while 1 {
        readerFill $i
        if {!$S($i,have) || [lindex $S($i,peek) 0] ne $key} break
        lappend recs $S($i,peek) ; set S($i,have) 0
    }
    return [list $key $recs]
}
proc ::mkitsql::readerFree {i} {
    variable S
    if {[info exists S($i,ch)] && !$S($i,done)} { spillClose $S($i,ch) }
    array unset S $i,*
}

# sorter -> reader.  The sorted records of a spilled sorter are merged into one file first.
proc ::mkitsql::sorterReader {i} {
    variable S
    if {![llength $S($i,runs)]} {
        set recs [sortRecs $S($i,buf) $S($i,spec)] ; set S($i,buf) {}
        return [readerNew [list list $recs]]
    }
    set path [spillNewPath]
    set ch [spillOpenW $path]
    sorterDrain $i [list ::mkitsql::spillSink $ch]
    spillClose $ch
    return [readerNew [list file $path]]
}
proc ::mkitsql::spillSink {ch rows} { spillWrite $ch $rows ; return 0 }

# the key string used to group rows: the row's list form
proc ::mkitsql::keyStr {l} { return $l }
