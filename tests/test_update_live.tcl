# The update path against the REAL GitHub release feed (needs the internet; CI runs it on every OS).
# Everything else about updating is tested against a fake feed on disk (test_update.tcl); this is the part a fake cannot show:
# the real API's JSON, the real redirects of the real download URLs, the published SHA256SUMS, and the published starpack.
#   tclkit tests/run.tcl tests/test_update_live.tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
foreach f {version update} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 200]> want <[string range $want 0 200]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
unset -nocomplain ::env(MKS_UPDATE_API)

puts "feed: [::update::apiUrl]"
puts "this platform: [::update::platformName]  file: [::update::starpackAsset]"

# 1. something newer than 0.0.1 exists, and it names a file for this platform plus the checksums
set info ""
set err [catch {::update::check 0.0.1 1} info]
ok live_check_works [expr {!$err}] $info
if {$err} { puts "(the rest needs the check to work)" ; puts "$pass passed, $fail failed" ; exit 1 }
ok live_found_a_release [expr {$info ne ""}]
puts "newest release: [dict get $info tag] (pre-release: [dict get $info pre]) with [expr {[llength [dict get $info assets]] / 2}] files"
ok live_version_valid [expr {![catch {::version::parse [dict get $info version]}]}]
set assets [dict get $info assets]
set name [::update::starpackAsset]
ok live_has_my_starpack [dict exists $assets $name] [dict keys $assets]
ok live_has_sums [dict exists $assets SHA256SUMS]
ok live_has_page [string match "https://github.com/*" [dict get $info page]]
# every installer a release advertises must be in the checksums too
foreach {n u} $assets { ok "asset_url_$n" [string match "https://github.com/*" $u] $u }

# 2. nothing is newer than a far-future version; a final release is not offered to someone on a stable version unless newer
check live_up_to_date [::update::check 99.0.0 1] ""

# 3. the published checksums list every published file but themselves
set dir [::update::scratch]
::update::download [dict get $assets SHA256SUMS] $dir/SHA256SUMS 60000
set sums [::update::parseSums [::update::readFile $dir/SHA256SUMS]]
ok live_sums_parsed [expr {[dict size $sums] >= 4}] [dict size $sums]
foreach {n u} $assets {
    if {$n eq "SHA256SUMS"} continue
    ok "sums_list_$n" [dict exists $sums $n]
}

# 4. the real download (through GitHub's real redirect) matches its published checksum
set f $dir/$name
set t0 [clock milliseconds]
::update::download [dict get $assets $name] $f 600000
puts "downloaded $name: [file size $f] bytes in [expr {[clock milliseconds] - $t0}] ms"
ok live_download_not_empty [expr {[file size $f] > 1000000}] [file size $f]
check live_download_checksum [::update::sha256 $f] [dict get $sums $name]

# 5. the published starpack starts on this machine and reports the version the release says it is
catch {file attributes $f -permissions 0755}
set out $dir/selftest.txt
lassign [::update::run [list $f --selftest $out] 90000] okrun msg
ok live_selftest_ran $okrun $msg
set text [expr {[file exists $out] ? [::update::readFile $out] : ""}]
puts "selftest says: [string trim $text]"
ok live_selftest_ok [string match "ok * mk4tcl yes*" $text] $text
check live_selftest_version [lindex $text 1] [dict get $info version]

file delete -force $dir
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
