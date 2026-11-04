# dbcheck.tcl -- is this file an intact Metakit database?  (used by both storage layers before opening)
#
# Mk4tcl will "open" ANY file: a truncated database, one with a damaged header or footer, or a text file all look
# like a database with no tables - and writing into it and committing would REPLACE the original.  A committed Metakit
# file has a fixed frame, which is cheap to verify without reading the data:
#
#   header  (8 bytes)  "JL" (or "LJ" for the other byte order), 0x1A, 0x00, then the file's size as one 32-bit word
#   footer (16 bytes)  word 0x80000000, the offset of the footer itself (= size - 16), word 0x80<len>, the offset of the table
#
# What this cannot see: bytes flipped inside the data (Metakit stores no checksums).  Files that do not start with the
# signature (a starkit / starpack carries its database at the end) are not judged here: the opener refuses them only if
# they hold no tables at all.
namespace eval ::mkitsql {}

# "" if the file looks intact (or is empty/new), otherwise the reason it is not
proc ::mkitsql::dbProblem {path} {
    if {![file exists $path]} { return "" }
    set size [file size $path]
    if {$size == 0} { return "" }
    if {[catch {
        set h [open $path rb]
        set head [read $h 8]
        seek $h [expr {$size > 16 ? -16 : 0}] end
        set tail [read $h 16]
        close $h
    } msg]} { return "it cannot be read ($msg)" }
    set sig [string range $head 0 1]
    if {$sig ne "JL" && $sig ne "LJ"} { return "" }              ;# not a standalone database file: judged after opening
    if {[string range $head 2 3] ne "\x1a\x00"} { return "its header is damaged" }
    if {$size < 24} { return "it is too short to be a Metakit database ($size bytes)" }
    set fmt [expr {$sig eq "JL" ? "I" : "i"}]                    ;# JL: words are big-endian, LJ: little-endian
    binary scan $head x4$fmt hdrSize
    binary scan $tail $fmt$fmt$fmt$fmt w0 footPos w2 tocPos
    set hdrSize [expr {$hdrSize & 0xFFFFFFFF}] ; set footPos [expr {$footPos & 0xFFFFFFFF}] ; set tocPos [expr {$tocPos & 0xFFFFFFFF}]
    set flag0 [expr {($w0 >> 24) & 0xFF}] ; set flag2 [expr {($w2 >> 24) & 0xFF}]
    if {$hdrSize > $size} { return "it is truncated: the header says $hdrSize bytes but the file has only $size" }
    if {$hdrSize < $size} { return "the header says $hdrSize bytes but the file has $size (it was cut or extended by another program, or a commit was interrupted - opening it for writing undoes that)" }
    if {($w0 & 0xFFFFFFFF) != 0x80000000 || $flag2 != 0x80} { return "its footer is damaged" }
    if {$footPos != $size - 16} { return "its footer is not where the header says it should be" }
    if {$tocPos >= $footPos} { return "its table of contents lies outside the file" }
    return ""
}
# raise MKIT DAMAGED unless the file is intact
proc ::mkitsql::dbRequireIntact {path} {
    set why [dbProblem $path]
    if {$why ne ""} {
        return -code error -errorcode [list MKIT DAMAGED $why] \
            "This file does not look like an intact Metakit database ($why):\n$path\nOpening it would show an empty database, and saving would overwrite it. Open a backup, or pass -unchecked to open it anyway."
    }
}
# after a successful open: a non-empty file without the Metakit signature and with no tables is some other kind of file
proc ::mkitsql::dbSignatureOk {path hasViews} {
    if {$hasViews || ![file exists $path] || [file size $path] == 0} { return 1 }
    if {[catch {set h [open $path rb] ; set sig [read $h 2] ; close $h}]} { return 1 }
    return [expr {$sig eq "JL" || $sig eq "LJ"}]
}

# ---- verifying an UNTRUSTED file in a throw-away process ---------------------------------------------------------
# The frame check above cannot see damage inside the data, and Metakit does not either: a few changed bytes make it
# crash (segfault) or loop forever, and neither can be caught in Tcl.  verifyFile therefore reads the whole file in a
# separate process (verify_child.tcl) with a time limit.  If that process survives, the file can be read safely; if not,
# the caller is told, and its own process is unharmed.  It costs a full read of the file, so it is opt-in:
#     ::mkitsql::db::openFile untrusted.mk -verify
# The helper is started with ::mkitsql::verifyInterp (default: the running tclsh / tclkit).  An application that is
# itself a packed executable must set it to a plain Tcl shell that has Mk4tcl.
namespace eval ::mkitsql {
    variable verifyInterp ""        ;# "" = the running interpreter, if it is a plain Tcl shell
    variable verifyTimeout 60       ;# seconds
}
# "" if the file was read completely by the helper, else the reason
proc ::mkitsql::verifyProblem {path {timeout ""}} {
    set rc [catch {verifyProblem1 $path $timeout} res opts]
    spillCleanup                                       ;# removes the private copy of the helper script, if one was made
    return -options $opts $res
}
proc ::mkitsql::verifyProblem1 {path timeout} {
    variable verifyInterp ; variable verifyTimeout ; variable dir
    if {$timeout eq ""} { set timeout $verifyTimeout }
    set exe $verifyInterp
    if {$exe eq ""} {
        set exe [info nameofexecutable]
        if {![regexp {^(tclsh|wish|tclkit|tclkitsh|tclkit-|tclsh8|wish8)} [file tail $exe]]} {
            fail "Cannot verify the file in a separate process: the running program ([file tail $exe]) is not a plain Tcl shell. Set ::mkitsql::verifyInterp to a tclsh or tclkit that has Mk4tcl."
        }
    }
    set script [file join $dir verify_child.tcl]
    set copy ""
    if {[lindex [file system $script] 0] ne "native"} {
        # inside a packed executable's virtual file system another process cannot read it: use a private copy
        set copy [file join [spillDir] verify_child.tcl]
        file copy -force $script $copy ; set script $copy
    }
    if {[catch {open [list | $exe $script $path 2>@1] r} ch]} { return "the verifier could not be started ($ch)" }
    fconfigure $ch -blocking 0 -buffering line
    set pid [pid $ch] ; set out "" ; set t0 [clock milliseconds] ; set eof 0
    while {!$eof} {
        set n [gets $ch line]
        if {$n >= 0} { append out $line "\n" } elseif {[eof $ch]} { set eof 1 } else {
            if {([clock milliseconds] - $t0) > $timeout * 1000} {
                catch {if {$::tcl_platform(platform) eq "windows"} {exec taskkill /F /PID $pid} else {exec kill -9 $pid}}
                catch {close $ch}
                return "reading it did not finish within $timeout seconds (it loops forever or is huge)"
            }
            after 10
        }
    }
    fconfigure $ch -blocking 1
    set rc [catch {close $ch} cmsg copts]
    set status ""
    if {$rc} { catch { set status [lindex [dict get $copts -errorcode] 0] } }
    if {[regexp {(^|\n)OK \d+ \d+\n} $out]} { return "" }
    if {[regexp {ERR ([^\n]*)} $out -> why]} { return "reading it failed: $why" }
    if {$status eq "CHILDKILLED" || $status eq "CHILDSTATUS"} { return "reading it crashed the helper process (Metakit trusted damaged data): [string trim [string range $cmsg 0 120]]" }
    return "the verifier produced no result ([string trim [string range $out 0 120]])"
}
proc ::mkitsql::dbVerify {path} {
    set why [verifyProblem $path]
    if {$why ne ""} {
        return -code error -errorcode [list MKIT DAMAGED $why] \
            "This file failed verification ($why):\n$path\nIt is damaged; opening it directly could crash this program."
    }
}

# ---- Metakit cannot change a column's type under the same name ------------------------------------------------------
# Found by tests/differential/features.py on real Metakit: once a view has had a column "x" of one type, giving that view a
# column "x" of ANOTHER type in the same open file does not work - the old storage is kept, writes fail ("expected integer
# but got ...") or silently store 4 bytes of the text, reads return 0, and closing the file can hang.  This happens after
#     DROP TABLE t; CREATE TABLE t (x TEXT)          when t had  x INT
#     ALTER TABLE t DROP COLUMN y; ... ADD COLUMN y <other type>
# The storage layers remember the type each (table, column) has had since the file was opened, and refuse - with a message
# that says what to do - a layout that would change one.  When nothing is pending (nothing to lose) the standalone layer
# first reopens the file, which resets Metakit's memory of types, and carries on.
namespace eval ::mkitsql {
    variable typeSeen
    array set typeSeen {}
}
proc ::mkitsql::typeRecord {tag view layout} {
    variable typeSeen
    foreach c $layout { set typeSeen([list $tag $view [lindex $c 0]]) [lindex $c 1] }
}
proc ::mkitsql::typeForget {tag} { variable typeSeen ; array unset typeSeen [list $tag *] }
# the first column whose type would change: {column old new} or ""
proc ::mkitsql::typeConflict {tag view layout} {
    variable typeSeen
    foreach c $layout {
        set k [list $tag $view [lindex $c 0]]
        if {[info exists typeSeen($k)] && $typeSeen($k) ne [lindex $c 1]} { return [list [lindex $c 0] $typeSeen($k) [lindex $c 1]] }
    }
    return ""
}
proc ::mkitsql::typeWords {l} { return [dict get {S text I integer L bigint F float D double B blob V table} $l] }
proc ::mkitsql::typeConflictError {view conflict} {
    lassign $conflict col old new
    return -code error -errorcode [list MKIT TYPECONFLICT $view $col $old $new] \
        "Column '$col' of '$view' has been [typeWords $old] in this open file and cannot become [typeWords $new] under the same name: Metakit keeps the old storage and would corrupt the data. COMMIT, then close and reopen the file (MK Studio: reopen it) and repeat; or use a different column name; or copy the data with CREATE TABLE ... AS SELECT CAST(...)."
}
