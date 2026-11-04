# db.tcl -- the storage layer of mkit-sql: the only code (with db_studio.tcl) that talks to Mk4tcl.
#
# The engine calls ::mkitsql::db::* and nothing else.  Two implementations of that interface exist:
#
#   db.tcl         (this file) STANDALONE: talks to Mk4tcl (mk::*) directly.  mkit-sql needs nothing
#                  from MK Studio.  This is the default.
#   db_studio.tcl  an adapter that forwards to MK Studio's ::store package when that is loaded, so both
#                  share one set of open files inside MK Studio.
#
# Vocabulary
#   tag     name Mk4tcl knows an open datafile by            (e.g. "demo")
#   path    a Metakit view path                              (e.g. "demo.people", "demo.people!3.skills")
#   layout  list of {name type sub} triples; type is one of S I L F D B V; for V (subview) `sub` is a
#           nested layout, else {}.
#
# Files are opened with -nocommit: nothing reaches the disk until `commit`, and closing never saves.
# Written for Tcl 8.5 and 8.6.

namespace eval ::mkitsql::db {
    variable lockOwned       ;# tag -> {lockfile content} of the lock this process holds
    variable lockedBy        ;# tag -> "pid host" of a live writer, for files opened read-only
    variable requireLock 0   ;# 1 = opening for writing fails when no lock file can be created (read-only folder)
    array set lockOwned {} ; array set lockedBy {}
    variable tags {}         ;# open tags, in open order
    variable file            ;# tag -> absolute path
    variable ro              ;# tag -> read-only flag
    variable dirty           ;# tag -> number of uncommitted changes
    array set file {} ; array set ro {} ; array set dirty {}

}

# ---- files ---------------------------------------------------------------------------------
proc ::mkitsql::db::available {} { expr {[llength [info commands ::mk::file]] > 0} }

proc ::mkitsql::db::makeTag {path} {
    variable tags
    set base [file rootname [file tail $path]]
    regsub -all {[^A-Za-z0-9_]} $base _ base
    if {$base eq "" || [string is digit [string index $base 0]]} { set base db_$base }
    set tag $base ; set n 1
    while {[lsearch -exact $tags $tag] >= 0} { set tag ${base}_[incr n] }
    return $tag
}
proc ::mkitsql::db::tags {} { variable tags ; return $tags }
proc ::mkitsql::db::path {tag}     { variable file ; return $file($tag) }
proc ::mkitsql::db::readonly {tag} { variable ro   ; return $ro($tag) }
proc ::mkitsql::db::dirty {tag}    { variable dirty ; return $dirty($tag) }
proc ::mkitsql::db::touch {tag}    { variable dirty ; incr dirty($tag) }
proc ::mkitsql::db::touchPath {path} { touch [lindex [split $path .!] 0] }

# ---- advisory write lock ----------------------------------------------------------------------
# Metakit does no locking: a process reading a file while another commits can see a half-written state, and two
# writers overwrite each other.  This is the protocol of MK Studio's docs/CONCURRENCY.md, implemented to the letter so
# that mkit-sql, MK Studio and a server exclude each other (tests/locking.tcl runs the spec's checks against this code,
# and MKSTUDIO_DIR=... runs real MK Studio processes against it):
#   * a file opened for writing owns "<file>.lock", one line "pid host [role [endpoint]]", created with O_EXCL;
#   * a lock is HELD (respected) when its process is alive on this host or when it names another host, STALE when
#     this host's process is gone or the file is empty/garbled and older than 5 s, OURS when it names this process;
#   * stale and ours are taken over under "<file>.lock.guard" (created exclusively; a guard older than 10 s was
#     abandoned by a crash): classify again with the guard held, delete the lock, delete the guard, create again;
#   * closing deletes the lock only if it still names us.  Files opened -readonly take no lock.
# Beyond the letter of the protocol (all of it only makes the checks stricter, never looser):
#   * a lock file that is not a regular file (a link, a folder, a fifo) is refused, never followed or read;
#   * a pid that was recycled (the process is younger than the lock file; Linux) counts as dead;
#   * the path is resolved through symbolic links first, so two names of one file share one lock.
# Limits (see docs/SQL.md): the lock is advisory; a hard link is another name Metakit cannot tell apart; processes
# in different PID namespaces that share a host name and a folder cannot see each other's pids.
namespace eval ::mkitsql::db {
    variable lockRole "" ; variable lockEndpoint ""     ;# a server announces itself: set before openFile
}
proc ::mkitsql::db::lockPath {path} { return $path.lock }
proc ::mkitsql::db::thisHost {} { if {[catch {info hostname} h]} { return unknown } ; return $h }
proc ::mkitsql::db::lockText {} {
    variable lockRole ; variable lockEndpoint
    set t "[pid] [thisHost]"
    if {$lockRole ne "" || $lockEndpoint ne ""} { append t " [expr {$lockRole eq {} ? {-} : $lockRole}]" }
    if {$lockEndpoint ne ""} { append t " $lockEndpoint" }
    return $t
}
# the real location of a file: symbolic links in the last component are followed too (`file normalize` does not)
proc ::mkitsql::db::realPath {p} {
    set p [::file normalize $p]
    for {set n 0} {$n < 40} {incr n} {
        if {[catch {::file readlink $p} t]} break
        set p [::file normalize [::file join [::file dirname $p] $t]]
    }
    return $p
}
# epoch second when a local process started (Linux: /proc/<pid>/stat field 22 and /proc/stat btime), "" where unknown
proc ::mkitsql::db::procStartTime {pid} {
    if {[catch {set h [open /proc/$pid/stat r] ; set d [read $h] ; close $h}]} { return "" }
    set rest [string range $d [expr {[string last ")" $d] + 2}] end]
    set ticks [lindex $rest 19]
    if {![string is integer -strict $ticks]} { return "" }
    if {[catch {set h [open /proc/stat r] ; set st [read $h] ; close $h}] || ![regexp {btime (\d+)} $st -> btime]} { return "" }
    return [expr {$btime + $ticks / 100}]
}
# The lock file as a dict: state free|ours|stale|held, and pid host role endpoint when there is one.
proc ::mkitsql::db::lockInfo {path} { return [lockInfoFile [lockPath $path]] }
# (the same for any file that is, or was, a lock file: a takeover judges the file it has moved aside, not only the one in place)
proc ::mkitsql::db::lockInfoFile {lf} {
    if {[catch {::file lstat $lf st}]} { return [dict create state free] }
    if {$st(type) ne "file"} {
        return -code error -errorcode [list MKIT BADLOCK $lf] "The lock path is not a regular file ($st(type)); refusing to use it:\n$lf"
    }
    # a bounded read of a regular file: a hostile or damaged lock file cannot make us read for ever
    if {[catch {set h [open $lf r] ; set d [string trim [read $h 512]] ; close $h}]} {
        # vanished meanwhile = free; still there but unreadable (another user's file under a strict umask) = held by an owner we cannot name
        if {[catch {::file lstat $lf st2}]} { return [dict create state free] }
        return [dict create state held pid 0 host unknown role "" endpoint ""]
    }
    lassign [split $d " "] pid host role endpoint
    set info [dict create pid $pid host $host role [expr {$role eq "-" ? "" : $role}] endpoint $endpoint]
    set state held
    if {![string is integer -strict $pid] || $host eq ""} {
        # empty or garbled: its creator is probably between creating and writing it; stale only once it has stayed so for a while
        variable emptyStale
        if {[clock seconds] - $st(mtime) > $emptyStale} { set state stale }
    } elseif {$pid == [pid] && $host eq [thisHost]} {
        set state ours
    } elseif {$host eq [thisHost]} {
        if {![::mkitsql::pidAlive $pid]} {
            set state stale
        } else {
            set started [procStartTime $pid]
            if {$started ne "" && $started > $st(mtime) + 2} { set state stale }      ;# the pid was recycled: that process started after the lock was made
        }
    }
    return [dict merge $info [dict create state $state]]
}
# "pid host role endpoint" of a live foreign holder, or "" when the file is unlocked / stale / ours
proc ::mkitsql::db::lockHolder {path} {
    set i [lockInfo $path]
    if {[dict get $i state] ne "held"} { return "" }
    return [list [dict get $i pid] [dict get $i host] [dict get $i role] [dict get $i endpoint]]
}
proc ::mkitsql::db::lockedError {holder path} {
    lassign $holder hpid hhost hrole hend
    set who "pid $hpid on $hhost"
    if {$hrole ne ""} { append who ", $hrole" }
    if {$hend ne ""} { append who " at $hend" }
    return -code error -errorcode [list MKIT LOCKED $hpid $hhost $hrole $hend] \
        "This database is open for editing in another process ($who):\n$path"
}
# Create our lock file; returns its text, "" when no lock could be made (read-only folder or disk: carry on unlocked),
# or raises MKIT LOCKED when somebody else owns it.
# Try to create our lock file.  Returns {created text}, {exists} (something is already there - or was a moment ago), or
# {blocked} (the folder will not hold a file: read-only, no permission, disk full - run unlocked).  Only a refusal of the
# folder itself means "blocked": a file that has vanished again by the time we look is a competitor that just released or
# replaced the lock, never "no lock needed" (treating it so let two processes both believe they owned the database).
# (file modes below are DECIMAL on purpose: 420 = 0644.  Tcl 9 no longer reads a leading zero as octal, so a written 0644 would be 644 decimal.)
proc ::mkitsql::db::createLock {lf mine} {
    if {[catch {open $lf {WRONLY CREAT EXCL} 420} h opts]} {
        set code [dict get $opts -errorcode]
        if {[lindex $code 0] eq "POSIX" && [lindex $code 1] eq "EEXIST"} { return [list exists] }
        return [list blocked]
    }
    lockStep created
    if {[catch {puts -nonewline $h $mine ; close $h} err]} {
        # the write failed (a full disk): an empty lock would keep everybody out until it is old - remove it and go on unlocked
        catch {close $h} ; catch {::file delete $lf}
        return [list blocked]
    }
    lockStep written
    # A process held up between creating the lock file and writing it (starved, suspended) can have been taken for dead and
    # overtaken meanwhile: what it wrote went into a file that is no longer under the name.  It must notice, not carry on.
    if {![stillMine $lf $mine]} { lockStep overtaken ; return [list exists] }
    # tidy up a takeover guard abandoned by a crashed process (it is harmless but would otherwise stay for ever)
    variable mutexStale
    if {![catch {::file mtime $lf.guard} mt] && [clock seconds] - $mt > $mutexStale} { lockStep guard-aged ; catch {::file delete $lf.guard} }
    tidyTakeovers $lf
    return [list created $mine]
}
# Is the file under the lock's name the one just written (its text is ours)?  A file that exists but cannot be read at this moment
# (a virus scanner has it) proves nothing against us; a file that is gone, or holds somebody else's text, is not ours any more.
proc ::mkitsql::db::stillMine {lf mine} {
    if {[catch {set h [open $lf r] ; set d [read $h 512] ; close $h}]} { return [::file exists $lf] }
    return [expr {$d eq $mine}]
}
# Take a lock file that was judged stale out of the way.  Returns
#   claimed   it was moved aside, judged again - still stale (or ours, or empty and old) - and deleted: the name is free
#   gone      there was nothing under the name any more: the name is free
#   alive     what was moved turned out to be a live owner's lock (somebody got in under a guard that was wrongly removed): it has
#             been put back, and is not ours to take
#   busy      the file could not be moved now (Windows: another program has it open): nothing was changed
# The rename is the one atomic step: whatever file is under the name at that instant is the file that is moved, and it is judged
# AFTER it has been moved, so a lock that was replaced between the verdict and the move is recognised instead of destroyed.
# (A delete by name cannot tell the stale lock it judged from a fresh one made under the same name since.)
namespace eval ::mkitsql::db { variable claimSeq 0 }
proc ::mkitsql::db::claimStale {lf} {
    variable claimSeq
    set aside $lf.take.[clock seconds].[pid].[incr claimSeq]
    if {[catch {::file rename $lf $aside}]} { return [expr {[::file exists $lf] ? "busy" : "gone"}] }
    lockStep claimed                                             ;# (test hook: the lock is out of the way, not yet judged)
    if {[catch {lockInfoFile $aside} info]} { set state held } else { set state [dict get $info state] }   ;# (not a plain file: never ignored)
    if {$state ne "held"} { catch {::file delete $aside} ; return claimed }
    # Put it back - with a hard link, which fails instead of replacing when the name is taken again meanwhile (a rename would
    # replace it, on Unix).  Where hard links do not exist (FAT, some network shares) the name is checked and the file renamed back.
    if {[catch {::file link -hard $lf $aside}] && ![::file exists $lf]} { catch {::file rename $aside $lf} }
    catch {::file delete $aside}
    return alive
}
# Files a takeover moved aside and a killed process never deleted.  The name carries the second it was moved; a live takeover
# deletes its own within moments, so anything older than the guard limit is litter.
proc ::mkitsql::db::takeovers {lf} {
    # (a file name may contain glob characters: they are matched literally)
    set tail [string map [list \\ \\\\ * \\* ? \\? \[ \\\[ \] \\\] \{ \\\{ \} \\\}] [::file tail $lf]]
    return [glob -nocomplain -directory [::file dirname $lf] -- $tail.take.*]
}
proc ::mkitsql::db::tidyTakeovers {lf} {
    variable mutexStale
    foreach f [takeovers $lf] {
        if {[regexp {\.take\.(\d+)\.\d+\.\d+$} $f -> at] && [clock seconds] - $at > $mutexStale} { catch {::file delete $f} }
    }
}
# test hook: a script prefix called with the name of each step of taking a lock (tests kill the process or race it there)
namespace eval ::mkitsql::db { variable lockHook "" ; variable emptyStale 5 ; variable mutexStale 10 }
proc ::mkitsql::db::lockStep {name} { variable lockHook ; if {$lockHook ne ""} { {*}$lockHook $name } }
proc ::mkitsql::db::takeLock {path} {
    variable mutexStale
    set lf [lockPath $path] ; set mine [lockText]
    for {set attempt 0} {$attempt < 60} {incr attempt} {
        set r [createLock $lf $mine]
        switch -- [lindex $r 0] {
            created { return [lindex $r 1] }
            blocked { return "" }
        }
        lockStep create-failed
        if {[catch {::file lstat $lf st}]} { continue }                       ;# it vanished: a competitor released or replaced it - try again
        set holder [lockHolder $path]
        if {$holder ne ""} { return [lockedError $holder $path] }
        # stale (or ours from an earlier run): replace it, one process at a time, under the guard
        set guard $lf.guard
        if {[catch {set gh [open $guard {WRONLY CREAT EXCL} 420] ; close $gh}]} {
            # somebody else is replacing the lock: a guard older than mutexStale was abandoned by a crash, otherwise give them a
            # moment (about 2.4 s over all attempts, as the protocol says) and look again
            if {![catch {::file mtime $guard} mt] && [clock seconds] - $mt > $mutexStale} {
                lockStep guard-aged                                          ;# (test hook: the guard has been judged abandoned, nothing is deleted yet)
                catch {::file delete $guard} ; continue
            }
            after 40
            continue
        }
        lockStep mutex
        set again [lockHolder $path]                                           ;# look again now that nobody else is replacing it
        set undeletable 0
        if {$again eq "" && [dict get [lockInfo $path] state] in {stale ours}} {
            lockStep checked                                                   ;# (test hook: the stale verdict is in, nothing is changed yet)
            # Move the lock aside and judge the file that was moved, instead of deleting by name: the guard can be removed wrongly
            # (docs/CONCURRENCY.md), and a delete by name would then destroy another process's brand-new lock.
            set claim [claimStale $lf] ; lockStep deleted
            # a stale lock that cannot be moved (another user's file in a sticky folder, a read-only folder) will never go away by retrying
            if {$claim eq "busy"} { set undeletable 1 }
        }
        catch {::file delete $guard}
        if {$again ne ""} { return [lockedError $again $path] }
        if {$undeletable} {
            return -code error -errorcode [list MKIT LOCKED 0 unknown {} {}] "The lock file of this database is stale (its process is gone) but cannot be removed - it may belong to another user or lie in a protected folder:\n$lf\nRemove it by hand."
        }
    }
    return -code error -errorcode [list MKIT LOCKED 0 unknown {} {}] "Could not take the lock on this database (another process is starting at the same moment), please repeat:\n$path"
}
# Release our lock - only if the file still holds OUR content (a regular file, read with a bound).
proc ::mkitsql::db::releaseLock {path mine} {
    set lf [lockPath $path]
    if {[catch {::file lstat $lf st}] || $st(type) ne "file"} return
    if {![catch {set h [open $lf r] ; set d [read $h 512] ; close $h}] && $d eq $mine} { catch {::file delete $lf} ; lockStep released }
}
# Who blocks writing to this file?  "pid host role endpoint" of the live writer a read-only handle noticed, else "".
proc ::mkitsql::db::lockedBy {tag} { variable lockedBy ; if {[info exists lockedBy($tag)]} { return $lockedBy($tag) } ; return "" }
# Does this handle hold the write lock?  (0 when it is read-only or the folder did not allow a lock file)
proc ::mkitsql::db::holdsLock {tag} { variable lockOwned ; return [info exists lockOwned($tag)] }

# Open (or with -create, create) a datafile; returns its tag.  Options: -create -readonly
proc ::mkitsql::db::openFile {path args} {
    variable tags ; variable file ; variable ro ; variable dirty ; variable lockOwned ; variable lockedBy ; variable requireLock
    set create 0 ; set readonly 0 ; set unchecked 0 ; set verify 0
    foreach a $args {
        switch -- $a { -create {set create 1} -readonly {set readonly 1} -unchecked {set unchecked 1} -verify {set verify 1} default { error "unknown option $a (use -create, -readonly, -unchecked or -verify)" } }
    }
    set path [realPath $path]
    foreach t $tags { if {$file($t) eq $path} { error "File is already open as '$t': $path" } }
    if {!$create && ![::file exists $path]} { error "File not found: $path" }
    # a file over 2 GiB (wide format) that this Mk4tcl cannot read would look EMPTY: refuse before anything touches it
    set why [wideRefusal $path]
    if {$why ne ""} { return -code error -errorcode [list MKIT WIDEFILE] $why }
    set mine "" ; set repairNote ""
    if {!$readonly} {
        set mine [takeLock $path]                       ;# before anything touches the file, so a refusal touches nothing
        if {$mine eq "" && $requireLock} { error "Cannot create the lock file for $path (is the folder writable?)" }
        # with the lock held nobody else is in the middle of a commit: put right a commit that was interrupted
        # (not without the lock: then another writer may be in the middle of a commit, and cutting its unfinished append would break it)
        if {$mine ne "" && [::file exists $path] && [catch {repairFile $path} repairNote]} { set repairNote "" }
        # a repaired file is a good file but no longer byte for byte what the sum recorded (see sumCheck): no proof until the next commit
        if {$repairNote ne "" && ![string match "Warning*" $repairNote]} { catch {::file delete [sumPath $path]} }
    }
    # a damaged file would open as an empty database (and a later COMMIT would replace the real data); an untrusted one is read
    # completely in a throw-away process first.  Both happen AFTER the repair, so a file that only needed one is not refused.
    set verdict "" ; set vlevel ""
    if {[catch {
        if {!$unchecked} { ::mkitsql::dbRequireIntact $path }
        # (a read-only open without -verify does not read the whole file for a checksum: the state stays "")
        if {!$unchecked && [::file exists $path] && (!$readonly || $verify)} {
            set verdict [sumCheck $path [expr {!$readonly}]]
            # a reader that meets a writer between its commit and its new sum, or reads while the file is being rewritten, must not cry damage
            if {$verdict eq "damaged" && $readonly && [lockHolder $path] ne ""} { set verdict changed }
            if {$verdict eq "damaged"} {
                return -code error -errorcode [list MKIT DAMAGED checksum] "This file does not look like what was last saved ([sumPath $path] records its checksum, and it no longer matches although the file's size and time are unchanged): part of it was damaged since.\n$path\nOpen a backup. (Pass -unchecked to open it anyway.)"
            }
        }
        if {$verify && [::file exists $path] && [::file size $path] > 0} {
            if {$verdict eq "ok"} { set vlevel proven } else { ::mkitsql::dbVerify $path ; set vlevel evidence }
        }
    } err opts]} {
        if {$mine ne ""} { releaseLock $path $mine }
        return -options $opts $err
    }
    set tag [makeTag $path]
    set opts {-nocommit}
    if {$readonly} { lappend opts -readonly }
    if {[catch {mk::file open $tag $path {*}$opts}]} {
        # a very old Mk4tcl without -nocommit
        if {[catch {mk::file open $tag $path {*}[expr {$readonly ? {-readonly} : {}}]} err]} {
            if {$mine ne ""} { releaseLock $path $mine }
            error "Cannot open $path: $err"
        }
    }
    if {!$unchecked && ![::mkitsql::dbSignatureOk $path [llength [mk::file views $tag]]]} {
        catch {mk::file close $tag}
        if {$mine ne ""} { releaseLock $path $mine }
        return -code error -errorcode [list MKIT DAMAGED "not a Metakit database"] "This file isn't a Metakit database, so it was not opened:\n$path"
    }
    set holder ""
    if {$readonly && [catch {lockHolder $path} holder opts]} {
        # a lock path that is not a regular file: nothing has been registered yet, so close the handle and report
        catch {mk::file close $tag}
        return -options $opts $holder
    }
    lappend tags $tag
    variable integrity ; variable level
    set integrity($tag) $verdict ; set level($tag) $vlevel
    if {$repairNote ne ""} { variable repaired ; set repaired($tag) $repairNote }
    set file($tag) $path ; set ro($tag) $readonly ; set dirty($tag) 0
    wideCapable ; guardReset $tag 1                   ;# the library is probed here, never in the middle of a statement
    if {$readonly} {
        if {$holder ne ""} { set lockedBy($tag) $holder }
    } elseif {$mine ne ""} {
        set lockOwned($tag) $mine
    }
    return $tag
}
proc ::mkitsql::db::closeFile {tag} {
    variable tags ; variable file ; variable ro ; variable dirty ; variable lockOwned ; variable lockedBy
    if {[info exists lockOwned($tag)]} { releaseLock $file($tag) $lockOwned($tag) ; unset lockOwned($tag) }
    unset -nocomplain lockedBy($tag)
    catch {mk::file close $tag}
    set i [lsearch -exact $tags $tag]
    if {$i >= 0} { set tags [lreplace $tags $i $i] }
    unset -nocomplain file($tag) ro($tag) dirty($tag) ::mkitsql::db::repaired($tag) ::mkitsql::db::integrity($tag) ::mkitsql::db::level($tag)
    ::mkitsql::typeForget $tag                       ;# what Metakit remembers about column types dies with the open file
    guardForget $tag
}
proc ::mkitsql::db::commit {tag} {
    variable dirty ; variable file
    set record 0
    if {$dirty($tag) > 0} { set record [beginCommit $file($tag)] }
    if {[catch {mk::file commit $tag} err]} {
        if {!$record} { return -code error $err }
        lassign [commitFailed $tag $err] code msg
        return -code error -errorcode $code $msg
    }
    set dirty($tag) 0
    guardReset $tag
    if {$record} { endCommit $file($tag) ; catch {sumWrite $file($tag)} }
}
# Metakit stores a file's size in ONE 32-bit word and stops at 2 GiB: a commit that would cross it fails ("I/O error during
# commit"), and - measured on real Metakit - may first have appended part of its data and even written the new header, leaving a
# file that crashes Metakit when it is opened.  The record written before the commit says what to put back.  The file is restored,
# the handle reopened (the changes since the last commit are gone, as with ROLLBACK), and the error says what happened.
namespace eval ::mkitsql::db { variable maxFileBytes 2147483647 ; variable unprotected ; array set unprotected {} }
proc ::mkitsql::db::commitFailed {tag err} {
    variable file ; variable dirty ; variable ro ; variable maxFileBytes
    set path $file($tag)
    # close first (Windows: no truncating a file Metakit still has mapped), put the file right, open it again and check it
    catch {mk::file close $tag}
    set note "" ; set repairFailed 0
    if {[catch {repairFile $path} note]} { set repairFailed 1 }
    catch {::file delete [sumPath $path]}                 ;# the restored file is good, but not byte for byte what the sum recorded
    set reopened 0
    if {!$repairFailed && ![string match "Warning*" $note]} {
        set opts {-nocommit}
        if {$ro($tag)} { lappend opts -readonly }
        if {![catch {::mkitsql::dbRequireIntact $path}] && ![catch {mk::file open $tag $path {*}$opts}]} { set reopened 1 }
    }
    set dirty($tag) 0
    ::mkitsql::typeForget $tag
    guardReset $tag 1
    set size [expr {[::file exists $path] ? [::file size $path] : 0}]
    set cause "a full disk or a write error"
    if {![wideCapable] && $size > $maxFileBytes / 2} { set cause "the size limit of a Metakit file ($maxFileBytes bytes = 2 GiB; this file is $size bytes) or a full disk" }
    set msg "The commit failed ($err) - most likely $cause. "
    if {$reopened} {
        append msg "The database file was put back to its last committed state and the changes made since then were discarded (as ROLLBACK does).\nNothing in the file is lost.[expr {[wideCapable] ? {} : { To get past the size limit, split the data over several database files, or use a Mk4tcl built for big files (see docs/SQL.md).}}]"
    } else {
        append msg "The file could NOT be put back automatically ([expr {$repairFailed ? $note : $note}]). This handle is closed; do not commit again. Open the file again: a pending commit record is applied when it is opened for writing."
    }
    return [list [list MKIT COMMITFAILED $size] $msg]
}

# ---- interrupted commits and power loss -------------------------------------------------------------------------
# The same mechanism, file names and formats as MK Studio's store.tcl (a file may be opened by either after a crash of the other).
# What a Metakit commit does to the file (measured with strace by MK Studio's tests/test_power_loss.tcl; ours: tests/power_loss.tcl):
#   1. a few small in-place writes (an 8-byte marker in the old tail),
#   2. the new data and a new tail APPENDED after the end of the file,
#   3. LAST, the 8-byte header at offset 0, which holds the offset of the new end of the file.
# There is no fsync anywhere.  So a crash between 2 and 3 leaves the OLD header and a LONGER file, which Metakit opens as an EMPTY
# database without any error (a plain `kill` rarely lands in that few milliseconds, a deterministic one does every time), and after a
# POWER CUT the pages may reach the disk in any order.  Two repairs make both recoverable:
#   * before a commit starts, <file>.commit records the committed header and size (forced to disk where the system has `sync`); after
#     the commit the file is forced to disk and the record removed.  If the record is found when the file is opened for writing, the
#     commit never finished (or was never confirmed): header and size are put back - the database is exactly what it was before it.
#   * without a record, a file longer than its header says (an unfinished append) is cut back to the header's offset.
# Not covered: a disk that loses data it said was written, or a system with no way to force data out (Windows has no `sync`
# command: there, kills are covered and power loss is as safe as the operating system's own write ordering).
# durable 0 turns the sync calls off (the environment variable MKIT_DURABLE=0 does the same at load time: for test machines where
# forcing every commit to disk - a PowerShell start on Windows - would only make a long test run longer)
namespace eval ::mkitsql::db { variable durable [expr {[info exists ::env(MKIT_DURABLE)] && $::env(MKIT_DURABLE) eq "0" ? 0 : 1}] ; variable repaired ; array set repaired {} }
# force the files (and the folder entry) to disk where the system can:
#   Linux/BSD  coreutils `sync FILE...`, else a plain `sync`
#   macOS      `sync` (flushes the OS cache; the drive's own cache is out of reach from Tcl)
#   Windows    FlushFileBuffers through PowerShell (.NET FileStream.Flush($true)), if PowerShell can be started
# Returns 1 when something was asked to force the data out, 0 when nothing could be.  (Same as MK Studio's store.tcl.)
proc ::mkitsql::db::syncDisk {args} {
    variable durable
    if {!$durable} { return 0 }
    if {$::tcl_platform(platform) eq "windows"} { return [syncWindows {*}$args] }
    set paths {}
    foreach p $args { lappend paths $p ; lappend paths [::file dirname $p] }
    if {[catch {exec sync {*}[lsort -unique $paths]}] && [catch {exec sync}]} { return 0 }
    return 1
}
namespace eval ::mkitsql::db { variable psOk -1 }
# A Windows program by its full path in the system folder (a bare name is searched for in the program's folder and the current
# folder first: a planted powershell.exe there would run).
proc ::mkitsql::db::winTool {name} {
    set root [expr {[info exists ::env(SystemRoot)] ? $::env(SystemRoot) : {C:/Windows}}]
    foreach f [list $root/System32/$name.exe $root/System32/WindowsPowerShell/v1.0/$name.exe $root/Sysnative/$name.exe] {
        if {[::file isfile $f]} { return $f }
    }
    return ""
}
proc ::mkitsql::db::base64 {bytes} {
    set tbl ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
    set out "" ; set n [string length $bytes]
    for {set i 0} {$i < $n} {incr i 3} {
        binary scan [string range $bytes $i [expr {$i + 2}]] c* v
        set a [expr {[lindex $v 0] & 255}] ; set b [expr {[llength $v] > 1 ? [lindex $v 1] & 255 : 0}] ; set c [expr {[llength $v] > 2 ? [lindex $v 2] & 255 : 0}]
        set x [expr {($a << 16) | ($b << 8) | $c}]
        append out [string index $tbl [expr {($x >> 18) & 63}]] [string index $tbl [expr {($x >> 12) & 63}]]
        append out [expr {[llength $v] > 1 ? [string index $tbl [expr {($x >> 6) & 63}]] : "="}] [expr {[llength $v] > 2 ? [string index $tbl [expr {$x & 63}]] : "="}]
    }
    return $out
}
# PowerShell started straight from a Windows GUI program (a wish-based tclkit) does NOTHING: exit status 0, no output, no effect
# (measured on real runners) - Tcl starts console programs without a console for a program that has none.  cmd.exe makes itself
# one and the PowerShell it starts runs.  The script goes as -EncodedCommand (UTF-16 in base64): no quoting, any file name intact.
# {ran ok output}: ran 0 = PowerShell could not be started at all; ok 1 = the script finished without error.
proc ::mkitsql::db::psRun {script} {
    set ps [winTool powershell] ; set cmd [winTool cmd]
    if {$ps eq "" || $cmd eq ""} { return [list 0 0 "PowerShell was not found"] }
    set argv [list $cmd /c [::file nativename $ps] -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand [base64 [encoding convertto unicode $script]]]
    set rc [catch {exec {*}$argv 2>@1} out opts]
    if {$rc && [lindex [dict get $opts -errorcode] 0] ne "CHILDSTATUS"} { return [list 0 0 $out] }
    return [list 1 [expr {!$rc}] $out]
}
proc ::mkitsql::db::syncWindows {args} {
    variable psOk
    if {$psOk == 0} { return 0 }
    set files {}
    foreach p $args { if {[::file isfile $p]} { lappend files [::file nativename $p] } }
    if {![llength $files]} { return 1 }
    set quoted {}
    foreach f $files { lappend quoted '[string map {' ''} $f]' }
    set script "foreach(\$f in @([join $quoted ,])){ \$s=\[IO.File\]::Open(\$f,'Open','ReadWrite','ReadWrite'); try{ \$s.Flush(\$true) } finally{ \$s.Dispose() } }"
    lassign [psRun $script] ran ok out
    set psOk $ran
    return $ok
}
# Called before mk::file commit: remember the state we can fall back to.
# What a commit can fall back to: the file as it is now.  A Metakit file -> "<header-hex16> <size>"; no file / 0 bytes -> "empty 0"
# (the first commit of a new database); anything else (a starkit, a foreign file) is not protected.
proc ::mkitsql::db::beginCommit {path} {
    set info [headerInfo $path]
    if {$info ne ""} {
        set line "[dict get $info header] [dict get $info size]"
    } elseif {![::file exists $path] || [::file size $path] == 0} {
        set line "empty 0"
    } else {
        return 0
    }
    set rec [commitRecord $path]
    catch {::file delete [sumPath $path]}               ;# a commit rewrites bytes in place: the old sum must not outlive it, whatever happens next
    if {[catch { set h [open $rec w] ; puts -nonewline $h $line ; close $h }]} {
        # no record can be written (a read-only folder, a full disk): the commit would run unprotected.  Remove what is left of a partial
        # record, and let the caller see it (commitUnprotected); it still goes ahead, because a database in a folder that cannot hold
        # a lock file must stay writable
        catch {close $h} ; catch {::file delete $rec}
        variable unprotected ; set unprotected($path) 1
        return 0
    }
    syncDisk $rec $path
    return 1
}
# 1 when a commit of this file ran without a commit record (the record could not be written): an interrupted one could not be undone
proc ::mkitsql::db::commitUnprotected {tag} { variable unprotected ; variable file ; return [info exists unprotected($file($tag))] }
proc ::mkitsql::db::endCommit {path} {
    syncDisk $path
    set rec [commitRecord $path]
    catch {::file delete $rec}
    if {[::file exists $rec]} {
        # The commit is complete and confirmed, but its record cannot be removed (on Windows a virus scanner or an indexer may hold a
        # fresh file open).  A record left behind would make the next writer undo this commit, so make it harmless: an empty record means
        # nothing to undo.  If even that fails the caller must know.
        if {[catch { set h [open $rec w] ; close $h }]} {
            return -code error -errorcode [list MKIT RECORDSTUCK $rec] "The commit succeeded, but its safety record could not be removed or emptied:\n$rec\nDelete that file before the database is opened again, or the next open would undo this commit."
        }
    }
}
# ---- integrity: a checksum of the whole file (the same <file>.sum MK Studio writes) ------------------------------------------------
# Metakit stores no checksums, so a flipped bit or a lost sector inside the data is invisible to it - and reading such a file can crash
# Metakit.  After every commit <file>.sum records "<crc32> <size> <mtime>" of the finished file.  Later the sum PROVES the file is still
# byte for byte what that commit left (and, a file Metakit wrote being well formed, safe to read); it proves nothing about a file that
# was already damaged when it was written, and a file another program changed has a sum that no longer applies ("changed": no proof).
# Files over `sumLimit` MB are not covered; `set ::mkitsql::db::sumLimit 0` turns it off.  crc32 catches accidental damage, not tampering.
namespace eval ::mkitsql::db { variable sumLimit 512 ; variable integrity ; array set integrity {} ; variable level ; array set level {} }
proc ::mkitsql::db::crcFile {path} {
    set crc 0
    set h [open $path rb]
    set rc [catch { while {![eof $h]} { set crc [zlib crc32 [read $h 4194304] $crc] } } err opts]
    close $h
    if {$rc} { return -options $opts $err }
    return [format %08x $crc]
}
proc ::mkitsql::db::sumCovered {path} {
    variable sumLimit
    expr {[llength [info commands zlib]] && [::file isfile $path] && [::file size $path] > 0 && [::file size $path] <= $sumLimit * 1048576}
}
# Written to a fresh temporary file (never through a link: the name is removed first and created exclusively) and renamed into place.
proc ::mkitsql::db::sumWrite {path} {
    if {![sumCovered $path]} { catch {::file delete [sumPath $path]} ; return 0 }
    set line "[crcFile $path] [::file size $path] [::file mtime $path]"
    set tmp [sumPath $path].tmp
    catch {::file delete $tmp}
    if {[catch { set h [open $tmp {WRONLY CREAT EXCL} 420] ; puts -nonewline $h $line ; close $h ; ::file rename -force $tmp [sumPath $path] }]} { catch {close $h} ; catch {::file delete $tmp} ; return 0 }
    syncDisk [sumPath $path]                        ;# the new name and its content on the disk before the commit is called done (as MK Studio's store.tcl)
    return 1
}
# ok | none (no sum, or not covered) | changed (size or time differ, a commit is unconfirmed, or the difference cannot be told from another
# program's write in the same second) | damaged (same size and time, different bytes, and the sum was written at least a second after the
# file's last change - so any later write by anyone would have moved the file's time)
proc ::mkitsql::db::sumCheck {path {restamp 0}} {
    if {![sumCovered $path]} { return none }
    set r [sumRead $path]
    if {$r eq ""} { return none }
    lassign $r crc size mtime sumMtime
    # a commit record means a commit began and was not confirmed: the file is between two states (a commit changes bytes in place, which
    # putting the header back does not undo), so the sum says nothing about it until the next open has repaired it
    if {[::file exists [commitRecord $path]]} { return changed }
    if {$size != [::file size $path] || $mtime != [::file mtime $path]} { return changed }
    if {[crcFile $path] eq $crc} {
        # proven intact now: if the sum was written in the same second as the file's last change, stamp it a second later, so that damage
        # from here on is unambiguous (a clock that has moved past that second makes this safe)
        if {$restamp} { sumRestamp $path }
        return ok
    }
    return [expr {$sumMtime > $mtime ? "damaged" : "changed"}]
}
# what is known about this open file: {state level}.  state: the verdict of the sum at open (ok none changed); level: "proven" when
# -verify found the sum intact, "evidence" when -verify read the whole file in a helper process without trouble (no proof: Metakit reads
# damaged data differently from one run to the next), "" when -verify was not asked for.
proc ::mkitsql::db::integrityOf {tag} {
    variable integrity ; variable level
    list [expr {[info exists integrity($tag)] ? $integrity($tag) : ""}] [expr {[info exists level($tag)] ? $level($tag) : ""}]
}

# Put right an interrupted commit.  Needs the write lock.  Returns "" (nothing to do) or what was done.
proc ::mkitsql::db::repairFile {path} {
    set rec [commitRecord $path]
    set info [headerInfo $path]
    if {[::file exists $rec]} {
        if {[catch {set h [open $rec r] ; set d [string trim [read $h 200]] ; close $h}]} { return "" }
        lassign [split $d " "] hex size
        if {$hex eq "empty" && $size == 0} {
            # the first commit of a new database was interrupted: it is a new, empty database again - unless the file already has a
            # complete frame (the commit finished and only its record was left behind): then it is a database, keep it
            if {$info ne "" && [dict get $info size] == [dict get $info offset] && [footerOkAt $path [dict get $info size] [dict get $info wide]]} {
                ::file delete $rec
                return ""
            }
            if {[::file exists $path] && [::file size $path] > 0} {
                set h [open $path r+b] ; chan truncate $h 0 ; close $h
                syncDisk $path
                ::file delete $rec                                       ;# last: a crash before this leaves the record for the next open
                return "The first save of this new database was interrupted and has been undone: the database is empty again."
            }
            ::file delete $rec
            return ""
        }
        if {[string length $hex] == 16 && [string is integer -strict $size] && $info ne ""} {
            if {[::file size $path] == $size && [dict get $info header] eq $hex} {
                ::file delete $rec                                       ;# the commit never wrote anything
                return ""
            }
            if {[::file size $path] >= $size && ![footerOkAt $path $size [wideHex $hex]]} {
                return "Warning: an interrupted commit was found, but the file does not end in a valid footer where it should; nothing was changed."
            }
            if {[::file size $path] >= $size} {
                set h [open $path r+b]
                seek $h 0 start ; puts -nonewline $h [binary format H* $hex] ; flush $h
                chan truncate $h $size
                close $h
                syncDisk $path
                ::file delete $rec
                return "An unfinished commit was undone: the database is as it was before that commit."
            }
            # the file is SHORTER than it was before the commit: nothing we can put back
            return "Warning: this file is shorter than it was at its last commit - the database may be damaged."
        }
        ::file delete $rec
    }
    if {$info ne "" && [dict get $info size] > [dict get $info offset] && [footerOkAt $path [dict get $info offset]]} {
        set h [open $path r+b] ; chan truncate $h [dict get $info offset] ; close $h
        return "The unfinished end of an interrupted commit was discarded."
    }
    return ""
}
# interrupted commits repaired while opening, by tag - for the application to tell the user
proc ::mkitsql::db::repairedNote {tag} { variable repaired ; if {[info exists repaired($tag)]} { return $repaired($tag) } ; return "" }

# Discard uncommitted work (newer Mk4tcl has `mk::file rollback`; otherwise reopen, which is safe with -nocommit).
proc ::mkitsql::db::rollback {tag} {
    variable dirty ; variable file ; variable ro
    if {[catch {mk::file rollback $tag}]} {
        set opts {-nocommit}
        if {$ro($tag)} { lappend opts -readonly }
        mk::file close $tag
        mk::file open $tag $file($tag) {*}$opts
    }
    set dirty($tag) 0
    guardReset $tag 1
}

# Close and reopen the file (same tag, same lock): resets Metakit's memory of column types.  Only with nothing pending.
proc ::mkitsql::db::reopen {tag} {
    variable file ; variable ro ; variable dirty
    if {$dirty($tag) > 0} { error "cannot reopen '$tag' with uncommitted changes" }
    catch {mk::file close $tag}
    set opts {-nocommit}
    if {$ro($tag)} { lappend opts -readonly }
    mk::file open $tag $file($tag) {*}$opts
    ::mkitsql::typeForget $tag
    guardReset $tag 1
}
# Before a view gets a layout: remember what it has now, and refuse (or reopen first) if the new layout would change the
# type of a column that has already existed under that name (see dbcheck.tcl).
proc ::mkitsql::db::typeGuard {tag view newLayout} {
    variable dirty
    if {![catch {parseLayout [mk::view layout $tag.$view]} old]} { ::mkitsql::typeRecord $tag $view $old }
    set c [::mkitsql::typeConflict $tag $view $newLayout]
    if {$c eq ""} return
    if {$dirty($tag) == 0} {
        reopen $tag
        if {![catch {parseLayout [mk::view layout $tag.$view]} old]} { ::mkitsql::typeRecord $tag $view $old }
        set c [::mkitsql::typeConflict $tag $view $newLayout]
        if {$c eq ""} return
    }
    ::mkitsql::typeConflictError $view $c
}

# ---- structure ------------------------------------------------------------------------------
# Metakit keeps listing a view after `mk::view delete` until the next commit; a deleted view has no layout.
proc ::mkitsql::db::views {tag} {
    set out {}
    foreach v [mk::file views $tag] {
        if {![catch {mk::view layout $tag.$v}]} { lappend out $v }
    }
    return [lsort -dictionary $out]
}
proc ::mkitsql::db::hasView {tag name} { expr {[lsearch -exact [views $tag] $name] >= 0} }

# "name:S age:I {addr {street:S city:S}} note"  ->  {{name S {}} {age I {}} {addr V {...}} {note S {}}}
proc ::mkitsql::db::parseLayout {spec} {
    set out {}
    foreach el $spec {
        if {[llength $el] == 2} {
            lappend out [list [lindex $el 0] V [parseLayout [lindex $el 1]]]
        } else {
            set i [string first : $el]
            if {$i < 0} {
                lappend out [list $el S {}]
            } else {
                lappend out [list [string range $el 0 [expr {$i-1}]] [string toupper [string range $el [expr {$i+1}] end]] {}]
            }
        }
    }
    return $out
}
proc ::mkitsql::db::formatLayout {layout} {
    set parts {}
    foreach col $layout {
        lassign $col n t sub
        if {$t eq "V"} { lappend parts [list $n [formatLayout $sub]] } else { lappend parts $n:$t }
    }
    return $parts
}
# Layout of a view or subview.  Real Mk4tcl answers `mk::view layout` for a subview path ("db.view!3.sub") with the TOP-LEVEL
# view's layout, so descend through the nested definitions ourselves (the same as MK Studio's ::store::layout).
proc ::mkitsql::db::layout {path} {
    set base [lindex [split $path !] 0]
    set layout [parseLayout [mk::view layout $base]]
    foreach {-> name} [regexp -all -inline {!\d+\.([A-Za-z0-9_]+)} $path] {
        set found ""
        foreach col $layout { if {[lindex $col 0] eq $name} { set found $col ; break } }
        if {$found eq "" || [lindex $found 1] ne "V"} { error "no subview '$name' in $path" }
        set layout [lindex $found 2]
    }
    return $layout
}
proc ::mkitsql::db::size   {path} { mk::view size $path }
proc ::mkitsql::db::subSize {path idx prop} { mk::view size $path!$idx.$prop }

# Row indices (ascending) that satisfy ALL of `conds`, decided inside Metakit (in C, ~40x faster than looking at
# every row from Tcl).  conds = list of {exact|min|max column value}; min/max are inclusive.  The caller must pass
# values valid for the column's type.
proc ::mkitsql::db::select {path conds} {
    set args {}
    foreach c $conds { lassign $c op p v ; lappend args -$op $p $v }
    return [mk::select $path {*}$args]
}
# ---- writing rows ---------------------------------------------------------------------------
proc ::mkitsql::db::appendRow {path props values} {
    variable wideCap
    if {$wideCap eq "1"} { guardWrite $path $props $values }
    set args {}
    foreach p $props v $values { lappend args $p $v }
    set cur [mk::row append $path {*}$args]
    touchPath $path
    return [lindex [split $cur !] end]
}
proc ::mkitsql::db::setCell {path idx prop value} {
    variable wideCap
    if {$wideCap eq "1"} { guardWrite $path [list $prop] [list $value] }
    mk::set $path!$idx $prop $value
    touchPath $path
}
# highest index first, so the rest stay valid
proc ::mkitsql::db::deleteRows {path indices} {
    foreach i [lsort -integer -decreasing -unique $indices] { mk::row delete $path!$i }
    touchPath $path
}

# `count` consecutive rows from `first` in one call (cheaper than one call per row)
proc ::mkitsql::db::deleteRange {path first count} {
    mk::row delete $path!$first $count
    touchPath $path
}
# remove every row of a view (and of its subviews), keeping the layout
proc ::mkitsql::db::clearView {path} {
    mk::view size $path 0
    touchPath $path
}

# ---- changing structure ---------------------------------------------------------------------
proc ::mkitsql::db::createView {tag name layout} {
    if {[hasView $tag $name]} { error "View '$name' already exists in '$tag'." }
    typeGuard $tag $name $layout
    mk::view layout $tag.$name [formatLayout $layout]
    ::mkitsql::typeRecord $tag $name $layout
    touch $tag
}
# `mk::view delete` leaves the ROWS behind: a view created again under the same name would get its old
# rows back.  So the rows are removed first - and if that does not work, the drop is abandoned with the
# original error (nothing is caught): a table is never dropped while its old rows could resurface.
proc ::mkitsql::db::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    if {![catch {parseLayout [mk::view layout $tag.$name]} old]} { ::mkitsql::typeRecord $tag $name $old }   ;# its types stay "seen"
    mk::view size $tag.$name 0
    set left [mk::view size $tag.$name]
    if {$left != 0} { error "Cannot drop '$name': $left rows could not be cleared." }
    mk::view delete $tag.$name
    touch $tag
}
# Apply a new layout.  Metakit keeps data for properties whose name AND type are unchanged.
proc ::mkitsql::db::restructure {path layout} {
    if {[string first ! $path] < 0} { lassign [split $path .] tag view ; typeGuard $tag $view $layout }
    mk::view layout $path [formatLayout $layout]
    if {[string first ! $path] < 0} { ::mkitsql::typeRecord $tag $view $layout ; guardReset $tag 1 }
    touchPath $path
}
