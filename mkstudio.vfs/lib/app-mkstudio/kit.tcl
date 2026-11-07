# kit.tcl -- the Kit tab: a Ribbon kit (.kit) seen the way kit sees it, next to its raw views.
#
# A kit is a Metakit starkit with a signed seal in front of its store, its files in hashed deflate chunks, and - for a
# system kit - an embedded filesystem image (atyr647/ribbon docs/KIT-FORMAT.md).  The tab is read through kitfmt, Ribbon's
# reference reader (mkstudio.vfs/lib/kitfmt, vendored at a pinned commit: tools/sync-kitfmt.sh), never through the store, and
# it never writes: kits are opened read-only and nothing is put next to them.
#
#   Files      the tree with sizes, codecs and chunk counts; a preview of text, PNG/GIF images and other bytes (as hex)
#   Manifest   identity, needs, provides, permission requests, entry points, effects, seal and signature
#   Verify     every chunk, the image, the header, the root and the signature, in a separate process (Metakit can crash on
#              damaged data; that must not take MK Studio with it), with progress and Cancel
#   Image      a system kit's embedded image: filesystem, offset, length, dm-verity root
#   Extract    a file, a folder or everything, into a folder you pick (names and links checked by kitfmt)
#
# Signatures: kitfmt reports "unchecked" unless it is told which keys to trust; Ribbon has no key infrastructure yet, so the
# trusted minisign public keys come from MKS_KIT_KEYS (space separated) for now.

namespace eval ::kitdoc {
    variable K                 ;# K(<doc id>,<field>)
    array set K {}
    variable have -1
    variable previewMax 65536  ;# bytes read for a preview
    variable imageMax 4194304  ;# images up to this size are shown
    variable stallSeconds 120  ;# the verifier is stopped when it reports nothing for this long
}

# is kitfmt there (it is in every build; a host that assembles the files itself may lack it)?
proc ::kitdoc::available {} {
    variable have
    if {$have < 0} {
        set have [expr {![catch {package require kitfmt 1}]}]
        if {$have && [info exists ::env(MKS_KIT_KEYS)] && [string trim $::env(MKS_KIT_KEYS)] ne ""} {
            catch {kitfmt configure -keys [split [string trim $::env(MKS_KIT_KEYS)]]}
        }
    }
    return $have
}
proc ::kitdoc::isKit {path} {
    if {![available]} { return 0 }
    if {[catch {kitfmt probe $path} p]} { return 0 }
    return [dict get $p kit]
}

proc ::kitdoc::fmtBytes {n} {
    if {$n eq ""} { return "" }
    if {$n < 1024} { return "$n B" }
    foreach u {KB MB GB TB} {
        set n [expr {$n / 1024.0}]
        if {$n < 1024} { return [format "%.1f %s" $n $u] }
    }
    return [format "%.1f PB" [expr {$n / 1024.0}]]
}
proc ::kitdoc::fmtMode {m} { if {$m eq ""} { return "" } ; return [format %04o $m] }

# ============================================================================
#  building the tab
# ============================================================================
proc ::kitdoc::create {id f tag} {
    variable K
    set path [::store::path $tag]
    set K($id,tag) $tag ; set K($id,path) $path ; set K($id,chan) "" ; set K($id,busy) 0 ; set K($id,stop) 0
    ttk::frame $f -style Surface.TFrame
    if {[catch {kitfmt open $path -force 1} h]} {
        set K($id,h) ""
        ttk::label $f.err -style Error.TLabel -padding {16 16} -wraplength [::theme::px 700] \
            -text "This file looks like a kit, but it cannot be read as one:\n\n$h\n\nIts Metakit views are still in the Object Explorer."
        pack $f.err -side top -anchor nw
        return $f
    }
    set K($id,h) $h
    set info [kitfmt info $h]
    set K($id,info) $info

    # header: who it is, and the state of its seal
    ttk::frame $f.head -style Surface.TFrame -padding {16 12 16 6}
    ttk::label $f.head.title -style Title.TLabel -text "[dict get $info name]  [dict get $info version]"
    ttk::label $f.head.sub -style SurfaceDim.TLabel -text [summaryLine $info]
    ttk::label $f.head.seal -style Surface.TLabel -text [sealLine $info]
    pack $f.head.title $f.head.sub $f.head.seal -side top -anchor w
    # toolbar
    ttk::frame $f.bar -style Surface.TFrame -padding {12 2 12 6}
    foreach {b text icon cmd} {
        verify  "Verify"          check   verify
        extract "Extract..."      open    extractSelected
        all     "Extract All..."  folder  extractAll
        cancel  "Cancel"          stop    cancel
    } {
        ttk::button $f.bar.$b -text $text -image [::icons::get $icon] -compound left \
            -style ToolSurface.TButton -command [list ::kitdoc::$cmd $id]
        pack $f.bar.$b -side left -padx {0 2}
    }
    $f.bar.cancel state disabled
    ::tip::attach $f.bar.verify "Check every chunk, the image, the header and the root hash against the seal"
    ::tip::attach $f.bar.extract "Copy the selected file or folder out of the kit"
    # info bar, with the progress of a verify or an extraction
    ttk::frame $f.info -style Panel.TFrame -padding {12 4}
    ttk::label $f.info.l -style PanelDim.TLabel -text "Read-only. Kits are only ever written by kit itself."
    ttk::progressbar $f.info.p -orient horizontal -length [::theme::px 220] -mode determinate -maximum 1000
    pack $f.info.l -side left
    # pages
    ::tabs::create $f.tabs -small 1 -closable 0 -bg panel -select [list ::kitdoc::showPage $id]
    ttk::frame $f.body -style Surface.TFrame
    grid rowconfigure $f.body 0 -weight 1 ; grid columnconfigure $f.body 0 -weight 1
    pack $f.head -side top -fill x
    pack $f.bar -side top -fill x
    pack $f.tabs -side top -fill x
    pack $f.info -side bottom -fill x
    pack $f.body -side top -fill both -expand 1

    buildFiles $id $f.body.files
    buildManifest $id $f.body.manifest
    buildVerify $id $f.body.verify
    set pages {files Files folder manifest Manifest doc verify Verify check}
    if {[dict get $info image]} { buildImage $id $f.body.image ; lappend pages image Image db }
    foreach {pid title icon} $pages {
        grid $f.body.$pid -row 0 -column 0 -sticky nsew
        ::tabs::add $f.tabs $pid $title $icon
    }
    showPage $id files
    return $f
}

proc ::kitdoc::summaryLine {info} {
    set kind [expr {[dict get $info kind] eq "system" ? "System kit" : "App kit"}]
    set s "$kind  \u00B7  format [join [dict get $info format] .]  \u00B7  [dict get $info entries] entries  \u00B7  "
    append s "[fmtBytes [dict get $info bytes]] in [dict get $info chunks] chunks ([fmtBytes [dict get $info stored]] stored)"
    if {[dict get $info header] > 0} { append s "  \u00B7  [fmtBytes [dict get $info header]] starkit header" }
    return $s
}
proc ::kitdoc::sealLine {info} {
    set sig [dict get $info signature]
    set root [expr {[dict get $info rootState] eq "ok" ? "content matches the seal" : "CONTENT DOES NOT MATCH THE SEAL"}]
    set st [dict get $sig state]
    switch -- $st {
        valid     { set s "Signed by trusted key [dict get $sig keyid]" }
        unchecked { set s "Signed by key [dict get $sig keyid] (not checked: no trusted keys are set up)" }
        untrusted { set s "Signed by key [dict get $sig keyid], which is not trusted" }
        unsigned  { set s "Not signed (a development kit)" }
        default   { set s "BAD SIGNATURE ([dict get $sig detail])" }
    }
    return "$s  \u00B7  $root"
}

proc ::kitdoc::showPage {id pid} {
    set f [::app::docFrame $id]
    raise $f.body.$pid
    ::tabs::select $f.tabs $pid
}

proc ::kitdoc::tree {w cols} {
    ttk::frame $w -style Surface.TFrame
    ttk::treeview $w.t -style Grid.Treeview -columns [dict keys $cols] -show {tree headings} -selectmode browse \
        -yscrollcommand [list $w.v set]
    ::ui::hoverTree $w.t
    ttk::scrollbar $w.v -orient vertical -command [list $w.t yview]
    dict for {c spec} $cols {
        lassign $spec title width anchor
        $w.t heading $c -text $title -anchor $anchor
        $w.t column $c -width [::theme::px $width] -anchor $anchor -stretch [expr {$width >= 300}]
    }
    pack $w.v -side right -fill y
    pack $w.t -side left -fill both -expand 1
    return $w.t
}

# ---- Files ---------------------------------------------------------------------------------------------------------------
proc ::kitdoc::buildFiles {id w} {
    variable K
    ttk::panedwindow $w -orient horizontal
    set t [tree $w.tree {size {Size 76 e} chunks {Chunks 56 e} codec {Codec 64 w} stored {Stored 76 e}}]
    $t heading #0 -text "Path" -anchor w
    $t column #0 -width [::theme::px 240] -stretch 1
    ttk::frame $w.pv -style Surface.TFrame
    ttk::label $w.pv.l -style SurfaceDim.TLabel -padding {10 6} -text "Select a file to preview it."
    text $w.pv.t -width 60 -height 12 -font MkMono -borderwidth 0 -highlightthickness 0 -padx 10 -pady 8 \
        -wrap none -state disabled -yscrollcommand [list $w.pv.v set]
    ttk::scrollbar $w.pv.v -orient vertical -command [list $w.pv.t yview]
    label $w.pv.img -borderwidth 0
    ::theme::reg $w.pv.t {%w configure -background $::theme::c(editor) -foreground $::theme::c(fg) -selectbackground $::theme::c(sel)}
    ::theme::reg $w.pv.img {%w configure -background $::theme::c(surface)}
    pack $w.pv.l -side top -anchor w -fill x
    pack $w.pv.v -side right -fill y
    pack $w.pv.t -side left -fill both -expand 1
    $w add $w.tree -weight 1
    $w add $w.pv -weight 1
    set K($id,ftree) $t ; set K($id,pv) $w.pv ; set K($id,img) ""
    fillTree $id $t "" ""
    bind $t <<TreeviewSelect>> [list ::kitdoc::preview $id]
    bind $t <Double-1> [list ::kitdoc::extractSelected $id]
}
proc ::kitdoc::fillTree {id t parent dir} {
    variable K
    foreach p [kitfmt list $K($id,h) $dir] {
        set s [kitfmt stat $K($id,h) $p]
        set name [string range $p [expr {[string last / $p] + 1}] end]
        switch -- [dict get $s type] {
            dir {
                set item [$t insert $parent end -id $p -text " $name" -image [::icons::get folder] -open [expr {$dir eq ""}]]
                fillTree $id $t $item $p
            }
            link { $t insert $parent end -id $p -text " $name  \u2192 [dict get $s link]" -image [::icons::get blank] -values {"" "" link ""} }
            file {
                $t insert $parent end -id $p -text " $name" -image [::icons::get doc] \
                    -values [list [fmtBytes [dict get $s size]] [dict get $s chunks] [dict get $s codec] [fmtBytes [dict get $s stored]]]
            }
        }
    }
}

proc ::kitdoc::preview {id} {
    variable K ; variable previewMax ; variable imageMax
    set pv $K($id,pv) ; set t $pv.t
    set p [lindex [$K($id,ftree) selection] 0]
    pack forget $pv.img
    if {![winfo ismapped $t]} { pack $pv.v -side right -fill y ; pack $t -side left -fill both -expand 1 }
    if {$K($id,img) ne ""} { catch {image delete $K($id,img)} ; set K($id,img) "" }
    $t configure -state normal ; $t delete 1.0 end
    if {$p eq ""} { $t configure -state disabled ; return }
    set s [kitfmt stat $K($id,h) $p]
    switch -- [dict get $s type] {
        dir {
            $pv.l configure -text "$p/  \u00B7  folder, [llength [kitfmt list $K($id,h) $p]] entries, mode [fmtMode [dict get $s mode]]"
            $t configure -state disabled ; return
        }
        link {
            $pv.l configure -text "$p  \u00B7  symbolic link"
            $t insert end "\u2192 [dict get $s link]"
            $t configure -state disabled ; return
        }
    }
    set n [dict get $s size]
    $pv.l configure -text "$p  \u00B7  [fmtBytes $n], mode [fmtMode [dict get $s mode]], [dict get $s codec], [dict get $s chunks] chunk(s)  \u00B7  [clock format [dict get $s date] -format {%Y-%m-%d %H:%M}]"
    # only the chunks the preview needs are read, and each is checked against its hash first
    set want [expr {min($n, $previewMax)}]
    if {[catch {kitfmt read $K($id,h) $p 0 $want} data]} {
        $t insert end "This file cannot be read:\n\n$data"
        $t configure -state disabled ; return
    }
    if {$n == 0} { $t insert end "(empty)" ; $t configure -state disabled ; return }
    set magic [string range $data 0 7]
    if {($magic eq "\x89PNG\r\n\x1a\n" || [string range $magic 0 3] eq "GIF8") && $n <= $imageMax} {
        if {$n > $want} { set data [kitfmt read $K($id,h) $p] }
        if {![catch {image create photo -data $data} img]} {
            set K($id,img) $img
            $pv.img configure -image $img
            pack forget $pv.v $t
            pack $pv.img -side top -anchor nw -padx 10 -pady 8
            return
        }
    }
    if {[string first \x00 $data] < 0 && ![catch {encoding convertfrom utf-8 $data} text] && ![regexp {[\x01-\x08\x0e-\x1f]} $text]} {
        $t insert end $text
        if {$n > $want} { $t insert end "\n\n... [fmtBytes [expr {$n - $want}]] more (Extract to see all)" }
    } else {
        $t insert end [::bytes::dump $data $n]
    }
    $t configure -state disabled
}

# ---- Manifest ------------------------------------------------------------------------------------------------------------
proc ::kitdoc::buildManifest {id w} {
    variable K
    set t [tree $w {value {Value 420 w}}]
    $t heading #0 -text "Field" -anchor w
    $t column #0 -width [::theme::px 260]
    set m [kitfmt manifest $K($id,h)]
    set info $K($id,info)
    set sec [$t insert {} end -text "IDENTITY" -open 1]
    dict for {k v} [dict get $m fields] { $t insert $sec end -text $k -values [list $v] }
    foreach {key title fmt} {needs NEEDS {%s %s} provides PROVIDES {%s %s} perms "PERMISSION REQUESTS" {%s} entries "ENTRY POINTS" {%s} effects EFFECTS {%s}} {
        set rows [dict get $m $key]
        set sec [$t insert {} end -text "$title ([llength $rows])" -open 1]
        foreach r $rows {
            switch -- $key {
                perms   { $t insert $sec end -text [lindex $r 0] -values [list [lindex $r 1]] }
                entries { $t insert $sec end -text [lindex $r 0] -values [list "[lindex $r 1] [lindex $r 2]  ([lindex $r 3])"] }
                default { $t insert $sec end -text [lindex $r 0] -values [list [lindex $r 1]] }
            }
        }
    }
    set sig [dict get $info signature]
    set sec [$t insert {} end -text "SEAL" -open 1]
    foreach {k v} [list Format "[join [dict get $info format] .] [dict get $info requires]" Root [dict get $info root] \
            "Root state" [dict get $info rootState] Signature [dict get $sig state] Signer [dict get $sig keyid] \
            "Trusted comment" [dict get $sig comment] Detail [dict get $sig detail] Writer [dict get $info writer] \
            "Header" "[dict get $info header] bytes" "Store starts at" [dict get $info store start]] {
        $t insert $sec end -text $k -values [list $v]
    }
}

# ---- Image (system kits) ----------------------------------------------------------------------------------------------------
proc ::kitdoc::buildImage {id w} {
    variable K
    set t [tree $w {value {Value 420 w}}]
    $t heading #0 -text "Embedded image" -anchor w
    $t column #0 -width [::theme::px 260]
    set im [kitfmt image $K($id,h)]
    foreach {k v} [list Filesystem [dict get $im fs] "File offset" "[dict get $im offset] (4 KiB aligned: [expr {[dict get $im offset] % 4096 == 0 ? {yes} : {NO}}])" \
            Length "[dict get $im length] ([fmtBytes [dict get $im length]])" Pad [dict get $im pad] \
            "Segments" "[dict get $im segments] of [fmtBytes [dict get $im seg]], each with a SHA-256" \
            "dm-verity root" [expr {[dict get $im verity] eq "" ? "(none)" : [dict get $im verity]}] \
            "dm-verity salt" [dict get $im salt] \
            "Mount (as root)" "losetup -r -o [dict get $im offset] --sizelimit [dict get $im length] -f --show <kit>, then mount -t [dict get $im fs]"] {
        $t insert {} end -text $k -values [list $v]
    }
}

# ---- Verify ----------------------------------------------------------------------------------------------------------------
proc ::kitdoc::buildVerify {id w} {
    variable K
    set t [tree $w {state {Result 90 w} detail {Detail 420 w}}]
    $t heading #0 -text "Part" -anchor w
    $t column #0 -width [::theme::px 300]
    $t tag configure bad -foreground $::theme::c(bad)
    $t tag configure good -foreground $::theme::c(ok)
    ::theme::reg $t {%w tag configure bad -foreground $::theme::c(bad) ; %w tag configure good -foreground $::theme::c(ok)}
    $t insert {} end -text "Not verified yet" -values {"" "Press Verify to check every chunk against the seal."}
    set K($id,vtree) $t
}

# the command that verifies a kit in a separate process: this program itself (a starpack runs its main.tcl), or, unwrapped,
# the Tcl shell it runs on with main.tcl (a tclsh next to a wish, so no window opens)
proc ::kitdoc::childCommand {path} {
    set exe [info nameofexecutable]
    if {[lindex [file system $::mkstudio_root] 0] ne "native"} { return [list $exe --kitverify $path] }
    if {[string match wish* [file tail $exe]]} {
        set tclsh [file join [file dirname $exe] [string map {wish tclsh} [file tail $exe]]]
        if {[file executable $tclsh]} { set exe $tclsh }
    }
    return [list $exe [file join $::mkstudio_root main.tcl] --kitverify $path]
}

proc ::kitdoc::setBusy {id on {what ""}} {
    variable K
    set f [::app::docFrame $id]
    set K($id,busy) $on
    foreach b {verify extract all} { $f.bar.$b state [expr {$on ? "disabled" : "!disabled"}] }
    $f.bar.cancel state [expr {$on ? "!disabled" : "disabled"}]
    if {$on} {
        $f.info.p configure -value 0
        pack $f.info.p -side right
        $f.info.l configure -text $what
    } else { pack forget $f.info.p }
}
proc ::kitdoc::progress {id done total} {
    set f [::app::docFrame $id]
    if {![winfo exists $f.info.p]} return
    $f.info.p configure -value [expr {$total > 0 ? int(1000.0 * $done / $total) : 0}]
}

proc ::kitdoc::verify {id} {
    variable K ; variable stallSeconds
    if {$K($id,h) eq "" || $K($id,busy)} return
    showPage $id verify
    set lib ""
    foreach l [info loaded] { if {[lindex $l 1] eq "Mk4tcl" && [lindex $l 0] ne ""} { set lib [lindex $l 0] } }
    set ::env(MKS_KIT_MK4TCL) $lib
    set rc [catch {open |[concat [childCommand $K($id,path)] [list 2>@1]] r} ch]
    unset -nocomplain ::env(MKS_KIT_MK4TCL)
    if {$rc} { ::ui::problem "The verifier could not be started:\n\n$ch" "Verify kit" ; return }
    fconfigure $ch -blocking 0 -buffering line -translation lf
    set K($id,chan) $ch ; set K($id,out) "" ; set K($id,result) "" ; set K($id,last) [clock seconds]
    setBusy $id 1 "Verifying in a separate process..."
    fileevent $ch readable [list ::kitdoc::childRead $id]
    set K($id,watch) [after 1000 [list ::kitdoc::watchdog $id]]
}
proc ::kitdoc::watchdog {id} {
    variable K ; variable stallSeconds
    if {![info exists K($id,chan)] || $K($id,chan) eq ""} return
    if {[clock seconds] - $K($id,last) > $stallSeconds} {
        childStop $id
        verifyDone $id "" "The verifier reported nothing for $stallSeconds seconds and was stopped (a damaged kit can make Metakit loop)."
        return
    }
    set K($id,watch) [after 1000 [list ::kitdoc::watchdog $id]]
}
proc ::kitdoc::childRead {id} {
    variable K
    set ch $K($id,chan)
    while {[gets $ch line] >= 0} {
        set K($id,last) [clock seconds]
        if {[regexp {^P (\d+) (\d+)$} $line -> d t]} { progress $id $d $t
        } elseif {[string match "R *" $line]} { set K($id,result) [string range $line 2 end]
        } else { append K($id,out) $line "\n" }
    }
    if {![eof $ch]} return
    fconfigure $ch -blocking 1
    set rc [catch {close $ch} cmsg]
    set K($id,chan) ""
    catch {after cancel $K($id,watch)}
    if {$K($id,result) ne ""} { verifyDone $id $K($id,result) "" ; return }
    set why [string trim $K($id,out)]
    if {$why eq ""} { set why [expr {$rc ? $cmsg : "no result"}] }
    verifyDone $id "" "The verifier stopped without a result (Metakit may have crashed on damaged data; MK Studio is unaffected):\n$why"
}
proc ::kitdoc::childStop {id} {
    variable K
    set ch $K($id,chan)
    if {$ch eq ""} return
    set K($id,chan) ""
    catch {after cancel $K($id,watch)}
    foreach pid [pid $ch] {
        catch {if {$::tcl_platform(platform) eq "windows"} { exec taskkill /F /PID $pid } else { exec kill -9 $pid }}
    }
    catch {close $ch}
}
proc ::kitdoc::verifyDone {id res err} {
    variable K
    if {![info exists K($id,vtree)]} return
    setBusy $id 0
    set t $K($id,vtree)
    $t delete [$t children {}]
    set f [::app::docFrame $id]
    if {$err ne ""} {
        $t insert {} end -text "Verification failed" -values [list FAILED $err] -tags bad
        $f.info.l configure -text "Verification did not finish."
        set K($id,verified) ""
        return
    }
    set K($id,verified) $res
    if {[dict get $res cancelled]} {
        $f.info.l configure -text "Verification cancelled."
        $t insert {} end -text "Cancelled" -values {"" "Press Verify to start again."}
        return
    }
    set bad [dict get $res bad]
    set badPaths [dict create]
    foreach b $bad { lassign $b p what detail ; if {$p ne ""} { dict lappend badPaths $p $detail } }
    set partBad [dict create]
    foreach b $bad { lassign $b p what detail ; if {$p eq ""} { dict lappend partBad $what $detail } }
    foreach {part label} {header Header root "Root hash" image "Embedded image" signature Signature} {
        if {$part eq "image" && [dict get $res image] eq "none"} continue
        if {$part eq "signature"} {
            set st [dict get $res signature]
            set tg [expr {$st eq "valid" ? "good" : ($st in {invalid} ? "bad" : "")}]
            $t insert {} end -text $label -values [list $st [dict get $res signatureDetail]] -tags $tg
            continue
        }
        if {[dict exists $partBad $part]} {
            $t insert {} end -text $label -values [list BAD [join [dict get $partBad $part] "; "]] -tags bad
        } else { $t insert {} end -text $label -values {ok ""} -tags good }
    }
    set files [$t insert {} end -text "Files ([dict get $res chunks] chunks, [fmtBytes [dict get $res bytes]])" -open 1]
    foreach p [kitfmt walk $K($id,h)] {
        if {[dict get [kitfmt stat $K($id,h) $p] type] ne "file"} continue
        if {[dict exists $badPaths $p]} {
            $t insert $files end -text $p -values [list BAD [join [dict get $badPaths $p] "; "]] -tags bad
        } else { $t insert $files end -text $p -values {ok ""} -tags good }
    }
    if {[dict get $res ok]} {
        $f.info.l configure -text "Verified: every chunk matches the seal ([dict get $res chunks] chunks).  Signature: [dict get $res signature]."
        ::app::setStatus "Kit verified: no damage found." ok
    } else {
        $f.info.l configure -text "DAMAGED: [llength $bad] problem(s) found."
        ::app::setStatus "Kit verification found [llength $bad] problem(s)." warn
    }
}
proc ::kitdoc::cancel {id} {
    variable K
    if {$K($id,chan) ne ""} {
        childStop $id
        verifyDone $id [dict create cancelled 1 ok 0 bad {}] ""
    }
    set K($id,stop) 1
}

# ---- Extract ----------------------------------------------------------------------------------------------------------------
proc ::kitdoc::extractSelected {id} {
    variable K
    if {$K($id,h) eq ""} return
    set p [lindex [$K($id,ftree) selection] 0]
    if {$p eq ""} { ::app::setStatus "Select a file or folder in the Files page first." warn ; return }
    extract $id $p
}
proc ::kitdoc::extractAll {id} { variable K ; if {$K($id,h) ne ""} { extract $id "" } }
proc ::kitdoc::extract {id p {dest ""}} {
    variable K
    if {$K($id,busy)} return
    if {$dest eq ""} {
        set dest [tk_chooseDirectory -title "Extract [expr {$p eq "" ? "the whole kit" : $p}] into" -mustexist 1]
        if {$dest eq ""} return
    }
    set K($id,stop) 0
    setBusy $id 1 "Extracting [expr {$p eq "" ? "everything" : $p}]..."
    set rc [catch {kitfmt extract $K($id,h) $p $dest -progress [list ::kitdoc::extractTick $id]} n]
    setBusy $id 0
    set f [::app::docFrame $id]
    if {$rc} {
        $f.info.l configure -text "Extraction stopped."
        if {!$K($id,stop)} { ::ui::problem "Could not extract [expr {$p eq "" ? "the kit" : $p}]:\n\n$n" "Extract" }
        return 0
    }
    $f.info.l configure -text "Extracted $n entr[expr {$n == 1 ? "y" : "ies"}] into $dest"
    ::app::setStatus "Extracted $n entr[expr {$n == 1 ? "y" : "ies"}] into $dest" ok
    return $n
}
proc ::kitdoc::extractTick {id done total} {
    variable K
    progress $id $done $total
    update
    if {![info exists K($id,stop)] || $K($id,stop)} { return stop }
    return go
}

# ---- closing --------------------------------------------------------------------------------------------------------------
proc ::kitdoc::forget {id} {
    variable K
    if {[info exists K($id,chan)]} { childStop $id }
    if {[info exists K($id,h)] && $K($id,h) ne ""} { catch {kitfmt close $K($id,h)} }
    if {[info exists K($id,img)] && $K($id,img) ne ""} { catch {image delete $K($id,img)} }
    array unset K $id,*
}
proc ::kitdoc::tagOf {id} { variable K ; if {[info exists K($id,tag)]} { return $K($id,tag) } ; return "" }
