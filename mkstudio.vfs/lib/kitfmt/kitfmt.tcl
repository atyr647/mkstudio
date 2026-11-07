# kitfmt.tcl -- the reference reader for Ribbon kit files (docs/KIT-FORMAT.md, format 1.0).
#
#   package require kitfmt          (needs Mk4tcl; zlib for deflate/classic data)
#
#   kitfmt probe   path                  is it a kit?  Reads the frame and the seal, never Metakit.
#   kitfmt open    path ?-force 0|1? ?-signed 0|1?   -> handle
#   kitfmt info    h                     format, kind, identity, root, seal, signature, store frame
#   kitfmt manifest h                    fields, needs, provides, perms, entries, effects
#   kitfmt list    h ?dir?               the entries directly in dir ("" = the root), sorted
#   kitfmt walk    h                     every entry, sorted
#   kitfmt stat    h path                type size mode date codec csize chunks stored link
#   kitfmt chunks  h path                {index stored-size sha256} for each chunk of a file
#   kitfmt read    h path ?offset? ?length?   bytes, each chunk checked against its hash first
#   kitfmt extract h path destdir ?-progress cmd?   file, link or folder ("" = everything) into destdir
#   kitfmt verify  h ?-progress cmd? ?-paths list?   every chunk, the image, the header, the root, the signature
#   kitfmt image   h                     the embedded image of a system kit ("" if none)
#   kitfmt close   h
#   kitfmt configure ?-option value ...?    -hash -helper -keys -verifier (see below)
#
# Rules this reader keeps (KIT-FORMAT.md section 11): the frame and the seal are read before
# Metakit sees the file; the file is opened read-only and nothing is ever written next to it; no
# payload value is fetched whole without its size being checked first; a chunk whose hash does
# not match is an error, never data; the limits of section 10 are enforced.
#
# Errors carry -errorcode {KITFMT <CODE> ...}: NOTKIT TRUNCATED SEAL VERSION FEATURE STRUCTURE
# LIMIT ROOT STATEMENT HASH CODEC NOENT TYPE EXISTS PATH SIGNATURE CONFIG CANCELLED.
#
# Tcl 8.5 to 9 compatible, ASCII only, no command of the package shadows a Tcl command.

package require Tcl 8.5-10

namespace eval ::kitfmt {
    variable version 1.0.0
    variable dir [file dirname [file normalize [info script]]]
    variable formatMajor 1
    variable formatMinor 0
    # features this reader knows by name, and the subset it can also decode
    variable knownFeatures {codec-zstd}
    variable decodable {}
    variable seq 0
    variable H            ;# per-handle state, H(<handle>,<field>)
    array set H {}
    variable cfg
    array set cfg {-hash auto -helper "" -keys {} -verifier ::kitfmt::MinisignVerify}
    variable backend ""   ;# the hash backend in use, decided on first use
    variable helperChan ""
    # limits (section 10)
    variable L
    array set L {
        entries 1000000  depth 64  name 255  path 4096  link 4095
        rows 10000  value 65536  classic 16777216  chunkMin 4096  chunkMax 1048576
        fileMax 1099511627776  segMin 65536  segMax 16777216  pad 65536  sealMax 65536
    }
}
source [file join $::kitfmt::dir sha256.tcl]

namespace eval ::kitfmt {
    namespace ensemble create -command ::kitfmt -map {
        probe ::kitfmt::Probe  open ::kitfmt::Open  close ::kitfmt::Close  info ::kitfmt::Info
        manifest ::kitfmt::Manifest  list ::kitfmt::List  walk ::kitfmt::Walk  stat ::kitfmt::Stat
        read ::kitfmt::Read  extract ::kitfmt::Extract  verify ::kitfmt::Verify  image ::kitfmt::Image
        configure ::kitfmt::Configure  hash ::kitfmt::Hash  index ::kitfmt::IndexText  chunks ::kitfmt::Chunks
    }
}

proc ::kitfmt::Fail {code msg args} {
    return -code error -errorcode [concat [list KITFMT $code] $args] $msg
}

# ============================================================================
#  Configuration
# ============================================================================
#   -hash auto|helper|tcllib|tool|tcl   which SHA-256 implementation (auto: the fastest one present)
#   -helper path                        kithelper to use (default: $KITFMT_HELPER, helper/kithelper here, PATH)
#   -keys {pubkey ...}                  trusted minisign public keys (the base64 line), for the signature state
#   -verifier cmdprefix                 called as {*}cmd statement signature pubkey -> 1 valid / 0 invalid
proc ::kitfmt::Configure {args} {
    variable cfg ; variable backend
    if {![llength $args]} { return [array get cfg] }
    if {[llength $args] == 1} {
        if {![info exists cfg([lindex $args 0])]} { Fail CONFIG "unknown option [lindex $args 0]" }
        return $cfg([lindex $args 0])
    }
    if {[llength $args] % 2} { Fail CONFIG "configure takes option value pairs" }
    foreach {k v} $args {
        if {![info exists cfg($k)]} { Fail CONFIG "unknown option $k: [join [lsort [array names cfg]] {, }]" }
        if {$k eq "-hash" && [lsearch -exact {auto helper tcllib tool tcl} $v] < 0} { Fail CONFIG "-hash must be auto, helper, tcllib, tool or tcl" }
        set cfg($k) $v
        if {$k eq "-hash" || $k eq "-helper"} { ResetHash }
    }
    return ""
}

# ============================================================================
#  Hashing.  SHA-256 everywhere (section 6).  Backends, fastest first:
#    helper  kithelper as a coprocess: one process for all hashes (~300 MB/s, no library)
#    tcllib  tcllib's sha256, only when it runs accelerated (tcllibc / Trf / cryptkit)
#    tool    sha256sum (coreutils) or shasum -a 256, one process per batch of chunks
#    tcl     sha256.tcl in this package (~0.7 MB/s): always there
# ============================================================================
proc ::kitfmt::ResetHash {} {
    variable backend ; variable helperChan
    if {$helperChan ne ""} { catch {close $helperChan} }
    set helperChan "" ; set backend ""
}

proc ::kitfmt::HelperPath {} {
    variable cfg ; variable dir
    if {$cfg(-helper) ne ""} { return $cfg(-helper) }
    if {[info exists ::env(KITFMT_HELPER)] && $::env(KITFMT_HELPER) ne ""} { return $::env(KITFMT_HELPER) }
    set p [file join $dir helper kithelper]
    if {[file executable $p] && [file isfile $p]} { return $p }
    set p [auto_execok kithelper]
    if {$p ne ""} { return [lindex $p 0] }
    return ""
}

proc ::kitfmt::StartHelper {} {
    variable helperChan
    set exe [HelperPath]
    if {$exe eq ""} { return 0 }
    if {[catch {
        set ch [open |[list $exe sha256] r+]
        fconfigure $ch -translation binary -buffering full
        puts -nonewline $ch [binary format I 3]abc
        flush $ch
        set got [gets $ch]
    }]} { catch {close $ch} ; return 0 }
    if {$got ne "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"} { catch {close $ch} ; return 0 }
    set helperChan $ch
    return 1
}

proc ::kitfmt::ToolCmd {} {
    foreach c {{sha256sum} {shasum -a 256}} {
        if {[auto_execok [lindex $c 0]] ne ""} { return $c }
    }
    return ""
}

proc ::kitfmt::TcllibAccel {} {
    if {[catch {package require sha256}]} { return 0 }
    if {![info exists ::sha2::accel]} { return 0 }
    foreach k [array names ::sha2::accel] { if {$::sha2::accel($k)} { return 1 } }
    return 0
}

proc ::kitfmt::HashBackend {} {
    variable backend ; variable cfg
    if {$backend ne ""} { return $backend }
    set want $cfg(-hash)
    if {$want eq "auto" && [info exists ::env(KITFMT_HASH)] && $::env(KITFMT_HASH) ne ""} { set want $::env(KITFMT_HASH) }
    switch -- $want {
        helper { if {![StartHelper]} { Fail CONFIG "the kithelper hash backend was asked for, but no working kithelper was found" } ; set backend helper }
        tcllib { if {![TcllibAccel]} { Fail CONFIG "tcllib's sha256 is not accelerated here" } ; set backend tcllib }
        tool   { if {[ToolCmd] eq ""} { Fail CONFIG "neither sha256sum nor shasum is on PATH" } ; set backend tool }
        tcl    { set backend tcl }
        default {
            if {[StartHelper]} { set backend helper } elseif {[TcllibAccel]} { set backend tcllib } \
            elseif {[ToolCmd] ne ""} { set backend tool } else { set backend tcl }
        }
    }
    return $backend
}

# hex SHA-256 of one byte string
proc ::kitfmt::Hash {data} { return [lindex [HashMany [list $data]] 0] }

# hex SHA-256 of each byte string in the list, in order
proc ::kitfmt::HashMany {items} {
    variable helperChan
    set out {}
    switch -- [HashBackend] {
        helper {
            foreach d $items {
                if {[catch {
                    puts -nonewline $helperChan [binary format I [string length $d]]
                    puts -nonewline $helperChan $d
                    flush $helperChan
                    set hx [gets $helperChan]
                }] || ![regexp {^[0-9a-f]{64}$} $hx]} {
                    # the helper died: carry on with the next backend for the rest of the process
                    ResetHash
                    variable backend
                    set backend [expr {[TcllibAccel] ? "tcllib" : ([ToolCmd] ne "" ? "tool" : "tcl")}]
                    return [concat $out [HashMany [lrange $items [llength $out] end]]]
                }
                lappend out $hx
            }
        }
        tcllib { foreach d $items { lappend out [::sha2::sha256 -hex -- $d] } }
        tool {
            set tmp [TempDir]
            set files {} ; set i 0
            set rc [catch {
                foreach d $items {
                    set f [file join $tmp c[incr i]]
                    set ch [open $f {WRONLY CREAT EXCL}]
                    fconfigure $ch -translation binary
                    puts -nonewline $ch $d
                    close $ch
                    lappend files $f
                }
                set res [exec {*}[ToolCmd] -- {*}$files]
            } err opts]
            catch {file delete -force $tmp}
            if {$rc} { return -options $opts $err }
            foreach line [split [string trim $res] \n] {
                if {![regexp {^\\?([0-9a-f]{64}) } $line -> hx]} { Fail CONFIG "unexpected output from [ToolCmd]: $line" }
                lappend out $hx
            }
            if {[llength $out] != [llength $items]} { Fail CONFIG "[ToolCmd] returned [llength $out] hashes for [llength $items] inputs" }
        }
        tcl { foreach d $items { lappend out [::kitfmt::sha256::hex $d] } }
    }
    return $out
}

# A private directory for the few files the external tools need (sha256sum, minisign).
# Never next to the kit; created fresh, owned by us, mode 0700; the caller deletes it.
proc ::kitfmt::TempDir {} {
    set base /tmp
    foreach v {TMPDIR TEMP TMP} {
        if {[info exists ::env($v)] && [file isdirectory $::env($v)]} { set base $::env($v) ; break }
    }
    for {set n 0} {$n < 20} {incr n} {
        set d [file join $base [format "kitfmt-%d-%08x%08x" [pid] [expr {int(rand() * 4294967295.0)}] [expr {[clock clicks] & 0xffffffff}]]]
        if {[file exists $d]} continue
        file mkdir $d
        if {[file type $d] ne "directory" || ![file owned $d]} continue
        if {$::tcl_platform(platform) eq "unix"} { file attributes $d -permissions 448 }
        if {[llength [glob -nocomplain -directory $d *]]} continue
        return $d
    }
    Fail CONFIG "could not create a private temporary directory under $base"
}

# ============================================================================
#  The frame: Metakit's tails, the seal, the header.  No Metakit involved.
# ============================================================================
proc ::kitfmt::ReadAt {path off len} {
    set ch [open $path rb]
    set rc [catch {seek $ch $off ; read $ch $len} data opts]
    close $ch
    if {$rc} { return -options $opts $data }
    return $data
}

# unsigned byte values (binary scan's "u" flag is Tcl 8.6 only)
proc ::kitfmt::Bytes {s} {
    binary scan $s c* v
    set out {}
    foreach x $v { lappend out [expr {$x & 0xff}] }
    return $out
}

proc ::kitfmt::U32 {bytes off} {
    binary scan $bytes @${off}I v
    return [expr {$v & 0xffffffff}]
}

# Where the Metakit store of a file starts and ends, from its last 16 (24) bytes.
# Returns {start end wide} or raises NOTKIT / TRUNCATED.
proc ::kitfmt::StoreFrame {path} {
    if {![file isfile $path]} { Fail NOTKIT "$path is not a regular file" }
    set size [file size $path]
    if {$size < 48} { Fail TRUNCATED "$path is too short ($size bytes) to hold a Metakit store" }
    set tail [ReadAt $path [expr {$size - 24}] 24]
    set b [Bytes $tail]
    # standard tails: skip 80 00 00 00 <skip:32>, commit 80 <len:24> <pos:32>
    if {[lindex $b 8] == 0x80 && [lindex $b 9] == 0 && [lindex $b 10] == 0 && [lindex $b 11] == 0 && [lindex $b 16] == 0x80} {
        set skip [U32 $tail 12]
        set start [expr {$size - 16 - $skip}]
        set wide 0
    } elseif {[lindex $b 0] == 0x82 && [lindex $b 1] == 0 && [lindex $b 2] == 0 && [lindex $b 3] == 0 && [lindex $b 8] == 0x83 && [lindex $b 16] == 0x81} {
        set skip [expr {(wide([lindex $b 9]) << 48 | wide([lindex $b 10]) << 40 | wide([lindex $b 11]) << 32) | [U32 $tail 4]}]
        set start [expr {$size - 24 - $skip}]
        set wide 1
    } else {
        Fail TRUNCATED "$path does not end with Metakit's tails: not a Metakit file, or truncated"
    }
    if {$start < 0 || $start > $size - 24} { Fail TRUNCATED "$path: the tails point outside the file (truncated?)" }
    set head [ReadAt $path $start 4]
    set hb [Bytes $head]
    if {[llength $hb] < 4 || !(([lindex $hb 0] == 0x4a && [lindex $hb 1] == 0x4c) || ([lindex $hb 0] == 0x4c && [lindex $hb 1] == 0x4a)) || [lindex $hb 2] != 0x1a} {
        Fail TRUNCATED "$path: no Metakit header where its tails say the store starts (offset $start)"
    }
    return [list $start $size $wide]
}

# The seal: the block that ends exactly where the store starts.
#   trailer (last 32 bytes): "KITSEAL" 0x1A | u32 version | u32 block size | u32 statement length
#                            | u32 signature length | u32 crc32(statement . signature) | u32 0
proc ::kitfmt::Frame {path} {
    variable L
    lassign [StoreFrame $path] start size wide
    if {$start < 32} { Fail SEAL "$path is a Metakit file with no kit seal in front of its store" }
    set tr [ReadAt $path [expr {$start - 32}] 32]
    if {[string range $tr 0 7] ne "KITSEAL\x1a"} { Fail SEAL "$path is a Metakit file with no kit seal in front of its store" }
    set ver [U32 $tr 8] ; set bsize [U32 $tr 12] ; set slen [U32 $tr 16] ; set glen [U32 $tr 20]
    set crc [U32 $tr 24] ; set res [U32 $tr 28]
    if {$ver != 1} { Fail SEAL "seal version $ver is not supported (this reader knows version 1)" }
    if {$bsize < 512 || $bsize > $L(sealMax) || $bsize % 512 || $bsize > $start || $slen + $glen + 32 > $bsize || $res != 0} {
        Fail SEAL "the seal's sizes are inconsistent (block $bsize, statement $slen, signature $glen)"
    }
    set bstart [expr {$start - $bsize}]
    set block [ReadAt $path $bstart $bsize]
    set stmt [string range $block 0 [expr {$slen - 1}]]
    set sig [string range $block $slen [expr {$slen + $glen - 1}]]
    set padding [string range $block [expr {$slen + $glen}] end-32]
    if {[string trim $padding \x00] ne ""} { Fail SEAL "the seal's padding is not all zero bytes" }
    if {([zlib crc32 $stmt$sig] & 0xffffffff) != $crc} { Fail SEAL "the seal's checksum does not match (damaged seal)" }
    set st [ParseStatement $stmt]
    if {[dict get $st header] != $bstart} {
        Fail STATEMENT "the statement says the header is [dict get $st header] bytes, but the seal starts at $bstart"
    }
    return [dict create size $size storeStart $start wide $wide sealStart $bstart sealSize $bsize \
        statement $stmt signature $sig st $st]
}

# section 7.2: fixed lines, fixed order, nothing else
proc ::kitfmt::ParseStatement {stmt} {
    if {[regexp {[^\x0a\x20-\x7e]} $stmt]} { Fail STATEMENT "the statement is not printable ASCII" }
    if {[string index $stmt end] ne "\n"} { Fail STATEMENT "the statement does not end with a newline" }
    set lines [split [string range $stmt 0 end-1] \n]
    set want {ribbon-kit-seal format kind name version root header}
    set st [dict create image ""]
    set i 0
    foreach line $lines {
        set w [split $line " "]
        set key [lindex $w 0]
        if {$i < [llength $want]} {
            if {$key ne [lindex $want $i]} { Fail STATEMENT "statement line [expr {$i + 1}] should be '[lindex $want $i]', not '$key'" }
        } elseif {$i == [llength $want] && $key eq "image"} {
        } else { Fail STATEMENT "unexpected statement line '$line'" }
        switch -- $key {
            ribbon-kit-seal { if {$line ne "ribbon-kit-seal 1"} { Fail STATEMENT "unknown statement version: $line" } }
            format { if {![regexp {^format ([0-9]+)\.([0-9]+)$} $line -> ma mi]} { Fail STATEMENT "bad format line: $line" } ; dict set st format [list $ma $mi] }
            kind { if {![regexp {^kind (app|system)$} $line -> v]} { Fail STATEMENT "bad kind line: $line" } ; dict set st kind $v }
            name { if {![regexp {^name (\S+)$} $line -> v]} { Fail STATEMENT "bad name line" } ; dict set st name $v }
            version { if {![regexp {^version (\S+)$} $line -> v]} { Fail STATEMENT "bad version line" } ; dict set st version $v }
            root { if {![regexp {^root ([0-9a-f]{64})$} $line -> v]} { Fail STATEMENT "bad root line" } ; dict set st root $v }
            header {
                if {![regexp {^header (0|[1-9][0-9]*) ([0-9a-f]{64})$} $line -> n v]} { Fail STATEMENT "bad header line" }
                dict set st header $n ; dict set st headerHash $v
            }
            image {
                if {![regexp {^image (erofs|squashfs) (0|[1-9][0-9]*) ([1-9][0-9]*) ([0-9a-f]{64}|-) ([0-9a-f]+|-)$} $line -> fs off len ver salt] || [string length $salt] > 256 || [string length $salt] % 2} {
                    Fail STATEMENT "bad image line: $line"
                }
                dict set st image [dict create fs $fs offset $off length $len verity $ver salt $salt]
            }
        }
        incr i
    }
    if {$i < [llength $want]} { Fail STATEMENT "the statement is incomplete" }
    return $st
}

# kitfmt probe path -> dict: kit 1 + identity, or kit 0 + reason (never raises for a readable file)
proc ::kitfmt::Probe {path} {
    if {[catch {Frame $path} fr opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "KITFMT" ? [lindex $ec 1] : "IO"}]
        # metakit 1: the file is a Metakit store (with or without a header) that is not a valid kit
        set metakit [expr {[lsearch -exact {TRUNCATED NOTKIT IO} $code] < 0}]
        return [dict create kit 0 reason $fr code $code metakit $metakit]
    }
    set st [dict get $fr st]
    return [dict create kit 1 kind [dict get $st kind] name [dict get $st name] version [dict get $st version] \
        format [dict get $st format] header [dict get $st header] storeStart [dict get $fr storeStart] \
        signed [expr {[string length [dict get $fr signature]] > 0}] image [expr {[dict get $st image] ne ""}] metakit 1]
}

# ============================================================================
#  Opening
# ============================================================================
proc ::kitfmt::Open {path args} {
    variable seq ; variable H ; variable formatMajor ; variable knownFeatures
    set force 0 ; set signed 0
    foreach {k v} $args {
        switch -- $k {
            -force { set force [expr {!!$v}] }
            -signed { set signed [expr {!!$v}] }
            default { Fail CONFIG "open: unknown option $k (-force, -signed)" }
        }
    }
    if {[llength $args] % 2} { Fail CONFIG "open: options come in pairs" }
    set path [file normalize $path]
    set fr [Frame $path]
    set st [dict get $fr st]
    lassign [dict get $st format] ma mi
    if {$ma != $formatMajor} { Fail VERSION "kit format $ma.$mi: this reader reads format $formatMajor.x only" $ma $mi }
    set sig [SigCheck [dict get $fr statement] [dict get $fr signature]]
    if {$signed && [dict get $sig state] ne "valid"} {
        Fail SIGNATURE "the kit's signature is [dict get $sig state]: [dict get $sig detail]" [dict get $sig state]
    }
    if {![llength [info commands ::mk::file]]} { package require Mk4tcl }
    set h kitfmt[incr seq]
    if {[catch {mk::file open $h $path -readonly} err]} { Fail STRUCTURE "Metakit could not open the store: $err" }
    set H($h,path) $path
    set H($h,frame) $fr
    set H($h,sig) $sig
    set H($h,verified) [dict create]
    set rc [catch {Load $h} err opts]
    if {!$rc} {
        set H($h,rootState) [expr {$H($h,root) eq [dict get $st root] ? "ok" : "mismatch"}]
        set rc [catch {CheckStatement $h} err opts]
    }
    if {!$rc && $H($h,rootState) ne "ok" && !$force} {
        set rc 1 ; set err "the kit's content does not match its seal: root $H($h,root), the seal says [dict get $st root]"
        set opts [list -errorcode [list KITFMT ROOT $H($h,root) [dict get $st root]]]
    }
    if {$rc} {
        Close $h
        if {![dict exists $opts -errorcode] || [lindex [dict get $opts -errorcode] 0] ne "KITFMT"} {
            Fail STRUCTURE "the store is not a valid kit: $err"
        }
        return -code error -errorcode [dict get $opts -errorcode] $err
    }
    return $h
}

proc ::kitfmt::Close {h} {
    variable H
    catch {mk::file close $h}
    array unset H $h,*
    return ""
}

proc ::kitfmt::Handle {h} {
    variable H
    if {![info exists H($h,path)]} { Fail CONFIG "no open kit '$h'" }
}

# the layout of a view as a dict  property -> type letter, or -> nested dict for a subview
proc ::kitfmt::LayoutDict {layout} {
    set d [dict create]
    foreach p $layout {
        if {[llength $p] == 2} {
            dict set d [lindex $p 0] [LayoutDict [lindex $p 1]]
        } else {
            set parts [split $p :]
            set t [expr {[llength $parts] > 1 ? [lindex $parts 1] : "S"}]
            dict set d [lindex $parts 0] $t
        }
    }
    return $d
}

# every property in `need` (name:T or {name {...}}) must be in the view's layout with that type
proc ::kitfmt::NeedLayout {have need where} {
    foreach p $need {
        if {[llength $p] == 2} {
            set n [lindex $p 0]
            if {![dict exists $have $n] || [llength [dict get $have $n]] < 2} { Fail STRUCTURE "$where has no subview '$n'" }
            NeedLayout [dict get $have $n] [lindex $p 1] $where.$n
        } else {
            lassign [split $p :] n t
            if {![dict exists $have $n] || [dict get $have $n] ne $t} { Fail STRUCTURE "$where has no property $n:$t" }
        }
    }
}

proc ::kitfmt::ValidName {name where} {
    variable L
    if {$name eq "" || $name eq "." || $name eq ".." || [string first / $name] >= 0 || [regexp {[\x00-\x1f\x7f\\]} $name]} {
        Fail PATH "$where: invalid name '$name'"
    }
    if {[string length [encoding convertto utf-8 $name]] > $L(name)} { Fail LIMIT "$where: name longer than $L(name) bytes" }
}

proc ::kitfmt::IsHex64 {s} { return [regexp {^[0-9a-f]{64}$} $s] }

# deflate/zlib worst case (zlib's compressBound)
proc ::kitfmt::Bound {n} { return [expr {$n + ($n >> 12) + ($n >> 14) + ($n >> 25) + 13}] }

proc ::kitfmt::Load {h} {
    variable H ; variable L ; variable formatMajor ; variable knownFeatures
    set views [mk::file views $h]
    foreach v {kit manifest needs provides perms entries effects dirs image} {
        if {[lsearch -exact $views $v] < 0} { Fail STRUCTURE "the store has no '$v' view" }
    }
    # ---- the format marker (section 9)
    NeedLayout [LayoutDict [mk::view layout $h.kit]] {format:S major:I minor:I requires:S} kit
    if {[mk::view size $h.kit] != 1} { Fail STRUCTURE "the kit view must have exactly one row" }
    lassign [mk::get $h.kit!0 format major minor requires] format major minor requires
    if {$format ne "ribbon-kit"} { Fail STRUCTURE "the format marker says '$format', not 'ribbon-kit'" }
    if {$major != $formatMajor} { Fail VERSION "kit format $major.$minor: this reader reads format $formatMajor.x only" $major $minor }
    set feats [lsort -unique [split [string trim $requires]]]
    foreach f $feats {
        if {![regexp {^[a-z0-9][a-z0-9-]*$} $f]} { Fail STRUCTURE "bad feature name '$f'" }
        if {[lsearch -exact $knownFeatures $f] < 0} { Fail FEATURE "the kit requires feature '$f', which this reader does not know" $f }
    }
    set H($h,format) [list $major $minor]
    set H($h,requires) $feats
    set H($h,writer) [expr {[dict exists [LayoutDict [mk::view layout $h.kit]] writer] ? [mk::get $h.kit!0 writer] : ""}]

    # ---- the manifest (section 4)
    LoadManifest $h

    # ---- the tree (section 5)
    set layout [LayoutDict [mk::view layout $h.dirs]]
    NeedLayout $layout {name:S parent:I mode:I {files {name:S size:I date:I contents:B mode:I link:S fsize:L codec:S csize:I hash:S {chunks {z:B hash:S}}}}} dirs
    set nd [mk::view size $h.dirs]
    if {$nd < 1} { Fail STRUCTURE "the dirs view is empty (no root directory)" }
    if {$nd > $L(entries)} { Fail LIMIT "more than $L(entries) directories" }
    set E [dict create]
    set dpath(0) ""
    lassign [mk::get $h.dirs!0 name parent mode] n p m
    if {$p != -1} { Fail STRUCTURE "directory row 0 (the root) must have parent -1" }
    set parent(0) -1 ; set dmode(0) $m
    for {set d 1} {$d < $nd} {incr d} {
        lassign [mk::get $h.dirs!$d name parent mode] n p m
        if {$p < 0 || $p >= $nd || $p == $d} { Fail STRUCTURE "directory row $d has an invalid parent $p" }
        ValidName $n "directory row $d"
        if {$m < 0 || $m > 0x1ff} { Fail STRUCTURE "directory row $d: mode [format %o $m] has bits outside 0777" }
        set parent($d) $p ; set dname($d) $n ; set dmode($d) $m
    }
    # paths, with cycle and depth checks
    for {set d 1} {$d < $nd} {incr d} {
        set parts {} ; set x $d ; set depth 0
        while {$x != 0} {
            if {[incr depth] > $L(depth)} { Fail LIMIT "directory row $d is nested deeper than $L(depth) (or its parents form a cycle)" }
            set parts [linsert $parts 0 $dname($x)]
            set x $parent($x)
        }
        set dpath($d) [join $parts /]
    }
    set total 0 ; set nchunksAll 0 ; set storedAll 0
    for {set d 1} {$d < $nd} {incr d} {
        if {[dict exists $E $dpath($d)]} { Fail STRUCTURE "duplicate entry $dpath($d)" }
        if {[string length [encoding convertto utf-8 $dpath($d)]] > $L(path)} { Fail LIMIT "path longer than $L(path) bytes: $dpath($d)" }
        dict set E $dpath($d) [dict create type dir mode $dmode($d) row $h.dirs!$d]
    }
    if {$dmode(0) < 0 || $dmode(0) > 0x1ff} { Fail STRUCTURE "the root directory's mode has bits outside 0777" }
    for {set d 0} {$d < $nd} {incr d} {
        set fv $h.dirs!$d.files
        set nf [mk::view size $fv]
        for {set f 0} {$f < $nf} {incr f} {
            if {[incr total] > $L(entries)} { Fail LIMIT "more than $L(entries) entries" }
            set row $fv!$f
            lassign [mk::get $row name size date mode link fsize codec csize hash] n size date mode link fsize codec csize hash
            ValidName $n "file row $f of directory $dpath($d)"
            set p [expr {$dpath($d) eq "" ? $n : "$dpath($d)/$n"}]
            if {[dict exists $E $p]} { Fail STRUCTURE "duplicate entry $p" }
            if {[string length [encoding convertto utf-8 $p]] > $L(path)} { Fail LIMIT "path longer than $L(path) bytes: $p" }
            if {$mode < 0 || $mode > 0x1ff} { Fail STRUCTURE "$p: mode [format %o $mode] has bits outside 0777 (no setuid, setgid, sticky or file type bits)" }
            set csz [mk::get $row -size contents]
            set nch [mk::view size $row.chunks]
            if {$link ne ""} {
                if {[string length [encoding convertto utf-8 $link]] > $L(link) || [regexp {[\x00]} $link]} { Fail LIMIT "$p: symlink target too long" }
                if {$codec ne "" || $fsize != 0 || $size != 0 || $csz != 0 || $nch != 0 || $hash ne ""} { Fail STRUCTURE "$p: a symlink carries no data" }
                dict set E $p [dict create type link mode $mode date $date link $link row $row]
                continue
            }
            if {$fsize < 0 || $fsize > $L(fileMax)} { Fail LIMIT "$p: size $fsize out of range" }
            if {($fsize <= 0x7fffffff && $size != $fsize) || ($fsize > 0x7fffffff && $size != -1)} {
                Fail STRUCTURE "$p: size ($size) and fsize ($fsize) disagree"
            }
            set e [dict create type file mode $mode date $date size $fsize codec $codec csize $csize row $row hash "" hashes {} lens {} stored 0 chunks 0]
            switch -- $codec {
                classic {
                    if {$nch != 0 || $csize != 0} { Fail STRUCTURE "$p: a classic file has no chunks" }
                    if {$fsize > $L(classic) || $csz > $L(classic)} { Fail LIMIT "$p: a classic file is limited to $L(classic) bytes" }
                    if {![IsHex64 $hash]} { Fail STRUCTURE "$p: a classic file needs its hash" }
                    if {$csz != $fsize && $csz > [Bound $fsize]} { Fail STRUCTURE "$p: stored $csz bytes for $fsize, more than deflate can need" }
                    dict set e hash $hash ; dict set e stored $csz
                }
                raw - deflate - zstd {
                    if {$codec eq "zstd" && [lsearch -exact $H($h,requires) codec-zstd] < 0} { Fail STRUCTURE "$p: codec zstd needs the feature codec-zstd" }
                    if {$csz != 0 || $hash ne ""} { Fail STRUCTURE "$p: a chunked file keeps its data in chunks only" }
                    if {$csize < $L(chunkMin) || $csize > $L(chunkMax) || ($csize & ($csize - 1))} {
                        Fail STRUCTURE "$p: chunk size $csize is not a power of two from $L(chunkMin) to $L(chunkMax)"
                    }
                    set want [expr {($fsize + $csize - 1) / $csize}]
                    if {$nch != $want} { Fail STRUCTURE "$p: $nch chunks, $want expected for $fsize bytes in chunks of $csize" }
                    set hashes {} ; set lens {} ; set stored 0
                    for {set i 0} {$i < $nch} {incr i} {
                        set hx [mk::get $row.chunks!$i hash]
                        if {![IsHex64 $hx]} { Fail STRUCTURE "$p: chunk $i has no valid hash" }
                        set zl [mk::get $row.chunks!$i -size z]
                        set plain [expr {$i < $nch - 1 ? $csize : $fsize - $i * wide($csize)}]
                        if {($codec eq "raw" && $zl != $plain) || ($codec ne "raw" && ($zl < 1 || $zl > [Bound $plain]))} {
                            Fail STRUCTURE "$p: chunk $i stores $zl bytes for $plain"
                        }
                        lappend hashes $hx ; lappend lens $zl ; incr stored $zl
                    }
                    dict set e hashes $hashes ; dict set e lens $lens ; dict set e stored $stored ; dict set e chunks $nch
                    incr nchunksAll $nch
                }
                default { Fail STRUCTURE "$p: unknown codec '$codec'" }
            }
            incr storedAll [dict get $e stored]
            dict set E $p $e
        }
    }
    set H($h,entries) $E
    set kids [dict create "" {}]
    dict for {p e} $E {
        set up [Up $p]
        dict lappend kids $up $p
        if {[dict get $e type] eq "dir" && ![dict exists $kids $p]} { dict set kids $p {} }
    }
    set H($h,kids) $kids
    set H($h,dirpaths) [array get dpath]
    set H($h,stats) [dict create chunks $nchunksAll stored $storedAll]
    LoadImage $h
    foreach en [dict get $H($h,manifest) entries] {
        set ep [lindex $en 1]
        if {![dict exists $E $ep] || [dict get $E $ep type] eq "dir"} { Fail STRUCTURE "entry point '[lindex $en 0]' names '$ep', which is not a file of the kit" }
    }
    set H($h,index) [BuildIndex $h]
    set H($h,root) [Hash [encoding convertto utf-8 $H($h,index)]]
}

proc ::kitfmt::LoadManifest {h} {
    variable H ; variable L
    set spec {
        manifest {key:S value:S}  needs {name:S range:S}  provides {name:S version:S}
        perms {name:S value:S}  entries {name:S path:S args:S type:S}  effects {type:S value:S}
    }
    set m [dict create]
    foreach {v props} $spec {
        NeedLayout [LayoutDict [mk::view layout $h.$v]] $props $v
        set n [mk::view size $h.$v]
        if {$n > $L(rows)} { Fail LIMIT "more than $L(rows) rows in $v" }
        set names {}
        foreach p $props { lappend names [lindex [split $p :] 0] }
        set rows {}
        for {set i 0} {$i < $n} {incr i} {
            set r [mk::get $h.$v!$i {*}$names]
            foreach x $r {
                if {[string length $x] > $L(value)} { Fail LIMIT "$v row $i: a value longer than $L(value) bytes" }
                if {[regexp {[\x00]} $x]} { Fail STRUCTURE "$v row $i: NUL in a value" }
            }
            lappend rows $r
        }
        dict set m $v $rows
    }
    set fields [dict create]
    foreach r [dict get $m manifest] {
        lassign $r k val
        if {![regexp {^[a-z][a-z0-9-]*$} $k] || [string length $k] > 64} { Fail STRUCTURE "bad manifest key '$k'" }
        if {[dict exists $fields $k]} { Fail STRUCTURE "manifest key '$k' appears twice" }
        dict set fields $k $val
    }
    foreach k {name version kind} {
        if {![dict exists $fields $k]} { Fail STRUCTURE "the manifest has no '$k'" }
    }
    if {![regexp {^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$} [dict get $fields name]] || [string length [dict get $fields name]] > 255} {
        Fail STRUCTURE "manifest name '[dict get $fields name]' is not a reverse-DNS name"
    }
    if {![regexp {^[0-9A-Za-z][0-9A-Za-z.+~_-]*$} [dict get $fields version]] || [string length [dict get $fields version]] > 64} {
        Fail STRUCTURE "manifest version '[dict get $fields version]' is not valid"
    }
    if {[lsearch -exact {app system} [dict get $fields kind]] < 0} { Fail STRUCTURE "manifest kind must be app or system" }
    foreach r [dict get $m perms] {
        if {![regexp {^[a-z][a-z0-9-]*$} [lindex $r 0]]} { Fail STRUCTURE "bad permission name '[lindex $r 0]'" }
    }
    dict set m fields $fields
    dict unset m manifest
    set H($h,manifest) $m
}

proc ::kitfmt::LoadImage {h} {
    variable H ; variable L
    NeedLayout [LayoutDict [mk::view layout $h.image]] {fs:S len:L pad:I seg:I verity:S salt:S {segs {hash:S}} data:B} image
    set n [mk::view size $h.image]
    set H($h,image) ""
    if {$n == 0} { return }
    if {$n > 1} { Fail STRUCTURE "a kit carries at most one image" }
    lassign [mk::get $h.image!0 fs len pad seg verity salt] fs len pad seg verity salt
    if {[lsearch -exact {erofs squashfs} $fs] < 0} { Fail STRUCTURE "image: unknown filesystem '$fs'" }
    if {$len <= 0 || $len % 4096} { Fail STRUCTURE "image: length $len is not a positive multiple of 4096" }
    if {$pad < 0 || $pad >= $L(pad)} { Fail STRUCTURE "image: pad $pad out of range" }
    if {$seg < $L(segMin) || $seg > $L(segMax) || ($seg & ($seg - 1))} { Fail STRUCTURE "image: segment size $seg is not a power of two from $L(segMin) to $L(segMax)" }
    if {$verity ne "" && ![IsHex64 $verity]} { Fail STRUCTURE "image: verity root is not 64 hex digits" }
    if {$salt ne "" && ![regexp {^([0-9a-f]{2}){1,128}$} $salt]} { Fail STRUCTURE "image: bad salt" }
    set ns [mk::view size $h.image!0.segs]
    if {$ns != ($len + $seg - 1) / $seg} { Fail STRUCTURE "image: $ns segment hashes for $len bytes in segments of $seg" }
    set segs {}
    for {set i 0} {$i < $ns} {incr i} {
        set hx [mk::get $h.image!0.segs!$i hash]
        if {![IsHex64 $hx]} { Fail STRUCTURE "image: segment $i has no valid hash" }
        lappend segs $hx
    }
    set msize [mk::get $h.image!0 -size data]
    if {$msize != $pad + $len} { Fail STRUCTURE "image: the memo holds $msize bytes, pad + length is [expr {$pad + $len}]" }
    set H($h,image) [dict create fs $fs length $len pad $pad seg $seg verity $verity salt $salt segs $segs]
}

# the statement (seal) against the store, section 7.3
proc ::kitfmt::CheckStatement {h} {
    variable H
    set st [dict get $H($h,frame) st]
    set f [dict get $H($h,manifest) fields]
    set lst [dict get $st format]
    if {[lindex $lst 0] != [lindex $H($h,format) 0] || [lindex $lst 1] != [lindex $H($h,format) 1]} {
        Fail STATEMENT "the seal says format [join $lst .], the store [join $H($h,format) .]"
    }
    foreach k {kind name version} {
        if {[dict get $st $k] ne [dict get $f $k]} { Fail STATEMENT "the seal says $k '[dict get $st $k]', the manifest '[dict get $f $k]'" }
    }
    set im [dict get $st image]
    if {($im eq "") != ($H($h,image) eq "")} { Fail STATEMENT "the seal and the store disagree about an embedded image" }
    if {$im eq ""} { return }
    set I $H($h,image)
    set off [dict get $im offset]
    if {[dict get $im fs] ne [dict get $I fs] || [dict get $im length] != [dict get $I length]} { Fail STATEMENT "the seal's image line does not match the image view" }
    foreach k {verity salt} {
        set v [dict get $I $k] ; if {$v eq ""} { set v - }
        if {[dict get $im $k] ne $v} { Fail STATEMENT "the seal's image $k does not match the image view" }
    }
    if {$off % 4096} { Fail STATEMENT "the image offset $off is not 4096-aligned" }
    set fr $H($h,frame)
    if {$off < [dict get $fr storeStart] || $off + [dict get $I length] > [dict get $fr size]} { Fail STATEMENT "the image offset points outside the store" }
    # the memo really is at that offset: compare its first bytes through Metakit with the file
    set n [expr {min(4096, [dict get $I length])}]
    set ch [mk::channel $h.image!0 data r]
    fconfigure $ch -translation binary
    seek $ch [dict get $I pad]
    set viaMk [read $ch $n]
    close $ch
    if {$viaMk ne [ReadAt $H($h,path) $off $n]} { Fail STATEMENT "the image is not where the seal says it is (offset $off)" }
    dict set H($h,image) offset $off
}

# ============================================================================
#  The index and the root hash (section 6.2)
# ============================================================================
proc ::kitfmt::Esc {s} { return [string map [list \\ \\\\ \t \\t \n \\n \r \\r] $s] }
proc ::kitfmt::Line {args} {
    set out {}
    foreach a $args { lappend out [Esc $a] }
    return [join $out \t]
}
# lines of one group, sorted by their UTF-8 bytes
proc ::kitfmt::SortGroup {lines} {
    set enc {}
    foreach l $lines { lappend enc [encoding convertto utf-8 $l] }
    set out {}
    foreach l [lsort $enc] { lappend out [encoding convertfrom utf-8 $l] }
    return $out
}

proc ::kitfmt::BuildIndex {h} {
    variable H
    set m $H($h,manifest)
    set out [list "ribbon-kit-index 1" [Line format [join $H($h,format) .]] [Line requires [join $H($h,requires) " "]]]
    set g {}
    dict for {k v} [dict get $m fields] { lappend g [Line manifest $k $v] }
    set out [concat $out [SortGroup $g]]
    foreach {v tag} {needs need provides provide perms perm entries entry effects effect} {
        set g {}
        foreach r [dict get $m $v] { lappend g [eval [list Line $tag] $r] }
        set out [concat $out [SortGroup $g]]
    }
    set dirs {} ; set files {} ; set links {}
    dict for {p e} $H($h,entries) {
        switch -- [dict get $e type] {
            dir { lappend dirs [Line dir $p [dict get $e mode]] }
            link { lappend links [Line link $p [dict get $e mode] [dict get $e date] [dict get $e link]] }
            file {
                set hs [expr {[dict get $e codec] eq "classic" ? [dict get $e hash] : [join [dict get $e hashes] ,]}]
                lappend files [Line file $p [dict get $e mode] [dict get $e date] [dict get $e size] [dict get $e codec] [dict get $e csize] $hs]
            }
        }
    }
    lappend out [Line rootdir [mk::get $h.dirs!0 mode]]
    set out [concat $out [SortGroup $dirs] [SortGroup $files] [SortGroup $links]]
    if {$H($h,image) ne ""} {
        set I $H($h,image)
        lappend out [Line image [dict get $I fs] [dict get $I length] [dict get $I pad] [dict get $I seg] \
            [dict get $I verity] [dict get $I salt] [join [dict get $I segs] ,]]
    }
    return "[join $out \n]\n"
}

proc ::kitfmt::IndexText {h} { Handle $h ; variable H ; return $H($h,index) }

# ============================================================================
#  Signatures (section 7.4).  minisign / Ed25519 (D14).  The trust decision is the caller's:
#  `kitfmt configure -keys` lists the public keys it trusts; with none, a signed kit is "unchecked".
# ============================================================================
proc ::kitfmt::B64Decode {s} {
    set alpha ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
    set s [string trimright [string trim $s] =]
    if {[regexp {[^A-Za-z0-9+/]} $s]} { return -code error "not base64" }
    set out "" ; set acc 0 ; set bits 0
    foreach c [split $s ""] {
        set acc [expr {(($acc << 6) | [string first $c $alpha]) & 0xffffff}]
        incr bits 6
        if {$bits >= 8} {
            incr bits -8
            append out [binary format c [expr {($acc >> $bits) & 0xff}]]
        }
    }
    return $out
}

# minisign key id as minisign prints it: the 8 bytes little-endian, upper-case hex
proc ::kitfmt::KeyId {bytes8} {
    binary scan $bytes8 H* hx
    set out ""
    foreach {a b} [split $hx ""] { set out "$a$b$out" }
    return [string toupper $out]
}

proc ::kitfmt::ParseSig {sig} {
    set lines [split [string trimright $sig \n] \n]
    if {[llength $lines] != 4 || ![string match "untrusted comment: *" [lindex $lines 0]] || ![string match "trusted comment: *" [lindex $lines 2]]} {
        return -code error "not a minisign signature"
    }
    set raw [B64Decode [lindex $lines 1]]
    if {[string length $raw] != 74 || ([string range $raw 0 1] ne "Ed" && [string range $raw 0 1] ne "ED")} { return -code error "not an Ed25519 minisign signature" }
    return [dict create keyid [KeyId [string range $raw 2 9]] comment [string range [lindex $lines 2] 17 end] alg [string range $raw 0 1]]
}

proc ::kitfmt::PubKeyId {pk} {
    if {[catch {B64Decode $pk} raw] || [string length $raw] != 42 || [string range $raw 0 1] ne "Ed"} { return "" }
    return [KeyId [string range $raw 2 9]]
}

proc ::kitfmt::SigCheck {stmt sig} {
    variable cfg
    if {$sig eq ""} { return [dict create state unsigned detail "the kit is not signed" keyid "" comment ""] }
    if {[catch {ParseSig $sig} s]} { return [dict create state invalid detail "malformed signature: $s" keyid "" comment ""] }
    set keyid [dict get $s keyid] ; set comment [dict get $s comment]
    if {![llength $cfg(-keys)]} {
        return [dict create state unchecked detail "no trusted keys are configured (kitfmt configure -keys)" keyid $keyid comment $comment]
    }
    set pk ""
    foreach k $cfg(-keys) { if {[PubKeyId $k] eq $keyid} { set pk $k ; break } }
    if {$pk eq ""} { return [dict create state untrusted detail "signed by key $keyid, which is not a trusted key" keyid $keyid comment $comment] }
    if {[catch {{*}$cfg(-verifier) $stmt $sig $pk} ok]} {
        return [dict create state unchecked detail "the signature could not be checked: $ok" keyid $keyid comment $comment]
    }
    if {$ok} { return [dict create state valid detail "good signature by trusted key $keyid" keyid $keyid comment $comment] }
    return [dict create state invalid detail "BAD signature (key $keyid)" keyid $keyid comment $comment]
}

# the default verifier: the minisign program (D14 A)
proc ::kitfmt::MinisignVerify {stmt sig pk} {
    set exe [auto_execok minisign]
    if {$exe eq ""} { return -code error "minisign is not installed" }
    set tmp [TempDir]
    set rc [catch {
        foreach {name data} [list m $stmt m.minisig $sig] {
            set ch [open [file join $tmp $name] {WRONLY CREAT EXCL}]
            fconfigure $ch -translation binary
            puts -nonewline $ch $data
            close $ch
        }
        exec {*}$exe -V -q -P $pk -m [file join $tmp m] -x [file join $tmp m.minisig]
    } res]
    catch {file delete -force $tmp}
    return [expr {!$rc}]
}

# ============================================================================
#  Queries
# ============================================================================
proc ::kitfmt::Info {h} {
    Handle $h ; variable H
    set fr $H($h,frame) ; set st [dict get $fr st] ; set f [dict get $H($h,manifest) fields]
    return [dict create path $H($h,path) format $H($h,format) requires $H($h,requires) writer $H($h,writer) \
        kind [dict get $f kind] name [dict get $f name] version [dict get $f version] \
        root $H($h,root) sealRoot [dict get $st root] rootState $H($h,rootState) \
        signature $H($h,sig) header [dict get $st header] \
        store [dict create start [dict get $fr storeStart] end [dict get $fr size] wide [dict get $fr wide]] \
        seal [dict create start [dict get $fr sealStart] size [dict get $fr sealSize]] \
        entries [dict size $H($h,entries)] chunks [dict get $H($h,stats) chunks] stored [dict get $H($h,stats) stored] \
        bytes [Total $h] image [expr {$H($h,image) ne ""}]]
}

proc ::kitfmt::Total {h} {
    variable H
    set n 0
    dict for {p e} $H($h,entries) { if {[dict get $e type] eq "file"} { incr n [dict get $e size] } }
    return $n
}

proc ::kitfmt::Manifest {h} { Handle $h ; variable H ; return $H($h,manifest) }

proc ::kitfmt::Image {h} {
    Handle $h ; variable H
    if {$H($h,image) eq ""} { return "" }
    set I $H($h,image)
    return [dict create fs [dict get $I fs] offset [dict get $I offset] length [dict get $I length] pad [dict get $I pad] \
        seg [dict get $I seg] segments [llength [dict get $I segs]] verity [dict get $I verity] salt [dict get $I salt]]
}

proc ::kitfmt::Entry {h path} {
    variable H
    set path [string trim $path /]
    if {$path eq ""} { return [dict create type dir mode [mk::get $h.dirs!0 mode]] }
    if {![dict exists $H($h,entries) $path]} { Fail NOENT "no such entry in the kit: $path" $path }
    return [dict get $H($h,entries) $path]
}

# the parent of a kit path ("" for the root).  Plain string work: [file dirname] and [file join]
# give a leading "~" a meaning in Tcl 8, and kit names may start with one.
proc ::kitfmt::Up {p} {
    set k [string last / $p]
    if {$k < 0} { return "" }
    return [string range $p 0 [expr {$k - 1}]]
}

proc ::kitfmt::Stat {h path} {
    Handle $h ; variable H
    set path [string trim $path /]
    if {$path eq ""} { return [dict create path "" type dir mode [mk::get $h.dirs!0 mode]] }
    if {![dict exists $H($h,entries) $path]} { Fail NOENT "no such entry in the kit: $path" $path }
    set e [dict get $H($h,entries) $path]
    set out [dict create path $path type [dict get $e type] mode [dict get $e mode]]
    switch -- [dict get $e type] {
        file { foreach k {date size codec csize chunks stored} { dict set out $k [dict get $e $k] } }
        link { dict set out date [dict get $e date] ; dict set out link [dict get $e link] }
    }
    return $out
}

proc ::kitfmt::Chunks {h path} {
    Handle $h ; variable H
    set path [string trim $path /]
    if {![dict exists $H($h,entries) $path]} { Fail NOENT "no such entry in the kit: $path" $path }
    set e [dict get $H($h,entries) $path]
    if {[dict get $e type] ne "file"} { Fail TYPE "$path is a [dict get $e type], not a file" }
    if {[dict get $e codec] eq "classic"} { return [list [list 0 [dict get $e stored] [dict get $e hash]]] }
    set out {} ; set i 0
    foreach n [dict get $e lens] hx [dict get $e hashes] { lappend out [list $i $n $hx] ; incr i }
    return $out
}

proc ::kitfmt::Walk {h} { Handle $h ; variable H ; return [lsort [dict keys $H($h,entries)]] }

proc ::kitfmt::List {h {dir ""}} {
    Handle $h ; variable H
    set dir [string trim $dir /]
    if {$dir ne ""} {
        if {![dict exists $H($h,entries) $dir]} { Fail NOENT "no such entry in the kit: $dir" $dir }
        if {[dict get $H($h,entries) $dir type] ne "dir"} { Fail TYPE "$dir is not a directory" }
    }
    if {![dict exists $H($h,kids) $dir]} { return {} }
    return [lsort [dict get $H($h,kids) $dir]]
}

# ============================================================================
#  Reading: one chunk at a time, size checked before the fetch, hash checked before decoding
# ============================================================================
proc ::kitfmt::Inflate {z plain where} {
    if {[llength [info commands ::zlib]] == 0} { Fail CODEC "$where: this Tcl has no zlib" }
    if {[catch {zlib stream decompress} s]} {
        # Tcl 8.5 tclkits: no streams, so no cap on the output (the hash was checked first)
        if {[catch {zlib decompress $z} out]} { Fail CODEC "$where: not a valid zlib stream: $out" }
    } else {
        # never more than one byte past what the chunk should hold (a decompression bomb stops here)
        set rc [catch {$s put -finalize $z ; set out [$s get [expr {$plain + 1}]] ; set eof [$s eof]} err]
        $s close
        if {$rc} { Fail CODEC "$where: not a valid zlib stream: $err" }
        if {!$eof} { Fail CODEC "$where: decodes to more than $plain bytes" }
    }
    if {[string length $out] != $plain} { Fail CODEC "$where: decodes to [string length $out] bytes, $plain expected" }
    return $out
}

proc ::kitfmt::Chunk {h p e i} {
    variable H
    set row [dict get $e row]
    set codec [dict get $e codec]
    if {$codec eq "zstd"} { Fail CODEC "$p: codec zstd is not supported by this reader" }
    set z [mk::get $row.chunks!$i z]
    if {[string length $z] != [lindex [dict get $e lens] $i]} { Fail HASH "$p: chunk $i changed size while open" $p $i }
    set key $row/$i
    if {![dict exists $H($h,verified) $key]} {
        if {[Hash $z] ne [lindex [dict get $e hashes] $i]} { Fail HASH "$p: chunk $i does not match its hash" $p $i }
        if {[dict size $H($h,verified)] < 100000} { dict set H($h,verified) $key 1 }
    }
    set csize [dict get $e csize]
    set plain [expr {$i < [dict get $e chunks] - 1 ? $csize : [dict get $e size] - $i * wide($csize)}]
    if {$codec eq "raw"} { return $z }
    return [Inflate $z $plain "$p chunk $i"]
}

proc ::kitfmt::Classic {h p e} {
    set row [dict get $e row]
    set z [mk::get $row contents]
    if {[string length $z] != [dict get $e stored]} { Fail HASH "$p changed size while open" $p }
    if {[Hash $z] ne [dict get $e hash]} { Fail HASH "$p: its data does not match its hash" $p 0 }
    if {[string length $z] == [dict get $e size]} { return $z }
    return [Inflate $z [dict get $e size] $p]
}

proc ::kitfmt::Read {h path {offset 0} {length -1}} {
    Handle $h ; variable H
    set path [string trim $path /]
    if {![dict exists $H($h,entries) $path]} { Fail NOENT "no such entry in the kit: $path" $path }
    set e [dict get $H($h,entries) $path]
    if {[dict get $e type] ne "file"} { Fail TYPE "$path is a [dict get $e type], not a file" }
    set size [dict get $e size]
    if {![string is wideinteger -strict $offset] || $offset < 0} { Fail CONFIG "bad offset $offset" }
    if {![string is wideinteger -strict $length]} { Fail CONFIG "bad length $length" }
    if {$length < 0 || $offset + $length > $size} { set length [expr {max(0, $size - $offset)}] }
    if {$length == 0} { return "" }
    if {[dict get $e codec] eq "classic"} {
        return [string range [Classic $h $path $e] $offset [expr {$offset + $length - 1}]]
    }
    set csize [dict get $e csize]
    set first [expr {$offset / $csize}]
    set last [expr {($offset + $length - 1) / $csize}]
    set out ""
    for {set i $first} {$i <= $last} {incr i} { append out [Chunk $h $path $e $i] }
    set from [expr {$offset - $first * wide($csize)}]
    return [string range $out $from [expr {$from + $length - 1}]]
}

# ============================================================================
#  Extracting
# ============================================================================
proc ::kitfmt::Extract {h path dest args} {
    Handle $h ; variable H
    set progress ""
    foreach {k v} $args {
        if {$k ne "-progress"} { Fail CONFIG "extract: unknown option $k (-progress)" }
        set progress $v
    }
    set path [string trim $path /]
    if {![file isdirectory $dest]} { Fail CONFIG "destination $dest is not a directory" }
    set dest [file normalize $dest]
    if {$path eq ""} {
        set todo [Walk $h] ; set strip ""
    } else {
        set e [Entry $h $path]
        set todo [list $path]
        if {[dict get $e type] eq "dir"} {
            foreach p [Walk $h] { if {[string match $path/* $p]} { lappend todo $p } }
        }
        set strip [Up $path]
    }
    set links {} ; set dirs {} ; set n 0 ; set done 0 ; set total 0
    foreach p $todo { set e [dict get $H($h,entries) $p] ; if {[dict get $e type] eq "file"} { incr total [dict get $e size] } }
    foreach p $todo {
        set rel [expr {$strip eq "" ? $p : [string range $p [expr {[string length $strip] + 1}] end]}]
        set target $dest/$rel
        if {[file exists $target] || ![catch {file lstat $target lst}]} { Fail EXISTS "$target already exists" $target }
    }
    foreach p $todo {
        set e [dict get $H($h,entries) $p]
        if {$progress ne "" && [uplevel #0 [concat $progress [list $done $total]]] eq "stop"} { Fail CANCELLED "extraction stopped after $n entries" $n }
        set rel [expr {$strip eq "" ? $p : [string range $p [expr {[string length $strip] + 1}] end]}]
        set target $dest/$rel
        switch -- [dict get $e type] {
            dir { file mkdir $target ; lappend dirs $target [dict get $e mode] }
            file { WriteFile $h $p $e $target ; incr n ; incr done [dict get $e size] }
            link { lappend links $p $e $target $rel }
        }
    }
    foreach {p e target rel} $links {
        # a link must stay inside what is extracted
        set t [dict get $e link]
        set depth [expr {[llength [split $rel /]] - 1}]
        foreach part [split $t /] {
            if {$part eq ".."} { incr depth -1 } elseif {$part ne "." && $part ne ""} { incr depth }
            if {$depth < 0} break
        }
        if {[string index $t 0] eq "/" || $depth < 0} { Fail PATH "$p: the link target '$t' leaves the extracted tree" $p }
        if {[catch {file link -symbolic $target $t}]} {
            if {$::tcl_platform(platform) ne "unix"} { Fail PATH "$p: could not create the symbolic link" $p }
            exec ln -s -- $t $target
        }
        incr n
    }
    # folder modes last (deepest first), keeping them writable for the owner until now
    for {set i [expr {[llength $dirs] - 2}]} {$i >= 0} {incr i -2} {
        if {$::tcl_platform(platform) eq "unix"} { catch {file attributes [lindex $dirs $i] -permissions [lindex $dirs [expr {$i + 1}]]} }
    }
    return $n
}

proc ::kitfmt::WriteFile {h p e target} {
    set ch [open $target {WRONLY CREAT EXCL}]
    fconfigure $ch -translation binary
    set rc [catch {
        if {[dict get $e codec] eq "classic"} {
            puts -nonewline $ch [Classic $h $p $e]
        } else {
            for {set i 0} {$i < [dict get $e chunks]} {incr i} { puts -nonewline $ch [Chunk $h $p $e $i] }
        }
    } err opts]
    close $ch
    if {$rc} { catch {file delete $target} ; return -options $opts $err }
    if {$::tcl_platform(platform) eq "unix"} { file attributes $target -permissions [dict get $e mode] }
    catch {file mtime $target [dict get $e date]}
}

# ============================================================================
#  Verifying everything (section 8): chunks, classic files, the image, the header, root, signature
# ============================================================================
proc ::kitfmt::Verify {h args} {
    Handle $h ; variable H
    set progress "" ; set paths ""
    foreach {k v} $args {
        switch -- $k {
            -progress { set progress $v }
            -paths { set paths $v }
            default { Fail CONFIG "verify: unknown option $k (-progress, -paths)" }
        }
    }
    set bad {}
    set total 0
    set todo {}
    if {$paths eq ""} { set paths [Walk $h] }
    set want {}
    foreach p $paths {
        set p [string trim $p /]
        set e [Entry $h $p]
        lappend want $p
        if {[dict get $e type] eq "dir"} { foreach q [Walk $h] { if {$p eq "" || [string match $p/* $q]} { lappend want $q } } }
    }
    foreach p [lsort -unique $want] {
        if {$p eq ""} continue
        set e [dict get $H($h,entries) $p]
        if {[dict get $e type] eq "file"} { lappend todo $p ; incr total [dict get $e stored] }
    }
    set I $H($h,image)
    if {$I ne ""} { incr total [dict get $I length] }
    set hlen [dict get $H($h,frame) st header]
    incr total $hlen
    set done 0 ; set chunks 0 ; set cancelled 0
    set tick [list apply {{progress done total} {
        if {$progress eq ""} { return 0 }
        return [expr {[uplevel #0 [concat $progress [list $done $total]]] eq "stop"}]
    }} $progress]
    # the header (bytes in front of the seal) is covered by the statement
    if {$hlen > 0} {
        set hd [ReadAt $H($h,path) 0 $hlen]
        if {[Hash $hd] ne [dict get $H($h,frame) st headerHash]} { lappend bad [list "" header "the header does not match the seal"] }
        incr done $hlen
    } elseif {[dict get $H($h,frame) st headerHash] ne [::kitfmt::sha256::hex ""]} {
        lappend bad [list "" header "the seal's hash of the empty header is wrong"]
    }
    if {[{*}$tick $done $total]} { set cancelled 1 }
    # chunks, in batches so that one external hash run covers many of them
    set batch {} ; set bbytes 0
    foreach p $todo {
        if {$cancelled} break
        set e [dict get $H($h,entries) $p]
        if {[dict get $e codec] eq "classic"} {
            if {[catch {Classic $h $p $e} err]} { lappend bad [list $p 0 $err] }
            incr done [dict get $e stored] ; incr chunks
            continue
        }
        for {set i 0} {$i < [dict get $e chunks]} {incr i} {
            lappend batch [list $p $i]
            incr bbytes [lindex [dict get $e lens] $i]
            if {[llength $batch] >= 64 || $bbytes >= 16777216} {
                set bad [concat $bad [VerifyBatch $h $batch]]
                incr done $bbytes ; incr chunks [llength $batch]
                set batch {} ; set bbytes 0
                if {[{*}$tick $done $total]} { set cancelled 1 ; break }
            }
        }
    }
    if {[llength $batch] && !$cancelled} {
        set bad [concat $bad [VerifyBatch $h $batch]]
        incr done $bbytes ; incr chunks [llength $batch]
    }
    if {!$cancelled && [{*}$tick $done $total]} { set cancelled 1 }
    # the image, segment by segment, read from the file at the sealed offset
    set imageState none
    if {$I ne "" && !$cancelled} {
        set imageState ok
        set seg [dict get $I seg] ; set len [dict get $I length] ; set off [dict get $I offset]
        set ch [open $H($h,path) rb]
        seek $ch $off
        set i 0
        foreach want [dict get $I segs] {
            set n [expr {min($seg, $len - $i * wide($seg))}]
            set data [read $ch $n]
            if {[string length $data] != $n || [Hash $data] ne $want} {
                lappend bad [list "" image "segment $i does not match its hash"] ; set imageState bad
            }
            incr done $n ; incr i
            if {[{*}$tick $done $total]} { set cancelled 1 ; break }
        }
        close $ch
    }
    # the root again (it was computed at open; a kit opened with -force may not match)
    set rootState $H($h,rootState)
    if {$rootState ne "ok"} { lappend bad [list "" root "the content does not match the seal's root hash"] }
    set sig $H($h,sig)
    set ok [expr {!$cancelled && ![llength $bad]}]
    return [dict create ok $ok cancelled $cancelled bad $bad root $rootState signature [dict get $sig state] \
        signatureDetail [dict get $sig detail] image $imageState chunks $chunks bytes $done total $total]
}

proc ::kitfmt::VerifyBatch {h batch} {
    variable H
    set datas {} ; set bad {}
    foreach item $batch {
        lassign $item p i
        set e [dict get $H($h,entries) $p]
        lappend datas [mk::get [dict get $e row].chunks!$i z]
    }
    set hashes [HashMany $datas]
    foreach item $batch got $hashes z $datas {
        lassign $item p i
        set e [dict get $H($h,entries) $p]
        if {$got ne [lindex [dict get $e hashes] $i]} { lappend bad [list $p $i "chunk $i does not match its hash"] ; continue }
        if {[dict get $e codec] eq "deflate"} {
            set csize [dict get $e csize]
            set plain [expr {$i < [dict get $e chunks] - 1 ? $csize : [dict get $e size] - $i * wide($csize)}]
            if {[catch {Inflate $z $plain "$p chunk $i"} err]} { lappend bad [list $p $i $err] }
        } elseif {[dict get $e codec] eq "zstd"} {
            # hash checked; decoding needs a zstd decoder this reader does not have
        }
    }
    return $bad
}

package provide kitfmt $::kitfmt::version
