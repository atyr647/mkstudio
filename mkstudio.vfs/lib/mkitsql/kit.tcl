# kit.tcl -- the kit.* virtual tables: a Ribbon kit file (docs/KIT-FORMAT.md in atyr647/ribbon) seen through SQL.
#
#   SELECT path, size, codec, chunks FROM kit.files WHERE type = 'file' ORDER BY size DESC
#   SELECT * FROM kit.verify WHERE ok = 0
#
# The kit is the statement's default database when its file is a kit, otherwise the one open database that is a kit.  The
# tables are registered always (vtab.tcl); reading one needs the kitfmt package, Ribbon's reference reader, which is NOT
# part of mkit-sql: it is loaded with `package require kitfmt` the first time a kit.* table is read, and a clear error says
# so if it is missing (MK Studio carries it; elsewhere put kit/kitfmt on auto_path).  Reasons: kitfmt is maintained with the
# format spec, an application pins both packages (one copy of each in a process), and SQL users without kits load nothing.
#
# kitfmt opens the kit read-only on its own (never through the storage layer: no lock, no checksum file), verifies the seal
# and the root hash, and never fetches a chunk whole without checking its size.  A kit whose root does not match is still
# opened (kit.info says root_state mismatch, kit.verify fails), so a damaged kit can be looked at.

namespace eval ::mkitsql::kit {
    variable handles            ;# handles(path) = {kitfmt-handle mtime size}
    array set handles {}
}

proc ::mkitsql::kit::need {} {
    if {[llength [info commands ::kitfmt]]} return
    if {[catch {package require kitfmt 1}]} {
        error "the kit.* tables need the kitfmt package (Ribbon's kit/kitfmt reader), which is not installed here; add its directory to auto_path"
    }
}

# the kit a statement means: its default database's file if that is a kit, else the only open database that is one
proc ::mkitsql::kit::target {db} {
    need
    set tags [::mkitsql::db::tags]
    if {$db ne "" && [lsearch -exact $tags $db] >= 0} {
        set p [::mkitsql::db::path $db]
        if {[dict get [kitfmt probe $p] kit]} { return $p }
    }
    set kits {}
    foreach tag $tags {
        set p [::mkitsql::db::path $tag]
        if {[dict get [kitfmt probe $p] kit]} { lappend kits $tag $p }
    }
    if {![llength $kits]} { error "no open database is a kit" }
    if {[llength $kits] > 2} {
        set names {} ; foreach {t p} $kits { lappend names $t }
        error "more than one open database is a kit ([join $names {, }]): make the one you mean the statement's default database"
    }
    return [lindex $kits 1]
}

# an open kitfmt handle for the kit, reopened when the file changed
proc ::mkitsql::kit::handle {db} {
    variable handles
    set p [target $db]
    set stamp [list [file mtime $p] [file size $p]]
    if {[info exists handles($p)]} {
        lassign $handles($p) h mt sz
        if {[list $mt $sz] eq $stamp} { return $h }
        catch {kitfmt close $h}
        unset handles($p)
    }
    set h [kitfmt open $p -force 1]
    set handles($p) [concat [list $h] $stamp]
    return $h
}

# close every kit opened here (the kits stay readable: they are opened again when a kit.* table is next read)
proc ::mkitsql::kit::forget {} {
    variable handles
    foreach p [array names handles] { catch {kitfmt close [lindex $handles($p) 0]} }
    array unset handles
    return
}

proc ::mkitsql::kit::rows {what ctx} {
    set h [handle [dict get $ctx db]]
    switch -- $what {
        info {
            set i [kitfmt info $h]
            set sig [dict get $i signature]
            set out {}
            foreach {k v} [list format [join [dict get $i format] .] requires [dict get $i requires] kind [dict get $i kind] \
                    name [dict get $i name] version [dict get $i version] root [dict get $i root] root_state [dict get $i rootState] \
                    signature [dict get $sig state] signer [dict get $sig keyid] signature_comment [dict get $sig comment] \
                    header [dict get $i header] store_start [dict get $i store start] entries [dict get $i entries] \
                    bytes [dict get $i bytes] stored [dict get $i stored] chunks [dict get $i chunks] image [dict get $i image] \
                    writer [dict get $i writer] path [dict get $i path]] {
                lappend out [list $k $v]
            }
            return $out
        }
        manifest {
            set out {}
            dict for {k v} [dict get [kitfmt manifest $h] fields] { lappend out [list $k $v] }
            return $out
        }
        needs - provides - entries - effects { return [dict get [kitfmt manifest $h] $what] }
        perms { return [dict get [kitfmt manifest $h] perms] }
        files {
            set out {}
            foreach p [kitfmt walk $h] {
                set s [kitfmt stat $h $p]
                set row [list $p [dict get $s type] "" [dict get $s mode] "" "" "" "" "" ""]
                switch -- [dict get $s type] {
                    file {
                        set row [list $p file [dict get $s size] [dict get $s mode] [dict get $s date] [dict get $s codec] \
                            [dict get $s csize] [dict get $s chunks] [dict get $s stored] ""]
                    }
                    link { set row [list $p link 0 [dict get $s mode] [dict get $s date] "" "" 0 0 [dict get $s link]] }
                }
                lappend out $row
            }
            return $out
        }
        chunks {
            set out {}
            foreach p [kitfmt walk $h] {
                if {[dict get [kitfmt stat $h $p] type] ne "file"} continue
                foreach c [kitfmt chunks $h $p] { lappend out [concat [list $p] $c] }
            }
            return $out
        }
        image {
            set im [kitfmt image $h]
            if {$im eq ""} { return {} }
            return [list [list [dict get $im fs] [dict get $im offset] [dict get $im length] [dict get $im pad] \
                [dict get $im seg] [dict get $im segments] [dict get $im verity] [dict get $im salt]]]
        }
        verify {
            set v [kitfmt verify $h]
            set badf [dict create] ; set badp [dict create]
            foreach b [dict get $v bad] {
                lassign $b p what detail
                if {$p eq ""} { dict lappend badp $what $detail } else { dict lappend badf $p $detail }
            }
            set out {}
            foreach part {header root image signature} {
                switch -- $part {
                    image { if {[dict get $v image] eq "none"} continue }
                    signature {
                        set st [dict get $v signature]
                        lappend out [list signature "" [expr {$st eq "valid"}] "$st: [dict get $v signatureDetail]"]
                        continue
                    }
                }
                if {[dict exists $badp $part]} { lappend out [list $part "" 0 [join [dict get $badp $part] "; "]] } \
                else { lappend out [list $part "" 1 ok] }
            }
            foreach p [kitfmt walk $h] {
                if {[dict get [kitfmt stat $h $p] type] ne "file"} continue
                if {[dict exists $badf $p]} { lappend out [list file $p 0 [join [dict get $badf $p] "; "]] } \
                else { lappend out [list file $p 1 ok] }
            }
            return $out
        }
    }
    error "kit: no table $what"
}

foreach {t cols} {
    info     {{key text} {value text}}
    manifest {{key text} {value text}}
    needs    {{name text} {range text}}
    provides {{name text} {version text}}
    perms    {{name text} {value text}}
    entries  {{name text} {path text} {args text} {type text}}
    effects  {{type text} {value text}}
    files    {{path text} {type text} {size int} {mode int} {date int} {codec text} {csize int} {chunks int} {stored int} {link text}}
    chunks   {{path text} {idx int} {stored int} {hash text}}
    image    {{fs text} {file_offset int} {length int} {pad int} {seg int} {segments int} {verity text} {salt text}}
    verify   {{part text} {path text} {ok int} {detail text}}
} {
    ::mkitsql::registerVirtual kit $t $cols [list ::mkitsql::kit::rows $t]
}
unset t cols
