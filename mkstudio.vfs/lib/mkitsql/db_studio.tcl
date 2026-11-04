# db_studio.tcl -- the same storage interface as db.tcl, forwarded to MK Studio's ::store package.
#
# Loaded instead of db.tcl when MK Studio's store.tcl is present, so mkit-sql and MK Studio share one
# set of open files.  mkit-sql never reaches into ::store any other way.  Two Metakit behaviours that
# not every version of store.tcl covers are handled here:
#
#   * `mk::view delete` leaves the rows behind, so a table re-created under the same name came back WITH
#     ITS OLD ROWS.  dropView empties the view first - and abandons the drop if that fails (no catch).
#   * older store.tcl versions keep listing a dropped view until the next commit.

namespace eval ::mkitsql::db {}

proc ::mkitsql::db::available {} { ::store::available }
proc ::mkitsql::db::tags {} { ::store::tags }
proc ::mkitsql::db::path {tag} { ::store::path $tag }
proc ::mkitsql::db::readonly {tag} { ::store::readonly $tag }
proc ::mkitsql::db::dirty {tag} { ::store::dirty $tag }
proc ::mkitsql::db::touch {tag} { ::store::touch $tag }
proc ::mkitsql::db::openFile {path args} {
    set unchecked [expr {"-unchecked" in $args}] ; set verify [expr {"-verify" in $args}]
    set fargs {}
    foreach a $args { if {$a ni {-unchecked -verify}} { lappend fargs $a } }
    set real [file normalize $path]
    # a file over 2 GiB (wide format) that this Mk4tcl cannot read would look EMPTY (and the store would hide it behind a new commit)
    set why [::mkitsql::db::wideRefusal $real]
    if {$why ne ""} { return -code error -errorcode [list MKIT WIDEFILE] $why }
    # A newer MK Studio puts right an interrupted commit while it opens a file for writing (after taking the lock): the frame
    # check must then come AFTER the open, or it would refuse the very file that is about to be repaired.  An older one does not,
    # so its files are checked first.
    set repairs [llength [info commands ::store::repairFile]]
    set vlevel ""
    if {!$repairs} {
        if {!$unchecked && [file exists $real]} { ::mkitsql::dbRequireIntact $real }
        if {$verify && [file exists $real] && [file size $real] > 0} { set vlevel [::mkitsql::db::verifyWithSum $real] }
    }
    if {$repairs && !$unchecked && "-readonly" ni $args && [file exists $real]} {
        # the store repairs an interrupted commit when it opens for writing; make sure that repair cannot throw data away
        set why [::mkitsql::db::repairUnsafe $real]
        if {$why ne ""} {
            return -code error -errorcode [list MKIT DAMAGED $why] "This file does not look like an intact Metakit database ($why):\n$real\nIt was not opened, so nothing was changed. Open a backup, or pass -unchecked to open it anyway."
        }
    }
    set sp [::mkitsql::db::sumPath $real]
    if {![catch {file lstat $sp st}] && ($st(type) ne "file" || $st(size) > 4096)} { catch {file delete $sp} }
    set tag [::store::openFile $path {*}$fargs]
    # a store that keeps a checksum compares it when it opens a file for writing and REPORTS the verdict instead of refusing
    set verdict ""
    if {[llength [info commands ::store::integrityState]]} { set verdict [::store::integrityState $tag] }
    if {$verdict eq "damaged"} { set verdict [::mkitsql::db::studioVerdict $real damaged] }
    variable state ; set state($tag) $verdict
    if {$verdict eq "ok" && "-readonly" ni $args} { ::mkitsql::db::sumRestamp $real }
    if {!$unchecked && $verdict eq "damaged"} {
        catch {::store::closeFile $tag}
        return -code error -errorcode [list MKIT DAMAGED checksum] "This file does not look like what was last saved (its checksum no longer matches although its size and time are unchanged): part of it was damaged since.\n$real\nOpen a backup. (Pass -unchecked to open it anyway.)"
    }
    if {$repairs && [file exists $real] && [catch {
        if {!$unchecked} { ::mkitsql::dbRequireIntact $real }
        if {$verify && [file size $real] > 0} { set vlevel [::mkitsql::db::verifyWithSum $real $verdict [expr {"-readonly" in $args}]] }
    } err opts]} {
        catch {::store::closeFile $tag}
        return -options $opts $err
    }
    # Mk4tcl opens a damaged file as an empty database; the frame check catches most damage, this one catches a file that
    # opened with fewer views than its header promises
    if {!$unchecked && [file exists $real] && ![::mkitsql::dbSignatureOk $real [llength [mk::file views $tag]]]} {
        catch {::store::closeFile $tag}
        return -code error -errorcode [list MKIT DAMAGED "not a Metakit database"] "This file isn't a Metakit database, so it was not opened:\n$real"
    }
    variable level ; set level($tag) $vlevel
    ::mkitsql::db::wideCapable ; ::mkitsql::db::guardReset $tag 1
    return $tag
}
# MK Studio's store calls "damaged" what has the recorded size and time but another checksum; when the sum was written in the same second as the
# file's last change that cannot be told from another program's write in that second, so it only counts as damage if the sum is a second newer
proc ::mkitsql::db::studioVerdict {real v} {
    if {$v ne "damaged"} { return $v }
    set r [sumRead $real]
    if {$r eq ""} { return none }
    return [expr {[lindex $r 3] > [lindex $r 2] ? "damaged" : "changed"}]
}
# -verify on MK Studio's store: its own checksum (<file>.sum, written after every commit) is the proof when it is there and intact,
# otherwise the file is read in a helper process (evidence, not proof).  `verdict` is what the store found when it OPENED the file for writing
# (before it re-baselines a missing or changed sum - judging afterwards would call every file proven); a read-only open asks now.
# Returns "proven" or "evidence"; raises MKIT DAMAGED.
proc ::mkitsql::db::verifyWithSum {real {verdict ""} {readonly 1}} {
    if {[llength [info commands ::store::sumCheck]]} {
        if {$readonly} { if {[catch {::store::sumCheck $real} v]} { set v none } ; set v [studioVerdict $real $v] } else { set v $verdict }
        if {$v eq "damaged"} {
            return -code error -errorcode [list MKIT DAMAGED checksum] "This file does not look like what was last saved (its checksum no longer matches although its size and time are unchanged):\n$real\nOpen a backup."
        }
        if {$v eq "ok"} { return proven }
    }
    ::mkitsql::dbVerify $real
    return evidence
}
namespace eval ::mkitsql::db { variable level ; array set level {} ; variable state ; array set state {} }
# {state level} of an open file: level is "proven" (the checksum matched), "evidence" (read in a helper process without trouble: not a proof) or "" (-verify not asked)
proc ::mkitsql::db::integrityOf {tag} {
    variable level
    variable state
    set st [expr {[info exists state($tag)] ? $state($tag) : ""}]
    list $st [expr {[info exists level($tag)] ? $level($tag) : ""}]
}
# what was put right when the file was opened (an interrupted commit), "" if nothing
proc ::mkitsql::db::repairedNote {tag} { if {[llength [info commands ::store::repairedNote]]} { return [::store::repairedNote $tag] } ; return "" }
proc ::mkitsql::db::closeFile {tag} { variable level ; variable state ; unset -nocomplain level($tag) state($tag) ; ::store::closeFile $tag ; ::mkitsql::typeForget $tag ; ::mkitsql::db::guardForget $tag }
proc ::mkitsql::db::commit {tag} {
    if {[catch {::store::commit $tag} err opts]} {
        # a failed commit (a full disk, Metakit's 2 GiB limit): put the file right if this store can, discard the pending changes, and
        # say what happened - the handle must not be used on to a file Metakit may have left half written
        set path [::store::path $tag] ; set note ""
        if {[llength [info commands ::store::repairFile]]} {
            # close, put the file right, open it again under the same tag (the repair must come before Metakit reads it again)
            catch {mk::file close $tag}
            catch {::store::repairFile $path} note
            set opts {-nocommit}
            if {[::store::readonly $tag]} { lappend opts -readonly }
            catch {mk::file open $tag $path {*}$opts}
        }
        catch {::store::rollback $tag}
        ::mkitsql::typeForget $tag
        ::mkitsql::db::guardReset $tag 1
        set size [expr {[file exists $path] ? [file size $path] : 0}]
        return -code error -errorcode [list MKIT COMMITFAILED $size] "The commit failed ($err) - most likely the size limit of a Metakit file (2 GiB; a Mk4tcl built for big files has no such limit) or a full disk. The database file was put back to its last committed state where possible and the changes made since then were discarded (as ROLLBACK does). $note"
    }
}
proc ::mkitsql::db::rollback {tag} { ::store::rollback $tag ; guardReset $tag 1 }
proc ::mkitsql::db::layout {path} { ::store::layout $path }
proc ::mkitsql::db::size {path} { ::store::size $path }
proc ::mkitsql::db::subSize {path idx prop} { ::store::subSize $path $idx $prop }
proc ::mkitsql::db::appendRow {path props values} {
    variable wideCap
    if {$wideCap eq "1"} { guardWrite $path $props $values }
    ::store::appendRow $path $props $values
}
proc ::mkitsql::db::setCell {path idx prop value} {
    variable wideCap
    if {$wideCap eq "1"} { guardWrite $path [list $prop] [list $value] }
    ::store::setCell $path $idx $prop $value
}
proc ::mkitsql::db::deleteRows {path indices} { ::store::deleteRows $path $indices }
proc ::mkitsql::db::restructure {path layout} {
    if {[string first ! $path] < 0} { lassign [split $path .] tag view ; typeGuard $tag $view $layout }
    ::store::restructure $path $layout
    if {[string first ! $path] < 0} { ::mkitsql::typeRecord $tag $view $layout ; guardReset $tag 1 }
}
proc ::mkitsql::db::parseLayout {spec} { ::store::parseLayout $spec }
proc ::mkitsql::db::formatLayout {layout} { ::store::formatLayout $layout }

# Row indices (ascending) that satisfy ALL of `conds`, decided inside Metakit (in C, ~40x faster than looking at
# every row from Tcl).  conds = list of {exact|min|max column value}; min/max are inclusive.  The caller must pass
# values valid for the column's type.
proc ::mkitsql::db::select {path conds} {
    set args {}
    foreach c $conds { lassign $c op p v ; lappend args -$op $p $v }
    return [mk::select $path {*}$args]
}
proc ::mkitsql::db::deleteRange {path first count} {
    mk::row delete $path!$first $count
    ::store::touchPath $path
}
proc ::mkitsql::db::clearView {path} {
    mk::view size $path 0
    ::store::touchPath $path
}

# who holds the write lock (MK Studio's own advisory lock), for a file this handle opened read-only
proc ::mkitsql::db::lockedBy {tag} {
    if {[llength [info commands ::store::lockedByOther]]} { return [::store::lockedByOther $tag] }
    return ""
}
proc ::mkitsql::db::holdsLock {tag} { expr {![::store::readonly $tag]} }

proc ::mkitsql::db::views {tag} {
    if {[llength [info commands ::store::hasLayout]]} { return [::store::views $tag] }
    set out {}
    foreach v [mk::file views $tag] {
        if {![catch {mk::view layout $tag.$v}]} { lappend out $v }
    }
    return [lsort -dictionary $out]
}
proc ::mkitsql::db::hasView {tag name} { expr {[lsearch -exact [views $tag] $name] >= 0} }

proc ::mkitsql::db::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    if {![catch {::store::parseLayout [mk::view layout $tag.$name]} old]} { ::mkitsql::typeRecord $tag $name $old }
    mk::view size $tag.$name 0
    set left [mk::view size $tag.$name]
    if {$left != 0} { error "Cannot drop '$name': $left rows could not be cleared." }
    mk::view delete $tag.$name
    ::store::touch $tag
}

# (not ::store::createView: older store.tcl versions check for an existing view with their own hasView,
# which still lists a dropped view until the next commit)
proc ::mkitsql::db::typeGuard {tag view newLayout} {
    if {![catch {::store::parseLayout [mk::view layout $tag.$view]} old]} { ::mkitsql::typeRecord $tag $view $old }
    set c [::mkitsql::typeConflict $tag $view $newLayout]
    if {$c ne ""} { ::mkitsql::typeConflictError $view $c }
}
proc ::mkitsql::db::createView {tag name layout} {
    if {[hasView $tag $name]} { error "View '$name' already exists in '$tag'." }
    typeGuard $tag $name $layout
    mk::view layout $tag.$name [::store::formatLayout $layout]
    ::mkitsql::typeRecord $tag $name $layout
    ::store::touch $tag
}

# MK Studio's store writes its own commit record and says nothing when it cannot: there is no "unprotected" flag to report
proc ::mkitsql::db::commitUnprotected {tag} { return 0 }
