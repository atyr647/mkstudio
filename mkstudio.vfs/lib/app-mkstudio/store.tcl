# store.tcl -- the ONLY file in MK Studio that talks to Mk4tcl (mk::*).
#
# Everything else (the MKQL engine, the explorer, the grids, the designer)
# goes through the ::store API below, so the Metakit surface area stays small
# and easy to audit.
#
# Vocabulary
#   tag     name Mk4tcl knows an open datafile by            (e.g. "demo")
#   path    a Metakit view path                              (e.g. "demo.people", "demo.people!3.skills")
#   layout  structured list of {name type sub} triples. type is one of
#           S I L F D B V.  For V (subview) `sub` is a nested layout; else {}.
#
# Written to run on Tcl 8.5 (classic tclkit) as well as 8.6.

namespace eval ::store {
    variable tags    {}     ;# open tags, in open order
    variable file    ;# tag -> absolute path
    variable ro      ;# tag -> read-only flag
    variable dirty   ;# tag -> number of uncommitted mutations
    variable gen     ;# tag -> generation (see ::store::generation)
    variable lockOwned   ;# tag -> {lock-file content} of the lock we hold (and must remove)
    variable lockedBy    ;# tag -> "pid host" of another process that holds a write lock (read-only opens)
    variable types {
        S {String  string}  I {Integer int}  L {Long long}
        F {Float   float}   D {Double  double}  B {Bytes bytes}
        V {Subview subview}
    }
    array set file {} ; array set ro {} ; array set dirty {} ; array set gen {} ; array set lockOwned {} ; array set lockedBy {}
}

# -- availability ------------------------------------------------------------
proc ::store::available {} {
    expr {[llength [info commands ::mk::file]] > 0}
}

proc ::store::typeName {t} {
    variable types
    if {[dict exists $types $t]} { return [lindex [dict get $types $t] 0] }
    return $t
}
proc ::store::typeKeyword {t} {
    variable types
    if {[dict exists $types $t]} { return [lindex [dict get $types $t] 1] }
    return string
}

# Map a user-written type word (int, text, blob, ...) to a Metakit type letter.
proc ::store::parseType {word} {
    switch -- [string tolower $word] {
        s - str - string - text - varchar - char   { return S }
        i - int - integer - smallint               { return I }
        l - long - bigint                          { return L }
        f - float - real                           { return F }
        d - double                                 { return D }
        b - bytes - blob - binary                  { return B }
    }
    return ""
}

# -- tags and files ----------------------------------------------------------
proc ::store::makeTag {path} {
    variable tags
    set base [file rootname [file tail $path]]
    regsub -all {[^A-Za-z0-9_]} $base _ base
    if {$base eq "" || [string is digit [string index $base 0]]} { set base db_$base }
    set tag $base ; set n 1
    while {[lsearch -exact $tags $tag] >= 0} { set tag ${base}_[incr n] }
    return $tag
}

# ---- advisory write lock ---------------------------------------------------------------------
# The shared concurrency policy for every component that writes a database (this app, the SQL
# engine, a server...) - the full protocol is in docs/CONCURRENCY.md.  In short: Metakit does no locking
# (measured: tests/test_crash_safety.tcl - a reader can see a half-written commit, two writers can
# overwrite each other), so a writer owns "<file>.lock" for as long as it has the file open for
# writing.  The file holds  "<pid> <host> [<role> [<endpoint>]]"  and is created atomically (O_EXCL).
# A lock whose process is dead (same host) is stale and is taken over, so a crash never locks a
# database for good; a lock from another host is always respected.  Programs that don't follow the
# protocol are not stopped - it is advisory.
namespace eval ::store {
    # how long an empty/garbled lock file, and a takeover mutex, may sit there before they count as abandoned
    # (protocol constants - 5 s and 10 s; only tests shorten them)
    variable emptyStale [expr {[info exists ::env(MKS_LOCK_EMPTY_STALE)] ? $::env(MKS_LOCK_EMPTY_STALE) : 5}]
    variable mutexStale [expr {[info exists ::env(MKS_LOCK_MUTEX_STALE)] ? $::env(MKS_LOCK_MUTEX_STALE) : 10}]
    variable lockRole ""       ;# a long-lived owner says what it is, e.g. "server" ...
    variable lockEndpoint ""   ;# ... and where clients should talk to it, e.g. "tcp://host:5433"
}
proc ::store::lockPath {path} { return $path.lock }

proc ::store::pidAlive {pid} {
    if {![string is integer -strict $pid] || $pid <= 0} { return 0 }
    if {$pid == [pid]} { return 1 }
    if {$::tcl_platform(platform) eq "windows"} {
        # (tasklist that cannot run is not evidence that the process is gone: never take a lock away on a guess)
        set tl [winTool tasklist]
        if {$tl eq "" || [catch {exec $tl /FI "PID eq $pid" /NH /FO CSV} out]} { return 1 }
        return [expr {[string first "\"$pid\"" $out] >= 0}]
    }
    if {[file isdirectory /proc/self]} {
        if {![file isdirectory /proc/$pid]} { return 0 }
        # a zombie (killed, but its parent has not collected it yet) still has a /proc entry - it is not running
        return [expr {[procState $pid] ni {Z X x}}]
    }
    # elsewhere: ask kill.  Only "no such process" means dead.  "Not permitted" (not ours to signal) is alive, and so is an
    # answer that is no answer - kill could not even be started (fork failed, out of resources on a loaded machine).  The
    # earlier version counted every failure as "dead": a live owner could then lose its lock to a second process.
    if {![killProbe $pid]} { return 0 }
    # it can be signalled - but a killed process nobody has collected yet (a zombie) is not running
    if {[catch {exec ps -o stat= -p $pid} st]} {
        # ps could not tell (the process may have just been collected): ask kill again
        return [killProbe $pid]
    }
    return [expr {![string match Z* [string trim $st]]}]
}
# 1 = alive or unknown, 0 = kill says there is no such process
proc ::store::killProbe {pid} {
    if {![catch {exec kill -0 $pid} msg]} { return 1 }
    if {[string match -nocase "*No such process*" $msg] || [string match -nocase "*ESRCH*" $msg]} { return 0 }
    return 1
}
proc ::store::thisHost {} { if {[catch {info hostname} h]} { return unknown } ; return $h }

# the state letter of a process on Linux (R S D T Z ...), "" when unknown
proc ::store::procState {pid} {
    if {[catch {set h [open /proc/$pid/stat r] ; set d [read $h] ; close $h}]} { return "" }
    return [lindex [string range $d [expr {[string last ")" $d] + 2}] end] 0]
}
# epoch second at which a local process started, "" where it cannot be found out.  Used to tell the process that wrote a lock
# from a LATER process that happens to have the same pid (after a reboot or a crash the system hands pids out again).
#   Linux    /proc/<pid>/stat field 22 and /proc/stat btime
#   macOS/BSD  ps -o etime= (elapsed time) subtracted from now
#   Windows  PowerShell Get-Process (~0.5 s; the answer is remembered for a few seconds)
namespace eval ::store { variable startCache [dict create] }
proc ::store::procStartTime {pid} {
    if {[file isdirectory /proc/self]} {
        if {[catch {set h [open /proc/$pid/stat r] ; set d [read $h] ; close $h}]} { return "" }
        set rest [string range $d [expr {[string last ")" $d] + 2}] end]
        set ticks [lindex $rest 19]
        if {![string is integer -strict $ticks]} { return "" }
        if {[catch {set h [open /proc/stat r] ; set st [read $h] ; close $h}] || ![regexp {btime (\d+)} $st -> btime]} { return "" }
        return [expr {$btime + $ticks / 100}]
    }
    variable startCache
    set now [clock seconds]
    if {[dict exists $startCache $pid]} {
        lassign [dict get $startCache $pid] when value
        if {$now - $when < 5} { return $value }
    }
    set value ""
    if {$::tcl_platform(platform) eq "windows"} {
        set tmpf [file join [expr {[info exists ::env(TEMP)] ? $::env(TEMP) : {C:/Windows/Temp}}] mks-start-[pid]-$pid.tmp]
        file delete -force $tmpf
        set q '[string map {' ''} [file nativename $tmpf]]'
        lassign [psRun "\$p=Get-Process -Id $pid -ErrorAction Stop; Set-Content -LiteralPath $q -Value ((\[DateTimeOffset\]\$p.StartTime).ToUnixTimeSeconds())"] ran ok out
        if {$ok && ![catch {set h [open $tmpf r] ; set out [string trim [read $h]] ; close $h}] && [string is integer -strict $out]} { set value $out }
        file delete -force $tmpf
    } else {
        if {![catch {exec ps -o etime= -p $pid} out]} {
            # [[dd-]hh:]mm:ss
            if {[regexp {^\s*(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)\s*$} $out -> dd hh mm ss]} {
                foreach v {dd hh mm ss} { set x [set $v] ; set $v [expr {$x eq "" ? 0 : [scan $x %d]}] }
                set value [expr {$now - ((($dd * 24 + $hh) * 60 + $mm) * 60 + $ss)}]
            }
        }
    }
    dict set startCache $pid [list $now $value]
    return $value
}
# A Windows program by its full path in the system folder.  The search Tcl does for a bare name looks in the folder of the
# running program and in the current folder BEFORE the system folders, so a planted powershell.exe / curl.exe there would run.
proc ::store::winTool {name} {
    if {$::tcl_platform(platform) ne "windows"} { return "" }
    set root [expr {[info exists ::env(SystemRoot)] ? $::env(SystemRoot) : {C:/Windows}}]
    foreach f [list $root/System32/$name.exe $root/System32/WindowsPowerShell/v1.0/$name.exe $root/Sysnative/$name.exe] {
        if {[file isfile $f]} { return $f }
    }
    return ""
}

# "<pid> <host> [<role> [<endpoint>]]"  (role "-" when only an endpoint is given)
proc ::store::lockText {} {
    variable lockRole ; variable lockEndpoint
    set t "[pid] [thisHost]"
    if {$lockRole ne "" || $lockEndpoint ne ""} { append t " [expr {$lockRole eq {} ? {-} : $lockRole}]" }
    if {$lockEndpoint ne ""} { append t " $lockEndpoint" }
    return $t
}
proc ::store::readLock {path} {
    set lf [lockPath $path]
    if {[catch {set h [open $lf r] ; set d [string trim [read $h 512]] ; close $h}]} { return "" }
    lassign [split $d " "] pid host role endpoint
    return [dict create pid $pid host $host role [expr {$role eq "-" ? "" : $role}] endpoint $endpoint text $d]
}

# What is the state of the lock on this database?  A dict:
#   state    free | ours | stale | held       ("held": a live (or remote) other process owns it)
#   pid host role endpoint                     (when there is a lock file)
proc ::store::lockInfo {path} {
    set l [readLock $path]
    if {![file exists [lockPath $path]]} { return [dict create state free] }
    if {$l eq ""} {
        # We could not read it.  If it has vanished meanwhile it is free; if it is still there, somebody we may not even read
        # (another user, a stricter umask) made it: that is a lock held by an owner we cannot name, never a free database.
        if {![file exists [lockPath $path]]} { return [dict create state free] }
        return [dict create state held pid 0 host unknown role "" endpoint "" text ""]
    }
    set state held
    set pid [dict get $l pid] ; set host [dict get $l host]
    if {![string is integer -strict $pid] || $host eq ""} {
        # empty or garbled: its creator is probably between creating and writing it; if it stays that
        # way for a while the creator died and the lock is stale
        if {![catch {file mtime [lockPath $path]} mt] && [clock seconds] - $mt > $::store::emptyStale} { set state stale }
    } elseif {$pid eq [pid] && $host eq [thisHost]} {
        set state ours
    } elseif {$host eq [thisHost]} {
        if {![pidAlive $pid]} {
            set state stale
        } else {
            # alive - but is it the process that wrote the lock, or a newer one that got the same pid?  (Linux: a
            # process that started AFTER the lock file was last written cannot be its owner.)
            # (Windows: asking costs a PowerShell start, about a second - not worth it, and not wanted inside the takeover guard,
            # for a lock that is only seconds old: a pid cannot be reused by a different program in that time.)
            if {![catch {file mtime [lockPath $path]} mt] && ($::tcl_platform(platform) ne "windows" || [clock seconds] - $mt > 30)} {
                set started [procStartTime $pid]
                if {$started ne "" && $started > $mt + 2} { set state stale }
            }
        }
    }
    return [dict merge $l [dict create state $state]]
}
# "pid host role endpoint" of a live foreign holder, or "" when the file is unlocked (or the lock is stale/ours)
proc ::store::lockHolder {path} {
    set i [lockInfo $path]
    if {[dict get $i state] ne "held"} { return "" }
    return [list [dict get $i pid] [dict get $i host] [dict get $i role] [dict get $i endpoint]]
}
proc ::store::lockedError {path holder} {
    lassign $holder hpid hhost hrole hend
    set who "pid $hpid on $hhost"
    if {$hrole ne ""} { append who ", $hrole" }
    if {$hend ne ""} { append who " at $hend" }
    return -code error -errorcode [list STORE LOCKED $hpid $hhost $hrole $hend] \
        "This database is open for editing in another process ($who):\n$path"
}
# test hook: a command called at named points of acquiring and releasing, so tests can kill the process there
namespace eval ::store { variable lockHook "" }
proc ::store::lockStep {name} { variable lockHook ; if {$lockHook ne ""} { {*}$lockHook $name } }

# Create the lock file atomically (O_EXCL) so two processes starting at once cannot both win.
# Returns the text written, "" when no lock could be made (read-only folder: carry on unlocked), or
# raises STORE LOCKED when somebody else owns it.  Replacing a stale lock happens under a mutex file
# (<file>.lock.guard), inside which the lock is judged again, deleted and re-created, so processes
# that all see the same stale lock cannot delete each other's fresh one: exactly one wins.  The mutex
# name and the 10 s abandonment rule are part of the protocol (docs/CONCURRENCY.md; mkit-sql implements the same).
proc ::store::takeLock {path} {
    set lf [lockPath $path] ; set mine [lockText]
    for {set attempt 0} {$attempt < 60} {incr attempt} {
        if {![catch {open $lf {WRONLY CREAT EXCL}} h]} {
            lockStep created
            puts -nonewline $h $mine ; close $h
            lockStep written
            # tidy up a takeover mutex abandoned by a crashed process
            if {![catch {file mtime $lf.guard} mt] && [clock seconds] - $mt > $::store::mutexStale} { catch {file delete $lf.guard} }
            return $mine
        }
        lockStep create-failed
        if {![file exists $lf]} {
            # The create failed and there is no file.  Either the folder won't let us make one (read-only,
            # no permission: carry on unlocked) or a competitor deleted the stale lock between our create and
            # this check (retry!).  Treating the second case as the first let two processes both "win".
            if {[string match -nocase "*permission*" $h] || [string match -nocase "*read-only*" $h] || ![file writable [file dirname $lf]]} { return "" }
            continue
        }
        set holder [lockHolder $path]
        if {$holder ne ""} { lockedError $path $holder }
        set mx $lf.guard
        if {![catch {open $mx {WRONLY CREAT EXCL}} mh]} {
            close $mh
            lockStep mutex
            if {[lockHolder $path] eq ""} {
                lockStep checked                             ;# (test hook: the stale verdict is in, nothing is deleted yet)
                catch {file delete $lf}
                lockStep deleted
                set rc [catch {open $lf {WRONLY CREAT EXCL}} h]
                catch {file delete $mx}
                if {!$rc} { puts -nonewline $h $mine ; close $h ; return $mine }
            } else { catch {file delete $mx} }
        } elseif {![catch {file mtime $mx} mt] && [clock seconds] - $mt > $::store::mutexStale} {
            catch {file delete $mx}                         ;# a takeover that crashed
        } else {
            after 40                                         ;# someone else is replacing the lock: give it a moment (~2.4 s in all)
        }
    }
    return -code error -errorcode [list STORE LOCKED 0 unknown "" ""] \
        "Could not take the lock on this database (another process is starting at the same moment), please repeat:\n$path"
}
# Remove OUR lock - only if the file still holds exactly what we wrote.  `lf` is the lock file, `mine` its content.
proc ::store::releaseLock {lf mine} {
    if {![catch {set h [open $lf r] ; set d [read $h] ; close $h}] && $d eq $mine} { catch {file delete $lf} }
}
proc ::store::lockedByOther {tag} { variable lockedBy ; if {[info exists lockedBy($tag)]} { return $lockedBy($tag) } ; return "" }

proc ::store::tags {} { variable tags ; return $tags }
proc ::store::exists {tag} { variable tags ; expr {[lsearch -exact $tags $tag] >= 0} }
proc ::store::path {tag}     { variable file ; return $file($tag) }
proc ::store::readonly {tag} { variable ro   ; return $ro($tag) }
proc ::store::dirty {tag}    { variable dirty; return $dirty($tag) }
proc ::store::touch {tag}    { variable dirty ; incr dirty($tag) ; touchGen $tag }
# A database's generation is a number drawn from ONE counter shared by every database in the process, so
# it never repeats: not after further changes, not after Roll Back, and not when the same file (or the same
# tag) is closed and opened again.  It changes whenever anything in the database may have changed, and is
# -1 while the database is not open.  Derived data (sorted orders, column copies, streaming results) is
# valid only for the generation it was built from, so it can never be mistaken for another state.
namespace eval ::store { variable genSeq 0 ; variable pump "" }
proc ::store::generation {tag} { variable gen ; if {[info exists gen($tag)]} { return $gen($tag) } ; return -1 }
proc ::store::touchGen {tag} { variable gen ; variable genSeq ; set gen($tag) [incr genSeq] }

# ---- derived-data cache ----------------------------------------------------------------------------
# A column copy or a sort order costs a full pass over the view (about 1.4 s for 500,000 rows) and a lot of
# memory in Tcl (every element is an object: ~50-60 bytes for a number, more for a string).  Keep a few,
# guarded by the generation, so sorting again, flipping the direction or running another
# ORDER BY ... LIMIT on the same column is instant.  The budget is in (estimated) BYTES, shared by all
# open databases, and the least recently used entries are evicted first.
#   ::store::cacheConfigure -budget <MB>      (default 256; env MKS_CACHE_MB; 0 turns the cache off)
#   ::store::cacheStats                        dict: entries bytes budget hits misses evictions
namespace eval ::store {
    variable cache [dict create]   ;# key -> {tag generation bytes value}, least recently used first
    variable cacheBytes 0
    variable cacheBudget [expr {[info exists ::env(MKS_CACHE_MB)] && [string is integer -strict $::env(MKS_CACHE_MB)] ? $::env(MKS_CACHE_MB) * 1048576 : 268435456}]
    variable cacheHits 0 ; variable cacheMisses 0 ; variable cacheEvictions 0
}
proc ::store::cacheConfigure {args} {
    variable cacheBudget
    foreach {k v} $args {
        switch -- $k {
            -budget { set cacheBudget [expr {int($v * 1048576)}] ; cacheTrim 0 }
            default { error "unknown option $k (use -budget <MB>)" }
        }
    }
    return [expr {$cacheBudget / 1048576.0}]
}
proc ::store::cacheStats {} {
    variable cache ; variable cacheBytes ; variable cacheBudget ; variable cacheHits ; variable cacheMisses ; variable cacheEvictions
    return [dict create entries [dict size $cache] bytes $cacheBytes budget $cacheBudget hits $cacheHits misses $cacheMisses evictions $cacheEvictions]
}
# about how much memory a list of values occupies as Tcl objects
proc ::store::estimateBytes {list} {
    set n [llength $list]
    if {$n == 0} { return 64 }
    set step [expr {max(1, $n / 64)}] ; set sum 0 ; set k 0
    for {set i 0} {$i < $n} {incr i $step} { incr sum [string length [lindex $list $i]] ; incr k }
    return [expr {$n * (48 + $sum / $k) + 64}]
}
proc ::store::cacheGet {tag key} {
    variable cache ; variable cacheHits ; variable cacheMisses
    if {![dict exists $cache $key]} { incr cacheMisses ; return {} }
    lassign [dict get $cache $key] t g c v
    if {$g != [generation $tag]} { cacheDrop $key ; incr cacheMisses ; return {} }
    # most recently used goes to the back
    dict unset cache $key ; dict set cache $key [list $t $g $c $v]
    incr cacheHits
    return [list $v]
}
proc ::store::cacheDrop {key} {
    variable cache ; variable cacheBytes
    if {![dict exists $cache $key]} return
    set cacheBytes [expr {$cacheBytes - [lindex [dict get $cache $key] 2]}]
    dict unset cache $key
}
proc ::store::cacheTrim {incoming} {
    variable cache ; variable cacheBytes ; variable cacheBudget ; variable cacheEvictions
    while {$cacheBytes + $incoming > $cacheBudget && [dict size $cache]} {
        cacheDrop [lindex [dict keys $cache] 0] ; incr cacheEvictions
    }
}
# `bytes` defaults to an estimate of the value's size
proc ::store::cachePut {tag key value {bytes {}}} {
    variable cache ; variable cacheBytes ; variable cacheBudget
    cacheDrop $key
    if {$bytes eq ""} { set bytes [estimateBytes $value] }
    if {$bytes > $cacheBudget} return                          ;# too big to keep
    cacheTrim $bytes
    dict set cache $key [list $tag [generation $tag] $bytes $value]
    incr cacheBytes $bytes
}
proc ::store::cacheClear {{tag {}}} {
    variable cache
    foreach k [dict keys $cache] { if {$tag eq {} || [lindex [dict get $cache $k] 0] eq $tag} { cacheDrop $k } }
}

proc ::store::fileSize {tag} {
    if {[catch {file size [path $tag]} n]} { return 0 }
    return $n
}

# The name a database is known by - and its lock file is named after: absolute, with every symbolic link resolved, the LAST
# component too (`file normalize` leaves that one alone).  Without this, opening `current.mk` (a link) and `real.mk` took two
# different locks on one file and the two writers overwrote each other's commits.
proc ::store::canonical {path} {
    set p [file normalize $path]
    for {set i 0} {$i < 40} {incr i} {
        if {[catch {file type $p} t] || $t ne "link"} break
        if {[catch {file readlink $p} target]} break
        set p [file normalize [file join [file dirname $p] $target]]
    }
    return $p
}
# the same file under two names (a hard link): same device and inode.  (Another PROCESS opening a hard link of a database that
# is open here takes a different lock file; the policy document lists this among the limits.)
proc ::store::sameFile {a b} {
    if {$a eq $b} { return 1 }
    if {[catch {file stat $a sa ; file stat $b sb}]} { return 0 }
    return [expr {$sa(ino) != 0 && $sa(ino) == $sb(ino) && $sa(dev) == $sb(dev)}]
}

# Open (or, when -create is given, create) a Metakit datafile.  Returns the tag.
# Files are always opened with -nocommit so nothing is written until the user
# commits -- closing a file never silently saves.
proc ::store::openFile {path args} {
    variable tags ; variable file ; variable ro ; variable dirty ; variable lockOwned ; variable lockedBy
    set create 0 ; set readonly 0
    foreach a $args {
        switch -- $a { -create {set create 1} -readonly {set readonly 1} }
    }
    set path [canonical $path]
    foreach t $tags {
        if {[sameFile $file($t) $path]} { error "File is already open as '$t'." }
    }
    if {!$create && ![file exists $path]} { error "File not found: $path" }
    set holder [lockHolder $path]
    set lf "" ; set mine "" ; set repairNote "" ; set integ ""
    if {!$readonly} {
        if {$holder ne ""} { lockedError $path $holder }
        set mine [takeLock $path]                        ;# before opening, so a refusal touches nothing
        set lf [expr {$mine eq "" ? "" : [lockPath $path]}]
        # with the lock held nobody else is mid-commit: put right a commit that was interrupted
        if {[file exists $path] && [catch {repairFile $path} repairNote]} { set repairNote "" }
        if {[file exists $path] && ![catch {integrityOnOpen $path} verdict]} { set integ $verdict }
    }
    set tag [makeTag $path]
    set opts {-nocommit}
    if {$readonly} { lappend opts -readonly }
    if {[catch {mk::file open $tag $path {*}$opts}]} {
        # very old Mk4tcl without -nocommit: fall back to the plain open
        if {[catch {mk::file open $tag $path {*}[expr {$readonly ? {-readonly} : {}}]} err]} {
            if {$lf ne ""} { releaseLock $lf $mine }
            error $err
        }
    }
    # Mk4tcl will "open" ANY file (a text file just looks like a database with no
    # views).  Refuse files that are neither Metakit nor empty, before anything
    # could be committed into them.  Metakit datafiles start with "JL" (or "LJ");
    # a starkit/starpack has no such header but does contain views.
    if {!$create && [file size $path] > 0 && ![hasMetakitSignature $path] && ![llength [mk::file views $tag]]} {
        catch {mk::file close $tag}
        if {$lf ne ""} { releaseLock $lf $mine }
        error "This file isn't a Metakit database, so it was not opened:\n$path"
    }
    lappend tags $tag
    if {$repairNote ne ""} { variable repaired ; set repaired($tag) $repairNote }
    if {$integ ne ""} { variable integrity ; set integrity($tag) $integ }
    set file($tag) $path ; set ro($tag) $readonly ; set dirty($tag) 0
    touchGen $tag
    if {$readonly} {
        if {$holder ne ""} { set lockedBy($tag) $holder }
    } elseif {$lf ne ""} {
        set lockOwned($tag) [list $lf $mine]
    } else {
        # opened for writing but no lock file could be made: the folder does not let this user create files, so there is also no
        # commit record, no backup and no checksum - saving works, but without any of the protection
        variable unprotected ; set unprotected($tag) 1
    }
    return $tag
}
namespace eval ::store { variable unprotected ; array set unprotected {} }
proc ::store::unprotectedNote {tag} {
    variable unprotected
    if {![info exists unprotected($tag)]} { return "" }
    return "The folder of this database does not allow new files, so MK Studio cannot lock it or keep a backup: saving works, but without protection against a crash, a power cut or a second program."
}

proc ::store::hasMetakitSignature {path} {
    if {[catch {
        set h [open $path rb] ; set sig [read $h 2] ; close $h
    }]} { return 0 }
    return [expr {$sig eq "JL" || $sig eq "LJ"}]
}

# Commands called with the tag just BEFORE a database is closed (streaming results freeze themselves here).
namespace eval ::store { variable closeHooks {} }
proc ::store::onClose {cmd} { variable closeHooks ; if {$cmd ni $closeHooks} { lappend closeHooks $cmd } }

proc ::store::closeFile {tag} {
    variable tags ; variable file ; variable ro ; variable dirty ; variable lockOwned ; variable lockedBy ; variable closeHooks
    foreach h $closeHooks { catch {{*}$h $tag} }
    if {[info exists lockOwned($tag)]} { releaseLock {*}$lockOwned($tag) ; unset lockOwned($tag) }
    lockStep released
    unset -nocomplain lockedBy($tag)
    catch {mk::file close $tag}
    set i [lsearch -exact $tags $tag]
    if {$i >= 0} { set tags [lreplace $tags $i $i] }
    unset -nocomplain file($tag) ro($tag) dirty($tag)
    cacheClear $tag
    unset -nocomplain ::store::gen($tag) ::store::repaired($tag) ::store::backedUp($tag) ::store::integrity($tag) ::store::unprotected($tag)
}

# ---- interrupted commits and power loss -------------------------------------------------------------------------
# What a Metakit commit does to the file (strace of a real commit, see tests/test_power_loss.tcl):
#   1. a few small in-place writes (an 8-byte marker in the old tail),
#   2. the new data and a new tail APPENDED after the end of the file,
#   3. LAST, the 8-byte header at offset 0, which holds the offset of the new end of the file.
# There is no fsync/fdatasync/msync anywhere.  Consequences, both measured:
#   * a crash between 2 and 3 leaves the OLD header and a LONGER file.  Metakit does not notice: it opens it as an
#     EMPTY database (no views, no error).  Plain kill tests rarely land in that few-millisecond window; a
#     deterministic one (strace fault injection) hits it every time.
#   * after a POWER CUT the pages may reach the disk in any order, e.g. the new header without the new data.
# The repairs below make both recoverable:
#   * before a commit starts, <file>.commit records the committed header and size (and is forced to disk where the OS
#     has `sync`); after it, the file is forced to disk and the record is removed.  If the record is found when the
#     database is opened for writing, the commit never finished (or was never confirmed): the header and size are put
#     back and the database is exactly what it was before that commit.  After a commit the record is first rewritten to
#     describe the finished file and only then deleted, so that a record which cannot be deleted (a virus scanner holds it on
#     Windows) or whose deletion is lost in a power cut can never undo a commit that was acknowledged.
#   * without a record, a file longer than its header says (an unfinished append) is cut back to the header's offset.
# Not covered: a disk that loses data it said was written, or a system with no way to force data out (Windows has no
# `sync` command, so there the protocol is as good as the OS's own write ordering - best effort).
namespace eval ::store { variable durable [expr {[info exists ::env(MKS_DURABLE)] ? $::env(MKS_DURABLE) : 1}] }   ;# 0 turns the `sync` calls off (the record and the repair stay); env MKS_DURABLE=0 for tests

proc ::store::commitRecord {path} { return $path.commit }

# {size S offset H header <8 bytes as hex>} for a Metakit file with the usual header, "" for anything else
proc ::store::headerInfo {path} {
    if {[catch {set h [open $path rb] ; set d [read $h 8] ; close $h}] || [string length $d] < 8} { return "" }
    set magic [string range $d 0 1]
    if {$magic eq "JL"} { binary scan $d x4I off } elseif {$magic eq "LJ"} { binary scan $d x4i off } else { return "" }
    if {[string index $d 2] ne "\x1a"} { return "" }
    binary scan $d H* hex
    return [dict create size [file size $path] offset $off header $hex]
}
# force the files (and the folder entry) to disk where the system can:
#   Linux/BSD  coreutils `sync FILE...`, else a plain `sync`
#   macOS      `sync` (flushes the OS cache; the drive's own cache is out of reach from Tcl)
#   Windows    FlushFileBuffers through PowerShell (.NET FileStream.Flush($true)), if PowerShell can be started
# Returns 1 when something was asked to force the data out, 0 when nothing could be (tests and the status line use it).
proc ::store::syncDisk {args} {
    variable durable
    if {!$durable} { return 0 }
    if {$::tcl_platform(platform) eq "windows"} { return [syncWindows {*}$args] }
    set paths {}
    foreach p $args { lappend paths $p ; lappend paths [file dirname $p] }
    if {[catch {exec sync {*}[lsort -unique $paths]}] && [catch {exec sync}]} { return 0 }
    return 1
}
namespace eval ::store { variable psOk -1 }
# base64 of a byte string (pure Tcl: no 8.6-only `binary encode`)
proc ::store::base64 {bytes} {
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
# The argument list that runs a PowerShell script on Windows, or {} when PowerShell is not there.
#   * NOT straight from this program: a Windows GUI program (the tclkit) has no console, Tcl starts console programs without
#     one for such a program, and PowerShell then does nothing at all - exit status 0, no output, no effect (measured on real
#     Windows runners, both with the 2014 and the current runtime).  That made the first version of the disk flush a no-op.
#     cmd.exe makes itself a console and PowerShell, started by it, runs.
#   * the script travels as -EncodedCommand (UTF-16 in base64): no quoting rules, no code page, any file name intact.
# PowerShell's output cannot be read back that way (there is no console to capture); a script that must report something writes
# a file.  The exit status does come back (a script error is a non-zero status).
proc ::store::psCommand {script} {
    set ps [winTool powershell] ; set cmd [winTool cmd]
    if {$ps eq "" || $cmd eq ""} { return {} }
    return [list $cmd /c [file nativename $ps] -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand [base64 [encoding convertto unicode $script]]]
}
# {ran ok output}: ran = 0 when PowerShell could not even be started; ok = 1 when the script finished without an error
proc ::store::psRun {script} {
    set argv [psCommand $script]
    if {![llength $argv]} { return [list 0 0 "PowerShell was not found"] }
    set rc [catch {exec {*}$argv 2>@1} out opts]
    if {$rc && [lindex [dict get $opts -errorcode] 0] ne "CHILDSTATUS"} { return [list 0 0 $out] }
    return [list 1 [expr {!$rc}] $out]
}
proc ::store::syncWindows {args} {
    variable psOk
    if {$psOk == 0} { return 0 }
    set files {}
    foreach p $args { if {[file isfile $p]} { lappend files [file nativename $p] } }
    if {![llength $files]} { return 1 }
    # The names are single-quoted PowerShell strings inside the script (a quote in a name is doubled).
    set quoted {}
    foreach f $files { lappend quoted '[string map {' ''} $f]' }
    set script "foreach(\$f in @([join $quoted ,])){ \$s=\[IO.File\]::Open(\$f,'Open','ReadWrite','ReadWrite'); try{ \$s.Flush(\$true) } finally{ \$s.Dispose() } }"
    lassign [psRun $script] ran ok out
    # not started at all (no PowerShell / no cmd): never try again.  Started and failed (a file another program keeps locked):
    # only THIS flush failed.
    set psOk $ran
    return $ok
}
# What a commit can fall back to: the file as it is now.  Three situations:
#   a Metakit file       -> "<header-hex16> <size>"
#   no file / 0 bytes    -> "empty 0"       (the first commit of a new database)
#   anything else        -> not protected   (a starkit, a foreign file)
proc ::store::beginCommit {path} {
    set info [headerInfo $path]
    if {$info ne ""} {
        set line "[dict get $info header] [dict get $info size]"
    } elseif {![file exists $path] || [file size $path] == 0} {
        set line "empty 0"
    } else {
        return 0
    }
    set rec [commitRecord $path]
    if {[catch { set h [open $rec w] ; puts -nonewline $h $line ; close $h }]} { return 0 }
    syncDisk $rec $path
    return 1
}
proc ::store::endCommit {path} {
    syncDisk $path
    set rec [commitRecord $path]
    # The record says "if you find me, undo the commit that follows".  Deleting it must not be the only thing that stands between
    # a finished commit and being undone: on Windows a virus scanner or a sync client can hold the file so the delete fails, and
    # on Linux the unlink can be lost in a power cut seconds after the data reached the disk (the old record then reverts an
    # acknowledged commit - or, for the first commit of a new database, empties it).  So first the record is rewritten to describe
    # the file AS IT NOW IS: found later, it finds nothing to undo.  Only then is it deleted.
    set info [headerInfo $path]
    set neutral 0
    if {$info ne ""} {
        set line "[dict get $info header] [dict get $info size]"
        if {![catch { set h [open $rec.tmp w] ; puts -nonewline $h $line ; close $h ; file rename -force $rec.tmp $rec }]} {
            set neutral 1
        } elseif {![catch { set h [open $rec w] ; puts -nonewline $h $line ; close $h }]} {
            set neutral 1                                   ;# (the rename can fail where the file is held open: write in place)
        }
        catch {file delete $rec.tmp}
        if {$neutral} { syncDisk $rec }
    }
    set gone [expr {![catch {file delete $rec}] && ![file exists $rec]}]
    if {!$gone && !$neutral} {
        # the data IS saved, but the record still describes the state before it and would undo it the next time the file is
        # opened for writing.  Say so rather than let a later open quietly take the data back.
        error "The changes were saved, but the leftover file\n$rec\ncould not be removed or updated (another program may be holding it). Close that program and delete the file, or the next open will undo this save."
    }
    catch {sumWrite $path}
}
# Put right an interrupted commit.  Needs the write lock.  Returns "" (nothing to do) or what was done.
proc ::store::repairFile {path} {
    set rec [commitRecord $path]
    set info [headerInfo $path]
    if {[file exists $rec]} {
        if {[catch {set h [open $rec r] ; set d [string trim [read $h]] ; close $h}]} { return "" }
        lassign [split $d " "] hex size
        if {$hex eq "empty" && $size == 0} {
            # the first commit of a new database was interrupted: it is a new, empty database again
            file delete $rec
            if {[file exists $path] && [file size $path] > 0} {
                set h [open $path r+b] ; chan truncate $h 0 ; close $h
                syncDisk $path
                return "The first save of this new database was interrupted and has been undone: the database is empty again."
            }
            return ""
        }
        if {[string length $hex] == 16 && [string is integer -strict $size] && $info ne ""} {
            if {[file size $path] == $size && [dict get $info header] eq $hex} {
                file delete $rec                                      ;# the commit never wrote anything
                return ""
            }
            if {[file size $path] >= $size} {
                set h [open $path r+b]
                seek $h 0 start ; puts -nonewline $h [binary format H* $hex] ; flush $h
                chan truncate $h $size
                close $h
                syncDisk $path
                file delete $rec
                return "An unfinished commit was undone: the database is as it was before that commit."
            }
            # the file is SHORTER than it was before the commit: nothing we can put back
            return "Warning: this file is shorter than it was at its last commit - the database may be damaged."
        }
        file delete $rec
    }
    if {$info ne "" && [dict get $info size] > [dict get $info offset]} {
        set h [open $path r+b] ; chan truncate $h [dict get $info offset] ; close $h
        return "The unfinished end of an interrupted commit was discarded."
    }
    return ""
}

# ---- silent corruption: a checksum of the whole file, and a backup ----------------------------------------------------
# Metakit stores no checksums, so a flipped bit or a lost sector inside the data is invisible to it.  After every commit
# <file>.sum records "<crc32> <size> <mtime>" of the finished file.  When the file is next opened for writing the sum is
# checked - but only if size and modification time still match what was recorded (a file that another program has changed
# legitimately just gets a new baseline).  Same size, same time, different content = damaged: the file is not changed and
# the application offers the backup.  The backup <file>.bak is a copy of the file as it was before the first commit of an
# editing session; it is never overwritten by a copy that fails the check.  Files over `sumLimit` MB are not covered.
namespace eval ::store { variable sumLimit 512 ; variable backups 1 }

proc ::store::sumPath {path} { return $path.sum }
proc ::store::backupPath {path} { return $path.bak }
proc ::store::crcFile {path} {
    set crc 0
    set h [open $path rb]
    set rc [catch { while {![eof $h]} { set crc [zlib crc32 [read $h 4194304] $crc] } } err opts]
    close $h
    if {$rc} { return -options $opts $err }                       ;# (no `try` in Tcl 8.5)
    return [format %08x $crc]
}
proc ::store::sumCovered {path} { variable sumLimit ; expr {[file isfile $path] && [file size $path] <= $sumLimit * 1048576 && [file size $path] > 0} }
proc ::store::sumWrite {path} {
    if {![sumCovered $path]} { file delete [sumPath $path] ; return 0 }
    set line "[crcFile $path] [file size $path] [file mtime $path]"
    set tmp [sumPath $path].tmp
    set h [open $tmp w] ; puts -nonewline $h $line ; close $h
    file rename -force $tmp [sumPath $path]
    return 1
}
# ok | none (no sum / not covered) | changed (size or time differ: modified by something else) | damaged
proc ::store::sumCheck {path} {
    if {![sumCovered $path] || ![file exists [sumPath $path]]} { return none }
    if {[catch {set h [open [sumPath $path] r] ; set d [string trim [read $h]] ; close $h}] || [llength $d] != 3} { return none }
    lassign $d crc size mtime
    if {$size != [file size $path] || $mtime != [file mtime $path]} { return changed }
    return [expr {[crcFile $path] eq $crc ? "ok" : "damaged"}]
}
# keep a copy of the database as it is before this session changes it
proc ::store::backupBeforeCommit {path} {
    variable backups
    if {!$backups || ![sumCovered $path] || ![file exists $path]} { return 0 }
    if {[sumCheck $path] eq "damaged"} { return 0 }               ;# never replace a good backup with a bad copy
    set bak [backupPath $path]
    set size [file size $path]
    if {[catch {
        file copy -force $path $bak.tmp
        # a complete copy, and on the disk before it takes the old backup's place (a power cut must not leave a half-written one)
        if {[file size $bak.tmp] != $size} { error "short copy" }
        syncDisk $bak.tmp
        file rename -force $bak.tmp $bak
        syncDisk $bak
    }]} { catch {file delete $bak.tmp} ; return 0 }
    return 1
}
# The file failed its checksum and the user chose to go on anyway.  Whatever is saved from here on will be taken as the new
# normal, so a LATER session would copy the damaged data over the backup.  Keep a second copy of the good backup, which nothing
# overwrites (it is deleted again when it has been restored).
proc ::store::protectBackup {path} {
    set bak [backupPath $path]
    if {[file exists $bak] && ![file exists $bak.good]} {
        if {[catch {file copy $bak $bak.good.tmp ; syncDisk $bak.good.tmp ; file rename $bak.good.tmp $bak.good}]} { catch {file delete $bak.good.tmp} }
    }
}
# the backup to offer: the protected one if there is one (it is older than the damage was noticed), else the usual one
proc ::store::backupFile {path} {
    foreach f [list [backupPath $path].good [backupPath $path]] { if {[file exists $f]} { return $f } }
    return ""
}
# Put the backup back (the damaged file is kept as <file>.damaged, or .damaged.1, ... - an earlier one is never overwritten).
# Needs the write lock - call it with the file closed.
proc ::store::restoreBackup {path} {
    set path [canonical $path]
    set bak [backupFile $path]
    if {$bak eq ""} { error "There is no backup of this database." }
    if {[file exists $path]} {
        set dest $path.damaged ; set n 0
        while {[file exists $dest]} { set dest $path.damaged.[incr n] }
        file rename $path $dest
    }
    file copy -force $bak $path
    catch {file delete [sumPath $path] ; file delete [commitRecord $path]}
    catch {sumWrite $path}
    if {[string match *.good $bak]} { catch {file delete $bak} }
    return $path
}
# Remove the lock of a database that is NOT open for writing by anyone - after a crash, a restart, or a host that has been
# renamed.  The application asks the user first; this only does it.  Returns the text of the lock that was removed.
proc ::store::breakLock {path} {
    set path [canonical $path]
    set lf [lockPath $path] ; set old ""
    catch {set h [open $lf r] ; set old [read $h 512] ; close $h}
    file delete -force $lf $lf.guard
    return [string trim $old]
}
# at open for writing: the verdict (ok none changed damaged), and a new baseline when there is none or it is out of date
proc ::store::integrityOnOpen {path} {
    set v [sumCheck $path]
    if {$v eq "none" || $v eq "changed"} { catch {sumWrite $path} }
    return $v
}
namespace eval ::store { variable integrity ; array set integrity {} }
proc ::store::integrityState {tag} { variable integrity ; if {[info exists integrity($tag)]} { return $integrity($tag) } ; return "" }
# interrupted commits repaired during open, by tag - for the application to tell the user
namespace eval ::store { variable repaired ; array set repaired {} ; variable backedUp ; array set backedUp {} }
proc ::store::repairedNote {tag} { variable repaired ; if {[info exists repaired($tag)]} { return $repaired($tag) } ; return "" }

proc ::store::commit {tag} {
    variable dirty ; variable file ; variable backedUp
    set record 0
    if {$dirty($tag) > 0} {
        if {![info exists backedUp($tag)]} {
            if {[integrityState $tag] eq "damaged"} { protectBackup $file($tag) ; set backedUp($tag) 0 } else { set backedUp($tag) [backupBeforeCommit $file($tag)] }
        }
        set record [beginCommit $file($tag)]
    }
    mk::file commit $tag
    set dirty($tag) 0
    if {$record} { endCommit $file($tag) }
}

# Discard uncommitted work.  Newer Mk4tcl has `mk::file rollback`; for older
# builds we reopen the file (which is safe because we always use -nocommit).
proc ::store::rollback {tag} {
    variable dirty ; variable file ; variable ro
    if {[catch {mk::file rollback $tag}]} {
        set opts {-nocommit}
        if {$ro($tag)} { lappend opts -readonly }
        mk::file close $tag
        mk::file open $tag $file($tag) {*}$opts
    }
    set dirty($tag) 0
    touchGen $tag
}

# -- reading structure -------------------------------------------------------
# Metakit keeps a deleted view in `mk::file views` (with an empty layout) until
# the next commit, so a view only counts as present while it has a layout.
proc ::store::views {tag} {
    set out {}
    foreach v [mk::file views $tag] {
        if {[hasLayout $tag.$v]} { lappend out $v }
    }
    return [lsort -dictionary $out]
}

proc ::store::hasView {tag name} {
    if {[lsearch -exact [mk::file views $tag] $name] < 0} { return 0 }
    hasLayout $tag.$name
}
proc ::store::hasLayout {path} {
    if {[catch {mk::view layout $path} l]} { return 0 }
    expr {[string trim $l] ne ""}
}

# Parse the string Mk4tcl returns from `mk::view layout` into triples.
#   "name:S age:I {addr {street:S city:S}} note"
proc ::store::parseLayout {spec} {
    set out {}
    foreach el $spec {
        if {[llength $el] == 2} {
            lappend out [list [lindex $el 0] V [parseLayout [lindex $el 1]]]
        } else {
            set i [string first : $el]
            if {$i < 0} {
                lappend out [list $el S {}]
            } else {
                set t [string toupper [string range $el [expr {$i+1}] end]]
                lappend out [list [string range $el 0 [expr {$i-1}]] $t {}]
            }
        }
    }
    return $out
}

proc ::store::formatLayout {layout} {
    set parts {}
    foreach col $layout {
        lassign $col n t sub
        if {$t eq "V"} {
            lappend parts [list $n [formatLayout $sub]]
        } else {
            lappend parts $n:$t
        }
    }
    return $parts
}

# Layout of a view or subview.  Real Mk4tcl answers `mk::view layout` for a
# subview path ("db.view!3.sub") with the TOP-LEVEL view's layout, so descend
# through the nested definitions ourselves.
proc ::store::layout {path} {
    set base [lindex [split $path !] 0]
    set layout [parseLayout [mk::view layout $base]]
    foreach {-> name} [regexp -all -inline {!\d+\.([A-Za-z0-9_]+)} $path] {
        set col [findCol $layout $name]
        if {$col eq "" || [lindex $col 1] ne "V"} { error "no subview '$name' in $path" }
        set layout [lindex $col 2]
    }
    return $layout
}
proc ::store::size   {path} { mk::view size $path }

# -- reading rows ------------------------------------------------------------
# Fetch `count` rows starting at `first`, returning a list of value-lists in
# the order of `props` (which must all be scalar properties).
proc ::store::rows {path props first count} {
    set out {}
    set n [mk::view size $path]
    set last [expr {min($n, $first + $count) - 1}]
    set one [expr {[llength $props] == 1}]
    for {set i $first} {$i <= $last} {incr i} {
        if {[llength $props] == 0} {
            lappend out {}
        } elseif {$one} {
            # a single property comes back unwrapped, so wrap it ourselves
            lappend out [list [mk::get $path!$i [lindex $props 0]]]
        } else {
            lappend out [mk::get $path!$i {*}$props]
        }
    }
    return $out
}

# Rows `first`..`first+count-1`, each as a list of the `props` values (same order).
# This is the hot loop of every scan, so it is written for speed, not elegance.
proc ::store::fetch {path props first count} {
    set n [mk::view size $path]
    set last [expr {min($n, $first + $count) - 1}]
    set out {}
    switch -- [llength $props] {
        0 { for {set i $first} {$i <= $last} {incr i} { lappend out {} } }
        1 {
            set p [lindex $props 0]
            for {set i $first} {$i <= $last} {incr i} { lappend out [list [mk::get $path!$i $p]] }
        }
        default {
            for {set i $first} {$i <= $last} {incr i} { lappend out [mk::get $path!$i {*}$props] }
        }
    }
    return $out
}

# The same for an explicit list of row indices.
proc ::store::fetchAt {path props indices} {
    set out {}
    switch -- [llength $props] {
        0 { foreach i $indices { lappend out {} } }
        1 {
            set p [lindex $props 0]
            foreach i $indices { lappend out [list [mk::get $path!$i $p]] }
        }
        default {
            foreach i $indices { lappend out [mk::get $path!$i {*}$props] }
        }
    }
    return $out
}

# One column as a flat list, for all rows or just the given indices.
proc ::store::column {path prop {indices all}} {
    set out {}
    if {$indices eq "all"} {
        set tag [lindex [split $path .!] 0]
        set hit [cacheGet $tag [list col $path $prop]]
        if {[llength $hit]} { return [lindex $hit 0] }
        variable pump
        set n [mk::view size $path]
        for {set i 0} {$i < $n} {incr i} {
            lappend out [mk::get $path!$i $prop]
            if {$pump ne "" && $i % 50000 == 49999} { {*}$pump }         ;# lets a long read be cancelled
        }
        cachePut $tag [list col $path $prop] $out
    } else {
        foreach i $indices { lappend out [mk::get $path!$i $prop] }
    }
    return $out
}

# Row indices (ascending) that satisfy ALL of `conds`, evaluated inside Metakit.  Each cond is
# {exact|min|max property value}; min/max are inclusive.  An empty cond list is every row.
# Callers must only pass values valid for the property's type (see mkplan.tcl).
proc ::store::select {path conds} {
    if {![llength $conds]} {
        set n [mk::view size $path] ; set out {}
        for {set i 0} {$i < $n} {incr i} { lappend out $i }
        return $out
    }
    set args {}
    foreach c $conds { lassign $c op p v ; lappend args -$op $p $v }
    return [mk::select $path {*}$args]
}

proc ::store::cell {path idx prop} { mk::get $path!$idx $prop }

# Number of rows in the subview `prop` of row `idx`.
proc ::store::subSize {path idx prop} { mk::view size $path!$idx.$prop }

# -- writing rows ------------------------------------------------------------
# Returns the index of the new row.
proc ::store::appendRow {path props values} {
    set args {}
    foreach p $props v $values { lappend args $p $v }
    set cur [mk::row append $path {*}$args]
    touchPath $path
    return [lindex [split $cur !] end]
}

proc ::store::setCell {path idx prop value} {
    mk::set $path!$idx $prop $value
    touchPath $path
}

# ---- bulk mutation ---------------------------------------------------------------------------
# Metakit stores each column contiguously, so rewriting a variable-length value or deleting a row
# shifts everything after it: measured ~2-4 ms per change on 500,000 rows, while APPENDING costs
# ~3 us per row.  Past about a thousand changes it is therefore faster to rebuild the affected tail
# of the view: copy it (with the changes applied) into a scratch view, truncate the view, and append
# the copy back.  The result is identical to making the changes one by one.
namespace eval ::store {
    variable rebuildFloor 1000   ;# changes (or separate delete runs) from which rebuilding wins
}

# Copy rows from..to-1 of `src` onto the end of `dst` (same layout), subviews included.
# `drop` is a dict of source row indices to leave out; `mods` maps a source row index to a
# list {prop value ...} of replacement values.
proc ::store::copyRows {src dst layout from to drop mods} {
    set props {} ; set subs {}
    foreach c $layout {
        if {[lindex $c 1] eq "V"} { lappend subs $c } else { lappend props [lindex $c 0] }
    }
    for {set first $from} {$first < $to} {incr first 2000} {
        set count [expr {min(2000, $to - $first)}]
        set rows [fetch $src $props $first $count]
        set i $first
        foreach vals $rows {
            if {[dict exists $drop $i]} { incr i ; continue }
            if {[dict exists $mods $i]} {
                foreach {p v} [dict get $mods $i] { set k [lsearch -exact $props $p] ; if {$k >= 0} { lset vals $k $v } }
            }
            set args {}
            foreach p $props v $vals { lappend args $p $v }
            set cur [mk::row append $dst {*}$args]
            foreach c $subs {
                lassign $c name t sub
                set n [mk::view size $src!$i.$name]
                if {$n > 0} { copyRows $src!$i.$name $cur.$name $sub 0 $n {} {} }
            }
            incr i
        }
    }
}

# Rebuild the tail of `path` starting at its first affected row: append the transformed copy of
# rows lo..n-1 AFTER the existing last row, then remove the old tail in a single ranged delete.
# One copy, no scratch view, and until that last step the original rows are untouched - if the
# copy fails the view is cut back to its old size and nothing has changed.
proc ::store::rebuildRows {path drop mods} {
    set layout [layout $path]
    set n [mk::view size $path]
    set lo $n
    foreach i [concat [dict keys $drop] [dict keys $mods]] { if {$i < $lo} { set lo $i } }
    if {$lo >= $n} return
    if {[catch {
        copyRows $path $path $layout $lo $n $drop $mods
    } msg opts]} {
        catch {mk::view size $path $n}
        return -options $opts $msg
    }
    mk::row delete $path!$lo [expr {$n - $lo}]
    touchPath $path
}
proc ::store::hasVarColumns {layout} {
    foreach c $layout { if {[lindex $c 1] in {S B V}} { return 1 } }
    return 0
}

# Delete rows by index (any order; duplicates ignored).
proc ::store::deleteRows {path indices} {
    variable rebuildFloor
    # Consecutive rows go in ONE call (a run of 10,000 rows is a single delete); runs are
    # removed from the end so the indices stay valid.
    set idx [lsort -integer -unique $indices]
    set runs {}
    set start "" ; set prev ""
    foreach i $idx {
        if {$start ne "" && $i == $prev + 1} { set prev $i ; continue }
        if {$start ne ""} { lappend runs [list $start [expr {$prev - $start + 1}]] }
        set start $i ; set prev $i
    }
    if {$start ne ""} { lappend runs [list $start [expr {$prev - $start + 1}]] }
    if {[llength $runs] >= $rebuildFloor && [hasVarColumns [layout $path]]} {
        set drop [dict create]
        foreach i $idx { dict set drop $i 1 }
        rebuildRows $path $drop {}
        return
    }
    foreach r [lreverse $runs] {
        lassign $r first count
        if {$count == 1} { mk::row delete $path!$first } else { mk::row delete $path!$first $count }
    }
    touchPath $path
}

# Apply many cell changes at once.  `changes` maps a row index to {prop value ...}.  `tick`, when
# given, is called as  {*}$tick n  every 500 changes made one by one (it may raise to cancel).
proc ::store::updateRows {path changes {tick {}}} {
    variable rebuildFloor
    if {![dict size $changes]} return
    set varWrite 0
    set layout [layout $path]
    dict for {i kv} $changes {
        foreach {p v} $kv {
            set d [findCol $layout $p]
            if {$d ne "" && [lindex $d 1] in {S B}} { set varWrite 1 }
        }
        if {$varWrite} break
    }
    if {$varWrite && [dict size $changes] >= $rebuildFloor} {
        rebuildRows $path {} $changes
        return
    }
    set n 0
    foreach i [lsort -integer [dict keys $changes]] {
        if {$tick ne ""} { if {$n % 500 == 0} { {*}$tick $n } }
        foreach {p v} [dict get $changes $i] { mk::set $path!$i $p $v }
        incr n
    }
    touchPath $path
}

# Snapshot a row, including every nested subview row, for undo.
#   -> {vals {prop value ...} subs {name {snapshot snapshot ...} ...}}
proc ::store::captureRow {path idx} {
    set vals {} ; set subs {}
    foreach c [layout $path] {
        lassign $c n t
        if {$t eq "V"} {
            set rows {}
            set cnt [mk::view size $path!$idx.$n]
            for {set i 0} {$i < $cnt} {incr i} { lappend rows [captureRow $path!$idx.$n $i] }
            lappend subs $n $rows
        } else {
            lappend vals $n [mk::get $path!$idx $n]
        }
    }
    return [list vals $vals subs $subs]
}

# Put a snapshot back at position idx (appending when idx is past the end).
# Real Mk4tcl's `mk::row insert` only takes a count, so insert blank and fill.
proc ::store::restoreRow {path idx snap} {
    set n [mk::view size $path]
    if {$idx >= $n} {
        set idx $n
        mk::row append $path
    } else {
        mk::row insert $path!$idx 1
    }
    foreach {p v} [dict get $snap vals] { mk::set $path!$idx $p $v }
    foreach {name rows} [dict get $snap subs] {
        foreach r $rows { restoreRow $path!$idx.$name [mk::view size $path!$idx.$name] $r }
    }
    touchPath $path
    return $idx
}

proc ::store::touchPath {path} { touch [lindex [split $path .!] 0] }

# -- changing structure ------------------------------------------------------
proc ::store::createView {tag name layout} {
    if {[hasView $tag $name]} { error "View '$name' already exists in '$tag'." }
    mk::view layout $tag.$name [formatLayout $layout]
    touch $tag
}

proc ::store::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    mk::view delete $tag.$name
    touch $tag
}

# Apply a new layout. Metakit keeps data for properties whose name AND type are
# unchanged and drops the rest.
proc ::store::restructure {path layout} {
    mk::view layout $path [formatLayout $layout]
    touchPath $path
}

# Rename and/or retype a top-level scalar column of a view, preserving data.
# Metakit identifies a property by (name, type), so this adds the new column,
# copies the values across (coercing where needed), and drops the old one.
# The rebuilt column keeps its original position in the layout.
proc ::store::rebuildColumn {path oldName newName newType} {
    set layout [layout $path]
    set oldType ""
    foreach c $layout { if {[lindex $c 0] eq $oldName} { set oldType [lindex $c 1] } }
    if {$oldType eq "" || $oldType eq "V"} { error "'$oldName' is not a scalar column." }
    if {$newName ne $oldName} {
        foreach c $layout {
            if {[lindex $c 0] eq $newName} { error "Column '$newName' already exists." }
        }
    }
    set tmp __mks_tmp
    set base {}
    foreach c $layout { if {[lindex $c 0] ne $oldName} { lappend base $c } }
    set T [list $tmp $newType {}]
    set N [list $newName $newType {}]
    restructure $path [concat $layout [list $T]]
    copyColumn $path $oldName $tmp $newType
    restructure $path [concat $base [list $T]]
    restructure $path [concat $base [list $T $N]]
    copyColumn $path $tmp $newName $newType
    # put the column back where it was (restructuring keeps data whatever the order)
    set final {}
    foreach c $layout {
        if {[lindex $c 0] eq $oldName} { lappend final $N } else { lappend final $c }
    }
    restructure $path $final
}

proc ::store::copyColumn {path from to type} {
    set n [size $path]
    for {set i 0} {$i < $n} {incr i} {
        set v [mk::get $path!$i $from]
        switch -- $type {
            I - L { if {![string is integer -strict $v]} {
                        set v [expr {[string is double -strict $v] ? int($v) : 0}] } }
            F - D { if {![string is double -strict $v]} { set v 0 } }
        }
        mk::set $path!$i $to $v
    }
}

# -- helpers for editing ------------------------------------------------------
proc ::store::findCol {layout name} {
    foreach c $layout { if {[string equal -nocase [lindex $c 0] $name]} { return $c } }
    return ""
}
# Convert user-typed text to a value valid for the column type, or raise an error.
proc ::store::coerce {col type v} {
    switch -- $type {
        I - L {
            if {[string is wideinteger -strict [string trim $v]]} { return [string trim $v] }
            if {[string is double -strict [string trim $v]] && [string trim $v] == int([string trim $v])} { return [expr {int([string trim $v])}] }
            error "'$col' holds whole numbers, but '[string range $v 0 40]' isn't one."
        }
        F - D {
            if {[string is double -strict [string trim $v]]} { return [string trim $v] }
            error "'$col' holds numbers, but '[string range $v 0 40]' isn't one."
        }
    }
    return $v
}

# -- a small sample database -------------------------------------------------
proc ::store::createSample {path} {
    set tag [openFile $path -create]
    createView $tag departments {{id I {}} {name S {}} {location S {}} {budget D {}}}
    foreach {id n loc b} {
        1 Engineering "Berlin"   1250000.0
        2 Design      "Lisbon"    430000.0
        3 Sales       "New York"  880000.0
        4 Support     "Manila"    310000.0
        5 Research    "Zurich"   1520000.0
    } { appendRow $tag.departments {id name location budget} [list $id $n $loc $b] }

    createView $tag employees [list {id I {}} {name S {}} {dept I {}} {title S {}} \
        {salary D {}} {hired S {}} {active I {}} \
        [list skills V {{skill S {}} {level I {}}}]]
    set people {
        {Ada Lovelace}   {Grace Hopper}  {Alan Turing}    {Edsger Dijkstra} {Barbara Liskov}
        {Ken Thompson}   {Dennis Ritchie} {Margaret Hamilton} {Linus Torvalds} {Radia Perlman}
        {John Ousterhout} {Donald Knuth} {Tim Berners-Lee} {Frances Allen} {Guido van Rossum}
        {Jean Sammet}    {Larry Wall}    {Sophie Wilson}  {Brian Kernighan} {Anita Borg}
    }
    set titles {Engineer {Senior Engineer} Designer {Account Exec} {Support Lead} Researcher {Staff Engineer}}
    set skillNames {Tcl C Rust Python Figma SQL Metakit Networking Compilers Writing}
    set i 0
    foreach p $people {
        incr i
        set dept [expr {($i * 7) % 5 + 1}]
        set sal  [expr {52000 + (($i * 7919) % 61) * 1000 + ($i % 4) * 1500}]
        set hired [format %04d-%02d-%02d [expr {2008 + $i % 16}] [expr {1 + ($i * 5) % 12}] [expr {1 + ($i * 11) % 28}]]
        set row [appendRow $tag.employees {id name dept title salary hired active} \
            [list $i $p $dept [lindex $titles [expr {$i % 7}]] [format %.1f $sal] $hired [expr {$i % 9 != 0}]]]
        for {set k 0} {$k < 1 + $i % 4} {incr k} {
            appendRow $tag.employees!$row.skills {skill level} \
                [list [lindex $skillNames [expr {($i + $k * 3) % 10}]] [expr {1 + ($i + $k) % 5}]]
        }
    }

    createView $tag products {{sku S {}} {name S {}} {price D {}} {stock I {}} {discontinued I {}}}
    foreach {sku n price stock} {
        MK-001 "Keyboard 60%"        89.00  140
        MK-002 "Mechanical Switch x10" 12.50 920
        MK-003 "USB-C Cable 1m"        9.99  2210
        MK-004 "Desk Mat XL"          24.00  310
        MK-005 "Monitor Arm"          79.90   58
        MK-006 "Webcam 4K"           129.00   12
        MK-007 "Headphones"          199.00   73
        MK-008 "Laptop Stand"         45.00  165
    } { appendRow $tag.products {sku name price stock discontinued} [list $sku $n $price $stock [expr {$stock < 20}]] }

    createView $tag orders [list {id I {}} {customer S {}} {placed S {}} {status S {}} \
        [list lines V {{sku S {}} {qty I {}} {unit D {}}}]]
    set customers {Acme Globex Initech Umbrella Hooli Stark Wayne Wonka}
    set statuses {new paid shipped shipped shipped returned}
    for {set o 1} {$o <= 18} {incr o} {
        set row [appendRow $tag.orders {id customer placed status} [list [expr {1000+$o}] \
            [lindex $customers [expr {$o % 8}]] [format 2026-%02d-%02d [expr {1 + $o % 12}] [expr {1 + ($o*3) % 28}]] \
            [lindex $statuses [expr {$o % 6}]]]]
        for {set k 0} {$k < 1 + $o % 3} {incr k} {
            set p [expr {($o + $k * 2) % 8}]
            appendRow $tag.orders!$row.lines {sku qty unit} \
                [list MK-00[expr {$p+1}] [expr {1 + ($o+$k) % 4}] [lindex {89.00 12.50 9.99 24.00 79.90 129.00 199.00 45.00} $p]]
        }
    }
    commit $tag
    return $tag
}

