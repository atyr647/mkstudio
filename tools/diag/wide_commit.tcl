# TEMPORARY diagnostic (Windows hang in test_wide's column-guard commit with the 64-bit Metakit):   tclkit wide_commit.tcl <experiment> <logfile>
# Every marker is appended and closed at once, so the last line says where a hang was.
package require Mk4tcl
lassign $argv exp log
proc m {s} { global log ; set h [open $log a] ; puts $h "[clock milliseconds] $s" ; close $h }
set here [file dirname [file normalize [info script]]]
set dir [file join [expr {[info exists ::env(RUNNER_TEMP)] ? $::env(RUNNER_TEMP) : "/tmp"}] diag_[pid]_$exp] ; file delete -force $dir ; file mkdir $dir
set blob [string repeat x 999]
m "start $exp"
switch -glob -- $exp {
    raw* {
        # raw Mk4tcl, no MK Studio code
        set rows 20 ; if {$exp eq "raw3"} { set rows 3 } ; if {$exp eq "raw2000"} { set rows 2000 }
        mk::file open db $dir/a.mk -nocommit
        mk::view layout db.t {k:I s:S b:B}
        m "opened"
        for {set i 0} {$i < $rows} {incr i} { mk::row append db.t k $i s $blob }
        m "appended $rows"
        if {$exp in {raw20b raw3 raw2000}} { mk::set db.t!0 b small ; m "set b" }
        if {$exp eq "rawbig"} { mk::set db.t!0 b [string repeat y 5000] ; m "set b 5000" }
        mk::file commit db
        m "committed"
        mk::file close db
        m "closed"
    }
    store - storenob {
        source $here/../../mkstudio.vfs/lib/app-mkstudio/store.tcl
        set ::store::durable 0
        set db [store::openFile $dir/a.mk -create]
        m "openFile"
        store::createView $db t {k:I s:S b:B}
        for {set i 0} {$i < 20} {incr i} { store::appendRow $db.t {k s} [list $i $blob] }
        m "appended"
        if {$exp ne "storenob"} { store::setCell $db.t 0 b small ; m "set b" }
        # store::commit, one call at a time
        set f $store::file($db)
        store::verifyLock $db ; m "verifyLock"
        set st [store::integrityState $db] ; m "integrityState $st"
        set bk [store::backupBeforeCommit $f] ; m "backupBeforeCommit $bk"
        set rec [store::beginCommit $f] ; m "beginCommit $rec"
        mk::file commit $db ; m "mk::file commit"
        if {$rec} { store::endCommit $f ; m "endCommit" }
        store::closeFile $db ; m "closed"
    }
    storeguard {
        # exactly the column-guard section of test_wide
        source $here/../../mkstudio.vfs/lib/app-mkstudio/store.tcl
        set ::store::durable 0
        set ::store::wideCap 1 ; set ::store::maxColumnBytes 20000 ; set ::store::guardSlack 0
        set db [store::openFile $dir/g.mk -create] ; m "openFile"
        store::createView $db t {k:I s:S b:B}
        set n 0
        for {set i 0} {$i < 40} {incr i} { if {[catch {store::appendRow $db.t {k s} [list $i $blob]} mm opts]} break ; incr n }
        m "appended $n, refused: [string range $mm 0 40]"
        catch {store::setCell $db.t 0 s [string repeat y 999]} mm ; m "setCell s: [string range $mm 0 30]"
        catch {store::setCell $db.t 0 b small} mm ; m "setCell b: $mm"
        catch {store::updateRows $db.t [dict create 0 [list s [string repeat z 999]]]} mm ; m "updateRows: [string range $mm 0 30]"
        store::commit $db ; m "commit"
        store::rollback $db ; m "rollback"
        store::closeFile $db ; m "closed"
    }
}
m "done $exp"
file delete -force $dir
exit 0
