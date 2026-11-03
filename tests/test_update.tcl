# The update path: version order, release feed parsing, choosing a release, a real download + checksum + self-test +
# replacement against a fake release feed on disk (file:// URLs), and every way that can go wrong.
#   tclkit tests/run.tcl tests/test_update.tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
foreach f {version update} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 200]> want <[string range $want 0 200]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
proc readall {f} { set h [open $f rb] ; set d [read $h] ; close $h ; return $d }
proc writebin {p d} { set h [open $p wb] ; puts -nonewline $h $d ; close $h }

# ---- version order -----------------------------------------------------------------------------------------------------------
foreach {a b want} {
    1.0.0 1.0.0 0   1.0.0-rc.1 1.0.0 -1   1.0.0 1.0.0-rc.1 1   1.0.0-rc.1 1.0.0-rc.2 -1   1.0.0-rc.2 1.0.0-rc.10 -1
    1.0.0-alpha 1.0.0-alpha.1 -1   1.0.0-alpha.1 1.0.0-alpha.beta -1   1.0.0-beta 1.0.0-alpha 1   v1.2 1.2.0 0
    1.10.0 1.9.9 1   2.0.0 1.99.99 1   1.0.0+b1 1.0.0 0   1.0.0-1 1.0.0-alpha -1} {
    check "compare $a $b" [::version::compare $a $b] $want
}
check parse_v [::version::parse v1.2.3-rc.1] {1 2 3 {rc 1}}
check prerelease_yes [::version::isPrerelease 1.0.0-rc.1] 1
check prerelease_no [::version::isPrerelease 1.0.0] 0
check bad_version [catch {::version::compare banana 1.0.0}] 1
check bad_version2 [catch {::version::compare 1.x.0 1.0.0}] 1
ok current_version_is_valid [expr {![catch {::version::parse $::version::current}]}]

# ---- JSON ----------------------------------------------------------------------------------------------------------------------
set j {{"a": 1, "b": [true, null, "x\ty\"z\\", {"c": []}], "d": {}, "e": "\u00e9\ud83d\ude00 \/ end", "f": -2.5e3}}
set d [::update::jsonParse $j]
check json_number [dict get $d a] 1
check json_array_len [llength [dict get $d b]] 4
check json_literals [lrange [dict get $d b] 0 1] {true null}
check json_escapes [lindex [dict get $d b] 2] "x\ty\"z\\"
check json_nested [dict get [lindex [dict get $d b] 3] c] {}
check json_empty_object [dict get $d d] {}
scan [string index [dict get $d e] 0] %c c0
check json_unicode_bmp $c0 233
scan [string index [dict get $d e] 1] %c c1
# (Tcl 8.5/8.6 strings hold only the basic plane: a character beyond it comes out as U+FFFD, never as an error)
ok json_surrogate_pair [expr {$c1 in {128512 65533}}] $c1
check json_slash [string range [dict get $d e] end-5 end] " / end"
check json_exponent [dict get $d f] -2.5e3
foreach {n bad} {unterminated {{"a": "x}} trailing {{"a":1} x} nocolon {{"a" 1}} badkey {{1: 2}} badarr {[1 2]} empty {} junk {nope}} {
    check "json_rejects_$n" [catch {::update::jsonParse $bad}] 1
}
# a big document is fast
set big "\[" ; for {set i 0} {$i < 3000} {incr i} { append big [expr {$i ? "," : ""}] "{\"id\":$i,\"name\":\"release $i\",\"assets\":\[{\"n\":\"a\"},{\"n\":\"b\"}\]}" } ; append big "\]"
set t0 [clock milliseconds] ; check json_big [llength [::update::jsonParse $big]] 3000
ok json_big_is_fast [expr {[clock milliseconds] - $t0 < 3000}] "[expr {[clock milliseconds] - $t0}] ms"

# ---- choosing a release --------------------------------------------------------------------------------------------------------
proc rel {tag args} { dict create tag_name $tag draft false prerelease false body "notes $tag" html_url "https://example.test/$tag" assets {} {*}$args }
set rels [list [rel v1.0.0-rc.1 prerelease true] [rel v1.0.0-rc.2 prerelease true] [rel v1.0.0] [rel v1.1.0 draft true] [rel v0.9.0] [rel garbage]]
check newest_for_rc1_with_pre [dict get [::update::newest $rels 1.0.0-rc.1 1] version] 1.0.0
check newest_for_rc1_no_pre [dict get [::update::newest $rels 1.0.0-rc.1 0] version] 1.0.0
check newest_skips_draft [::update::newest $rels 1.0.0 1] ""
check up_to_date [::update::newest $rels 1.0.0 1] ""
set rels2 [list [rel v1.0.0-rc.1 prerelease true] [rel v1.0.0-rc.3 prerelease true] [rel v1.0.0-rc.2 prerelease true]]
check newest_prerelease [dict get [::update::newest $rels2 1.0.0-rc.1 1] tag] v1.0.0-rc.3
check prerelease_hidden_from_stable [::update::newest $rels2 0.9.0 0] ""
check newest_notes [dict get [::update::newest $rels2 1.0.0-rc.1 1] notes] "notes v1.0.0-rc.3"
set withAssets [list [rel v2.0.0 assets [list [dict create name a browser_download_url http://x/a] [dict create name SHA256SUMS browser_download_url http://x/s]]]]
check assets_collected [dict get [::update::newest $withAssets 1.0.0 0] assets] {a http://x/a SHA256SUMS http://x/s}

# ---- platform names ---------------------------------------------------------------------------------------------------------------
set save [array get ::tcl_platform]
foreach {plat os machine want} {
    windows {Windows NT} amd64 mkstudio-windows-x86_64.exe
    unix Linux x86_64 mkstudio-linux-x86_64
    unix Linux aarch64 mkstudio-linux-arm64
    unix Darwin arm64 mkstudio-macos-arm64
    unix Darwin x86_64 mkstudio-macos-x86_64} {
    set ::tcl_platform(platform) $plat ; set ::tcl_platform(os) $os ; set ::tcl_platform(machine) $machine
    check "asset_name $os $machine" [::update::starpackAsset] $want
}
array set ::tcl_platform $save

# ---- checksums ----------------------------------------------------------------------------------------------------------------------
set f [tmp upd_abc.txt] ; writebin $f abc
set sums "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  upd_abc.txt\n[string repeat 0 64] *star.bin\nnot a line\n"
check parse_sums [::update::parseSums $sums] [dict create upd_abc.txt ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad star.bin [string repeat 0 64]]
if {[catch {::update::sha256 $f} h]} { puts "  (no checksum program here: $h)" } else {
    check sha256_of_abc $h ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
}
file delete $f

# ---- a real download against a fake release feed ----------------------------------------------------------------------------------------
set haveTool [expr {[::update::transport] ne ""}]
set haveSum [expr {![catch {::update::sha256 [tmp upd_abc.txt]}] || [file exists [tmp upd_abc.txt]] ? 1 : 0}]
writebin [tmp upd_abc.txt] abc ; set haveSum [expr {![catch {::update::sha256 [tmp upd_abc.txt]}]}] ; file delete [tmp upd_abc.txt]
proc fileUrl {p} { return file://[expr {[string index $p 0] eq "/" ? "" : "/"}][string map {\\ /} $p] }
if {!$haveTool} { puts "  (no curl/wget/PowerShell here: download tests skipped)" } else {
    set feed [tmp upd_feed] ; file delete -force $feed ; file mkdir $feed
    set exeName [::update::starpackAsset]
    # the "new version": a shell script that does what `--selftest` does
    proc newProgram {version {ok 1}} {
        if {!$ok} { return "#!/bin/sh\nexit 1\n" }
        return "#!/bin/sh\n\[ \"\$1\" = \"--selftest\" \] && echo \"ok $version mk4tcl yes\" > \"\$2\"\nexit 0\n"
    }
    proc makeFeed {feed version prog {sumOverride ""} {withSums 1} {withAsset 1}} {
        global exeName
        file delete -force $feed ; file mkdir $feed
        set assets {}
        if {$withAsset} {
            writebin $feed/$exeName $prog
            lappend assets "{\"name\":\"$exeName\",\"browser_download_url\":\"[fileUrl $feed/$exeName]\"}"
        }
        if {$withSums} {
            set hash [expr {$sumOverride ne "" ? $sumOverride : ($withAsset ? [::update::sha256 $feed/$exeName] : [string repeat 0 64])}]
            writebin $feed/SHA256SUMS "$hash  $exeName\n"
            lappend assets "{\"name\":\"SHA256SUMS\",\"browser_download_url\":\"[fileUrl $feed/SHA256SUMS]\"}"
        }
        writebin $feed/releases.json "\[{\"tag_name\":\"v$version\",\"draft\":false,\"prerelease\":true,\"body\":\"What is new\\nline 2 \\u00e9\",\"html_url\":\"https://example.test/r\",\"assets\":\[[join $assets ,]\]},{\"tag_name\":\"v0.1.0\",\"draft\":false,\"prerelease\":false,\"assets\":\[\]}\]"
        set ::env(MKS_UPDATE_API) [fileUrl $feed/releases.json]
    }
    set prog [newProgram 1.0.0-rc.2]
    makeFeed $feed 1.0.0-rc.2 $prog
    set info [::update::check 1.0.0-rc.1]
    check check_finds_the_new_release [dict get $info version] 1.0.0-rc.2
    check check_notes [string range [dict get $info notes] 0 11] "What is new\n"
    check check_page [dict get $info page] https://example.test/r
    check check_up_to_date [::update::check 1.0.0-rc.2] ""
    check check_older_current [dict get [::update::check 0.5.0 1] version] 1.0.0-rc.2
    # the feed cannot be fetched
    set ::env(MKS_UPDATE_API) [fileUrl $feed/does-not-exist.json]
    check check_failure_is_an_error [catch {::update::check 1.0.0-rc.1} msg] 1
    ok check_failure_message [string match "Download failed*" $msg] $msg
    set ::env(MKS_UPDATE_API) [fileUrl $feed/releases.json]
    # junk feed
    writebin $feed/releases.json "<html>rate limited</html>"
    check check_junk_feed [catch {::update::check 1.0.0-rc.1}] 1
    makeFeed $feed 1.0.0-rc.2 $prog

    if {$::tcl_platform(platform) eq "windows" || !$haveSum} { puts "  (self-replacement tests need a shell script and a checksum program: skipped here)" } else {
        namespace eval ::starkit {}
        set ::starkit::mode starpack
        set app [tmp upd_app] ; file delete -force $app ; file mkdir $app
        set exe $app/mkstudio ; writebin $exe "#!/bin/sh\necho old\n" ; file attributes $exe -permissions 0755
        set msgs {}
        proc note {m} { lappend ::msgs $m }
        # success
        set r [::update::install [::update::check 1.0.0-rc.1] note $exe]
        check install_returns_the_path [file normalize $r] [file normalize $exe]      ;# (macOS: /var is /private/var)
        check install_new_content [readall $exe] $prog
        check install_keeps_the_old_one [readall $exe.old] "#!/bin/sh\necho old\n"
        ok install_new_is_executable [file executable $exe]
        ok install_no_leftover_new [expr {![file exists $exe.new]}]
        ok install_reported_steps [expr {[llength $msgs] >= 4}] $msgs
        ok install_the_new_one_runs [expr {![catch {exec $exe --selftest $app/x.txt}] && [readall $app/x.txt] ne ""}]
        # the next update replaces .old as well
        writebin $exe "#!/bin/sh\necho old2\n" ; file attributes $exe -permissions 0755
        ::update::install [::update::check 1.0.0-rc.1] "" $exe
        check second_update_replaces_old_copy [readall $exe.old] "#!/bin/sh\necho old2\n"

        proc resetApp {} { global exe ; writebin $exe "#!/bin/sh\necho old\n" ; file attributes $exe -permissions 0755 ; file delete -force $exe.old $exe.new }
        # wrong checksum: nothing changes
        resetApp ; makeFeed $feed 1.0.0-rc.2 $prog [string repeat a 64]
        check bad_checksum_refused [catch {::update::install [::update::check 1.0.0-rc.1] "" $exe} msg] 1
        ok bad_checksum_message [string match "*damaged*checksum*" $msg] $msg
        check bad_checksum_changes_nothing [readall $exe] "#!/bin/sh\necho old\n"
        ok bad_checksum_leaves_no_download [expr {![file exists $exe.new] && ![file exists $exe.old]}]
        # a download that is cut short / altered after the sums were made
        resetApp ; makeFeed $feed 1.0.0-rc.2 $prog ; writebin $feed/$exeName "[string range $prog 0 20]"
        check truncated_download_refused [catch {::update::install [::update::check 1.0.0-rc.1] "" $exe}] 1
        check truncated_changes_nothing [readall $exe] "#!/bin/sh\necho old\n"
        # the new program does not start
        resetApp ; makeFeed $feed 1.0.0-rc.2 [newProgram x 0]
        check selftest_failure_refused [catch {::update::install [::update::check 1.0.0-rc.1] "" $exe} msg] 1
        ok selftest_failure_message [string match "*did not start correctly*nothing was changed*" $msg] $msg
        check selftest_failure_changes_nothing [readall $exe] "#!/bin/sh\necho old\n"
        ok selftest_failure_cleans_up [expr {![file exists $exe.new]}]
        # the new program reports another version than the release says
        resetApp ; makeFeed $feed 1.0.0-rc.2 [newProgram 9.9.9]
        check wrong_version_refused [catch {::update::install [::update::check 1.0.0-rc.1] "" $exe} msg] 1
        ok wrong_version_message [string match "*reports version 9.9.9*" $msg] $msg
        check wrong_version_changes_nothing [readall $exe] "#!/bin/sh\necho old\n"
        # no checksum file in the release: no automatic install
        resetApp ; makeFeed $feed 1.0.0-rc.2 $prog "" 0
        check no_sums_refused [catch {::update::install [::update::check 1.0.0-rc.1] "" $exe} msg] 1
        ok no_sums_message [string match "*SHA256SUMS*" $msg] $msg
        check no_sums_changes_nothing [readall $exe] "#!/bin/sh\necho old\n"
        # no file for this platform
        resetApp ; makeFeed $feed 1.0.0-rc.2 $prog "" 1 0
        check no_asset_refused [catch {::update::install [::update::check 1.0.0-rc.1] "" $exe} msg] 1
        ok no_asset_message [string match "*no file named $exeName*" $msg] $msg
        # a copy that must not replace itself
        resetApp ; makeFeed $feed 1.0.0-rc.2 $prog
        set ::starkit::mode starkit
        check starkit_not_replaceable [::update::selfReplaceable $exe] ""
        check starkit_install_refused [catch {::update::install [::update::check 1.0.0-rc.1] "" $exe}] 1
        set ::starkit::mode starpack
        file mkdir $app/MK.app/Contents/MacOS ; writebin $app/MK.app/Contents/MacOS/mkstudio x
        check app_bundle_not_replaceable [::update::selfReplaceable $app/MK.app/Contents/MacOS/mkstudio] ""
        ok app_bundle_reason [string match "*bundle*" $::update::lastError] $::update::lastError
        check missing_file_not_replaceable [::update::selfReplaceable $app/nothing] ""
        # cleanup() removes a half-finished download, keeps the way back
        writebin [info nameofexecutable].new junk
        file delete -force $app
    }
    file delete -force $feed
}
unset -nocomplain ::env(MKS_UPDATE_API)
# selftest text
ok selftest_text [string match "ok $::version::current mk4tcl *" [::update::selftestText]]
puts "$pass passed, $fail failed"
if {$fail} { exit 1 }
