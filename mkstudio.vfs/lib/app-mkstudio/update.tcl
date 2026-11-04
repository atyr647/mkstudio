# update.tcl -- finding, downloading, verifying and installing a newer MK Studio.  No Tk in here (tests/test_update.tcl
# drives all of it, including a real download and replacement, against a fake release feed).
#
# How it works
#   * The release list comes from the GitHub API (https://api.github.com/repos/<repo>/releases) - one plain GET, nothing
#     about you or your data is sent except the program's name and version in the User-Agent.
#   * tclkit has no TLS, so the transfer is done by a program the system already has: curl (Linux, macOS, Windows 10+),
#     wget, or PowerShell on Windows.  If none exists, "Check for Updates" says so and offers the web page.
#   * A downloaded file is checked against the SHA256SUMS file of the same release (sha256sum / shasum / certutil /
#     PowerShell).  This protects against a damaged or truncated download; it does NOT prove who published it - the
#     release files are not signed with a certificate (see README).  No checksum tool = no automatic install.
#   * Only a stand-alone starpack in a folder you can write to replaces itself: the new file is tried (`--selftest`),
#     the old one is kept as <name>.old, and if anything fails the old one is put back.  Installed copies (.deb, the .app
#     bundle, an installer's Program Files) are updated by downloading the new installer.
namespace eval ::update {
    variable api ""            ;# override for tests / mirrors:  MKS_UPDATE_API
    variable seq 0
    variable lastError ""
}

proc ::update::apiUrl {} {
    if {[info exists ::env(MKS_UPDATE_API)] && $::env(MKS_UPDATE_API) ne ""} { return $::env(MKS_UPDATE_API) }
    return "https://api.github.com/repos/$::version::repo/releases"
}
proc ::update::userAgent {} { return "MKStudio/$::version::current" }

# ---- running a program without freezing the window -----------------------------------------------------------------------
# returns {ok output}; ok is 0 on a non-zero exit, a failure to start or a timeout
proc ::update::run {argv {timeoutMs 120000}} {
    variable seq
    incr seq
    set var ::update::done$seq
    set $var ""
    if {[catch {open |[concat $argv [list 2>@1]] rb} ch]} { return [list 0 $ch] }
    fconfigure $ch -blocking 0 -translation binary
    set ::update::buf$seq ""
    fileevent $ch readable [list ::update::onReadable $ch $seq]
    set timer [after $timeoutMs [list set $var timeout]]
    if {[set $var] eq ""} { vwait $var }
    after cancel $timer
    set result [set $var]
    set out [set ::update::buf$seq]
    catch {fileevent $ch readable {}}
    if {$result eq "timeout"} {
        catch {exec kill [pid $ch]} ; catch {exec taskkill /F /PID [pid $ch]}
        catch {close $ch}
        unset -nocomplain $var ::update::buf$seq
        return [list 0 "timed out"]
    }
    fconfigure $ch -blocking 1
    set rc [catch {close $ch} err]
    unset -nocomplain $var ::update::buf$seq
    return [list [expr {!$rc}] $out]
}
proc ::update::onReadable {ch seq} {
    if {[catch {read $ch} d]} { set d "" ; set eof 1 } else { set eof [eof $ch] }
    append ::update::buf$seq $d
    if {$eof} { set ::update::done$seq eof }
}

# ---- transfer ---------------------------------------------------------------------------------------------------------------
proc ::update::tool {name} {
    if {$::tcl_platform(platform) eq "windows"} { return [winTool $name] }
    set p [auto_execok $name]
    if {$p eq "" || $p eq "0"} { return "" }
    return [lindex $p 0]
}
# A Windows program by its full path in the system folder.  Tcl's search for a bare name looks in the folder of the running
# program and in the current folder BEFORE the system folders: a curl.exe or certutil.exe dropped next to a downloaded
# starpack (or in the folder it was started from) would run on every update check.  Only the system's own copies are used.
proc ::update::winTool {name} {
    set root [expr {[info exists ::env(SystemRoot)] ? $::env(SystemRoot) : {C:/Windows}}]
    foreach f [list $root/System32/$name.exe $root/System32/WindowsPowerShell/v1.0/$name.exe $root/Sysnative/$name.exe] {
        if {[file isfile $f]} { return $f }
    }
    return ""
}
# The argument list that runs a PowerShell script on Windows ({} when it cannot).  NOT straight from this program: a Windows GUI
# program has no console, Tcl starts console programs without one for it, and PowerShell then does nothing at all (exit status
# 0, no output, no effect - measured on real runners).  cmd.exe makes itself a console and the PowerShell it starts runs.  The
# script travels as -EncodedCommand (UTF-16 in base64): no quoting, no code page, any file name intact.  Output cannot be read
# back (no console to capture); a script that must report writes a file.  (Same as ::store::psCommand: this file stands alone.)
proc ::update::base64 {bytes} {
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
proc ::update::psCommand {script} {
    set ps [winTool powershell] ; set cmd [winTool cmd]
    if {$ps eq "" || $cmd eq ""} { return {} }
    return [list $cmd /c [file nativename $ps] -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand [base64 [encoding convertto unicode $script]]]
}
# which transfer program will be used ("" = none)
proc ::update::transport {} {
    foreach t {curl wget} { if {[tool $t] ne ""} { return $t } }
    if {$::tcl_platform(platform) eq "windows" && [tool powershell] ne ""} { return powershell }
    return ""
}
# download URL to FILE; raises an error with a readable message
proc ::update::download {url file {timeoutMs 180000}} {
    set tr [transport]
    if {$tr eq ""} { error "No program to download with was found (curl, wget or PowerShell)." }
    file delete -force $file.part
    switch -- $tr {
        curl {
            set cmd [list [tool curl] -fsSL --max-time [expr {$timeoutMs / 1000}] -A [userAgent] -H "Accept: application/vnd.github+json"]
            # GitHub allows 60 anonymous API requests an hour per network address - a shared address (an office, a CI runner)
            # can be out of them.  MKS_UPDATE_TOKEN (never set by the program itself) sends a token to the API host only.
            if {[info exists ::env(MKS_UPDATE_TOKEN)] && $::env(MKS_UPDATE_TOKEN) ne "" && [string match "https://api.github.com/*" $url]} {
                lappend cmd -H "Authorization: Bearer $::env(MKS_UPDATE_TOKEN)"
            }
            lappend cmd -o $file.part $url
        }
        wget {
            set cmd [list [tool wget] -q -T 60 -U [userAgent] -O $file.part $url]
        }
        powershell {
            # (everything is in the script, single-quoted; PowerShell is started the way psCommand says)
            set q {' ''}
            set script "\[Net.ServicePointManager\]::SecurityProtocol=\[Net.SecurityProtocolType\]::Tls12; \$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri '[string map $q $url]' -OutFile '[string map $q [file nativename $file.part]]' -UserAgent '[string map $q [userAgent]]'"
            set cmd [psCommand $script]
        }
    }
    lassign [run $cmd $timeoutMs] ok out
    if {!$ok || ![file exists $file.part]} {
        file delete -force $file.part
        error "Download failed: [string trim [string range $out 0 300]]"
    }
    file rename -force $file.part $file
    return $file
}
# A folder only this user can use, with a name nobody can guess, that did not exist a moment ago.  (A predictable name in a
# shared temp folder lets another user on the machine create it first and control what the updater downloads and reads.)
proc ::update::randomName {} {
    if {![catch {set h [open /dev/urandom rb] ; set r [read $h 8] ; close $h}] && [string length $r] == 8} {
        binary scan $r H* hex ; return $hex
    }
    expr {srand([clock microseconds] + [pid])}
    return [format %08x%08x [expr {int(rand() * 4294967296)}] [expr {int(rand() * 4294967296)}]]
}
proc ::update::scratch {} {
    set bases {}
    if {$::tcl_platform(platform) eq "windows"} {
        foreach v {LOCALAPPDATA TEMP TMP} { if {[info exists ::env($v)]} { lappend bases $::env($v) } }
    } else {
        if {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne ""} { lappend bases $::env(XDG_CACHE_HOME) }
        if {[info exists ::env(HOME)]} { lappend bases $::env(HOME)/.cache }
        foreach v {TMPDIR} { if {[info exists ::env($v)]} { lappend bases $::env($v) } }
        lappend bases /tmp
    }
    foreach b $bases {
        if {$b eq "" || (![file isdirectory $b] && [catch {file mkdir $b}])} continue
        set d [file join $b mkstudio-update-[randomName]]
        if {[file exists $d] || [catch {file mkdir $d}]} continue
        if {$::tcl_platform(platform) ne "windows"} {
            catch {file attributes $d -permissions 0700}
            # ours alone: owned by this user and closed to everybody else
            if {[catch {file attributes $d -owner} owner] || $owner ne $::tcl_platform(user)} { file delete -force $d ; continue }
            if {[catch {file attributes $d -permissions} perm] || ($perm & 0077)} { file delete -force $d ; continue }
        }
        return $d
    }
    error "No private folder for the update could be created."
}
proc ::update::readFile {f {enc utf-8}} { set h [open $f rb] ; set d [read $h] ; close $h ; return [encoding convertfrom $enc $d] }

# ---- JSON (the little the release list needs) ------------------------------------------------------------------------------
# objects -> dicts, arrays -> lists, strings -> strings, numbers as written, true/false/null as text
proc ::update::jsonParse {text} {
    set pos 0
    set v [jsonValue $text pos]
    jsonSpace $text pos
    if {$pos < [string length $text]} { error "JSON: unexpected text at $pos" }
    return $v
}
proc ::update::jsonSpace {t pv} {
    upvar 1 $pv pos
    regexp -start $pos -indices {\s*} $t m
    set pos [expr {[lindex $m 1] + 1}]
}
proc ::update::jsonValue {t pv} {
    upvar 1 $pv pos
    jsonSpace $t pos
    set c [string index $t $pos]
    switch -- $c {
        \{ {
            incr pos ; set d [dict create]
            jsonSpace $t pos
            if {[string index $t $pos] eq "\}"} { incr pos ; return $d }
            while 1 {
                jsonSpace $t pos
                if {[string index $t $pos] ne "\""} { error "JSON: key expected at $pos" }
                set k [jsonString $t pos]
                jsonSpace $t pos
                if {[string index $t $pos] ne ":"} { error "JSON: colon expected at $pos" }
                incr pos
                dict set d $k [jsonValue $t pos]
                jsonSpace $t pos
                set c [string index $t $pos] ; incr pos
                if {$c eq "\}"} break
                if {$c ne ","} { error "JSON: comma or brace expected at $pos" }
            }
            return $d
        }
        \[ {
            incr pos ; set l {}
            jsonSpace $t pos
            if {[string index $t $pos] eq "\]"} { incr pos ; return $l }
            while 1 {
                lappend l [jsonValue $t pos]
                jsonSpace $t pos
                set c [string index $t $pos] ; incr pos
                if {$c eq "\]"} break
                if {$c ne ","} { error "JSON: comma or bracket expected at $pos" }
            }
            return $l
        }
        \" { return [jsonString $t pos] }
        default {
            # (-start and ^ do not combine: match anywhere, then insist on the position)
            if {![regexp -start $pos -indices -- {-?[0-9][0-9.eE+-]*|true|false|null} $t m] || [lindex $m 0] != $pos} { error "JSON: unexpected character at $pos" }
            set lit [string range $t $pos [lindex $m 1]]
            set pos [expr {[lindex $m 1] + 1}]
            return $lit
        }
    }
}
proc ::update::jsonString {t pv} {
    upvar 1 $pv pos
    incr pos                                            ;# the opening quote
    set out ""
    while 1 {
        if {![regexp -start $pos -indices {[^"\\]*} $t m]} { error "JSON: bad string" }
        append out [string range $t $pos [lindex $m 1]]
        set pos [expr {[lindex $m 1] + 1}]
        set c [string index $t $pos]
        if {$c eq "\""} { incr pos ; return $out }
        if {$c eq ""} { error "JSON: unterminated string" }
        # a backslash escape
        incr pos
        set e [string index $t $pos] ; incr pos
        switch -- $e {
            n { append out "\n" } t { append out "\t" } r { append out "\r" } b { append out "\b" } f { append out "\f" }
            u {
                set hex [string range $t $pos [expr {$pos + 3}]] ; incr pos 4
                if {![regexp {^[0-9a-fA-F]{4}$} $hex]} { error "JSON: bad unicode escape" }
                scan $hex %x code
                # a surrogate pair is one character
                if {$code >= 0xD800 && $code < 0xDC00 && [string range $t $pos [expr {$pos + 1}]] eq "\\u"} {
                    set lo [string range $t [expr {$pos + 2}] [expr {$pos + 5}]]
                    if {[regexp {^[0-9a-fA-F]{4}$} $lo]} {
                        scan $lo %x low
                        if {$low >= 0xDC00 && $low < 0xE000} { set code [expr {0x10000 + (($code - 0xD800) << 10) + ($low - 0xDC00)}] ; incr pos 6 }
                    }
                }
                append out [format %c $code]
            }
            default { append out $e }
        }
    }
}

# ---- what is the newest release, and which file is mine ----------------------------------------------------------------------
# the platform name used in release file names
proc ::update::platformName {} {
    switch -- $::tcl_platform(platform) {
        windows { return windows-x86_64 }
        default {
            set m $::tcl_platform(machine)
            if {$m in {arm64 aarch64}} { set m arm64 } elseif {$m in {x86_64 amd64 x64}} { set m x86_64 }
            if {$::tcl_platform(os) eq "Darwin"} { return macos-$m }
            return linux-$m
        }
    }
}
# the stand-alone starpack's file name in a release
proc ::update::starpackAsset {} {
    set p [platformName]
    return [expr {[string match windows* $p] ? "mkstudio-$p.exe" : "mkstudio-$p"}]
}
# releases: the parsed list from the API.  Returns a dict (version tag notes page assets pre) of the newest release that is
# newer than `current`, or "" when there is none.  Drafts are never offered; pre-releases only when asked for.
proc ::update::newest {releases current includePre} {
    set best "" ; set bestV ""
    foreach r $releases {
        if {![dict exists $r tag_name]} continue
        if {[dict exists $r draft] && [dict get $r draft] eq "true"} continue
        set pre [expr {[dict exists $r prerelease] && [dict get $r prerelease] eq "true"}]
        if {$pre && !$includePre} continue
        set tag [dict get $r tag_name]
        if {[catch {::version::compare $tag $current} c] || $c <= 0} continue
        if {$best ne "" && [::version::compare $tag $bestV] <= 0} continue
        set assets {}
        if {[dict exists $r assets]} {
            foreach a [dict get $r assets] {
                if {[dict exists $a name] && [dict exists $a browser_download_url]} {
                    lappend assets [dict get $a name] [dict get $a browser_download_url]
                }
            }
        }
        set best [dict create version [string trimleft $tag vV] tag $tag pre $pre assets $assets \
            notes [expr {[dict exists $r body] ? [dict get $r body] : ""}] \
            page [expr {[dict exists $r html_url] ? [dict get $r html_url] : "https://github.com/$::version::repo/releases"}]]
        set bestV $tag
    }
    return $best
}
# Ask the server.  Returns "" (up to date) or the dict of `newest`; raises an error when the check itself fails.
proc ::update::check {{current ""} {includePre ""}} {
    if {$current eq ""} { set current $::version::current }
    if {$includePre eq ""} { set includePre [::version::isPrerelease $current] }
    set dir [scratch]
    set f [file join $dir releases.json]
    if {[catch {download [apiUrl] $f 60000} err]} {
        if {[string match "*403*" $err]} {
            error "GitHub refused the request - most likely too many update checks from this network address in the last hour. Try again later, or look at the releases page."
        } elseif {[string match "*404*" $err]} {
            error "GitHub has no release list for this program (error 404)."
        }
        error $err
    }
    set rel [jsonParse [readFile $f]]
    file delete -force $dir
    return [newest $rel $current $includePre]
}

# ---- checksums --------------------------------------------------------------------------------------------------------------
# SHA-256 of a file as lower-case hex, with whatever the system has; raises when nothing can do it
proc ::update::sha256 {file} {
    set nat [file nativename $file]
    set tries {}
    if {$::tcl_platform(platform) eq "windows"} {
        if {[tool certutil] ne ""} { lappend tries [list [tool certutil] -hashfile $nat SHA256] certutil }
    } else {
        if {[tool sha256sum] ne ""} { lappend tries [list [tool sha256sum] $file] sum }
        if {[tool shasum] ne ""} { lappend tries [list [tool shasum] -a 256 $file] sum }
        if {[tool openssl] ne ""} { lappend tries [list [tool openssl] dgst -sha256 $file] openssl }
    }
    foreach {cmd kind} $tries {
        lassign [run $cmd 120000] ok out
        if {!$ok} continue
        switch -- $kind {
            sum     { if {[regexp {^\s*([0-9a-fA-F]{64})} $out -> h]} { return [string tolower $h] } }
            openssl { if {[regexp {=\s*([0-9a-fA-F]{64})} $out -> h]} { return [string tolower $h] } }
            certutil {
                foreach line [split $out "\n"] {
                    set l [string tolower [string map {" " "" "\r" ""} $line]]
                    if {[regexp {^[0-9a-f]{64}$} $l]} { return $l }
                }
            }
        }
    }
    error "No program that can compute a SHA-256 checksum was found (sha256sum, shasum, certutil)."
}
# SHA256SUMS text -> dict name -> hash   (lines: "<hash>  <name>" or "<hash> *<name>")
proc ::update::parseSums {text} {
    set d [dict create]
    foreach line [split $text "\n"] {
        if {[regexp {^([0-9a-fA-F]{64})\s+\*?(\S.*?)\s*$} $line -> h n]} { dict set d $n [string tolower $h] }
    }
    return $d
}

# ---- can this copy replace itself? ------------------------------------------------------------------------------------------
# Returns the path of the running starpack when it may be replaced in place, otherwise "" and a reason in ::update::lastError
proc ::update::selfReplaceable {{exe ""}} {
    variable lastError
    if {![info exists ::starkit::mode] || $::starkit::mode ne "starpack"} { set lastError "this copy runs from source or as a starkit, not as a starpack" ; return "" }
    if {$exe eq ""} { set exe [info nameofexecutable] }
    set exe [file normalize $exe]
    if {[string match "*.app/Contents/*" $exe]} { set lastError "this copy is inside an application bundle" ; return "" }
    # a copy the package manager installed (/usr/bin/mkstudio from the .deb) belongs to it, and root can write there: replacing it
    # would leave dpkg with a file it does not recognise
    foreach pre {/usr/bin/ /usr/sbin/ /usr/lib/ /usr/share/ /bin/ /sbin/} {
        if {[string first $pre $exe] == 0} { set lastError "this copy was installed by the system's package manager - install the new .deb instead" ; return "" }
    }
    if {![file isfile $exe] || ![file writable $exe] || ![file writable [file dirname $exe]]} {
        set lastError "the folder or file is not writable (an installed copy)" ; return ""
    }
    return $exe
}
# Download the new starpack, verify it, test it, swap it in.  `progress` is a command called with a text.  Returns the path.
proc ::update::install {info {progress {}} {target ""}} {
    set exe [selfReplaceable $target]
    if {$exe eq ""} { error "Cannot update in place: $::update::lastError." }
    set assets [dict get $info assets]
    set name [starpackAsset]
    if {![dict exists $assets $name]} { error "This release has no file named $name." }
    if {![dict exists $assets SHA256SUMS]} { error "This release has no SHA256SUMS file, so the download cannot be verified." }
    set dir [scratch]
    if {$progress ne ""} { {*}$progress "Downloading checksums..." }
    download [dict get $assets SHA256SUMS] $dir/SHA256SUMS 60000
    set sums [parseSums [readFile $dir/SHA256SUMS]]
    if {![dict exists $sums $name]} { error "SHA256SUMS does not list $name." }
    if {$progress ne ""} { {*}$progress "Downloading [dict get $info version]..." }
    set new $exe.new
    download [dict get $assets $name] $new 600000
    if {$progress ne ""} { {*}$progress "Verifying..." }
    set got [sha256 $new]
    if {$got ne [dict get $sums $name]} {
        file delete -force $new $dir
        error "The download is damaged: its SHA-256 checksum does not match the release's SHA256SUMS."
    }
    catch {file attributes $new -permissions 0755}
    if {$progress ne ""} { {*}$progress "Testing the new version..." }
    set out $dir/selftest.txt
    lassign [run [list $new --selftest $out] 60000] ok msg
    if {!$ok || ![file exists $out] || ![string match "ok *" [readFile $out]]} {
        file delete -force $new $dir
        error "The downloaded program did not start correctly, so nothing was changed. [string trim [string range $msg 0 200]]"
    }
    set reported [lindex [readFile $out] 1]
    if {$reported ne [dict get $info version]} {
        file delete -force $new $dir
        error "The downloaded program reports version $reported, not [dict get $info version]; nothing was changed."
    }
    if {$progress ne ""} { {*}$progress "Installing..." }
    set old $exe.old
    variable deferred ; set deferred 0
    if {$::tcl_platform(platform) eq "windows"} {
        # A running starpack keeps its own file open (the starkit mount) without sharing it for rename or delete, so on Windows
        # the program cannot be replaced while it runs (measured on a real runner: "permission denied" on the rename).  The
        # verified download stays next to it as <name>.new and a small script waits for the program to exit, swaps the files
        # (keeping the old one as <name>.old) and - if <name>.restart exists by then - starts the new one.
        if {[catch {stageWindows $exe $new} err]} {
            file delete -force $new $dir
            error "Could not prepare the update ($err); nothing was changed."
        }
        set deferred 1
        file delete -force $dir
        return $exe
    }
    # The way back (<name>.old) is made WITHOUT touching the program's own name - a hard link to the same file, or a copy where
    # links are not possible - and the new version then replaces the program in ONE rename.  (Renaming the program away first and
    # the new one into its place second leaves, for an instant, no program at all: a crash or power cut there is a program
    # that is gone.)  A running program is not disturbed: it keeps the old file open.
    file delete -force $old
    if {[catch {file link -hard $old $exe}] && [catch {file copy -force $exe $old} copyErr]} {
        file delete -force $new $dir
        error "Could not keep the old version as $old ($copyErr); nothing was changed."
    }
    if {[catch {file rename -force $new $exe} err]} {
        file delete -force $old $new $dir
        error "Could not put the new version in place ($err); the old one is untouched."
    }
    file delete -force $dir
    return $exe
}
# Windows: start the helper that completes the update once the program has exited.
# A running starpack cannot be replaced, so the verified download waits as <name>.new and a PowerShell process - started now,
# in the background - waits for the program to exit, swaps the files (the old one becomes <name>.old; retried for a moment if a
# virus scanner holds the new one, and put back if it cannot be placed) and starts the new one when <name>.restart exists.
# It waits for as long as the program runs (the user may keep working for hours) and stops when <name>.new is gone.
# The paths are IN the command text, single-quoted (a quote inside a name is doubled): the command line reaches PowerShell as
# Unicode, so a folder like "Jos\u00e9 (work)" works; environment variables and batch files (the code page of cmd) do not carry
# such names intact.
namespace eval ::update { variable deferred 0 }
proc ::update::psq {s} { return "'[string map {' ''} $s]'" }
proc ::update::helperCommand {exe} {
    set e [psq [file nativename $exe]]
    # (one statement per line: this is script text, not a command line)
    return [join [list \
        "\$exe = $e" \
        "\$new = \$exe + '.new'" \
        "\$old = \$exe + '.old'" \
        "\$mark = \$exe + '.restart'" \
        "while (Test-Path -LiteralPath \$new) {" \
        "  try { Move-Item -LiteralPath \$exe -Destination \$old -Force -ErrorAction Stop } catch { Start-Sleep -Seconds 1; continue }" \
        "  \$placed = \$false" \
        "  for (\$i = 0; \$i -lt 15; \$i++) {" \
        "    try { Move-Item -LiteralPath \$new -Destination \$exe -Force -ErrorAction Stop; \$placed = \$true; break } catch { Start-Sleep -Seconds 1 }" \
        "  }" \
        "  if (-not \$placed) { Move-Item -LiteralPath \$old -Destination \$exe -Force; break }" \
        "  if (Test-Path -LiteralPath \$mark) { Remove-Item -LiteralPath \$mark -Force; Start-Process -FilePath \$exe }" \
        "  break" \
        "}"] "\n"]
}
proc ::update::stageWindows {exe new} {
    set argv [psCommand [helperCommand $exe]]
    if {![llength $argv]} { error "PowerShell was not found, which is needed to start the update helper" }
    if {[catch {exec {*}$argv > NUL 2> NUL &} err]} {
        error "the update helper could not be started: [string range $err 0 200]"
    }
    return $exe.new
}
# ask the helper script (Windows) to start the new program as soon as it has replaced the old one
proc ::update::requestRestart {} {
    set exe [info nameofexecutable]
    catch {set h [open $exe.restart w] ; close $h}
}
# at start-up: remove a half-finished download.  <name>.old (the version before the last update) is KEPT: it is the way back -
# rename it over the program if the new version misbehaves; the next update replaces it.  A staged update (Windows) that is
# waiting for this program to exit keeps its .new; one that has been there a week was abandoned (the helper died with a log-off).
proc ::update::cleanup {} {
    if {![info exists ::starkit::mode] || $::starkit::mode ne "starpack"} return
    set exe [info nameofexecutable]
    if {$::tcl_platform(platform) eq "windows" && [file exists $exe.new]} {
        if {[catch {file mtime $exe.new} mt] || [clock seconds] - $mt < 7 * 86400} return
    }
    catch {file delete -force $exe.new}
    catch {file delete -force $exe.restart}
    catch {file delete -force $exe.update.cmd}        ;# (left by an earlier version of the helper)
}
# what `--selftest FILE` writes:  "ok <version> mk4tcl <yes|no>"
proc ::update::selftestText {} {
    set mk [expr {[llength [info commands ::mk::file]] > 0 || ![catch {package require Mk4tcl}] ? "yes" : "no"}]
    return "ok $::version::current mk4tcl $mk"
}
