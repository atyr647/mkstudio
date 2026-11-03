# Crash reporting: what is in a report (and what is not), sessions that ended without a clean exit, the error handler.
#   tclkit tests/run.tcl tests/test_crash.tcl
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
foreach f {version store crash} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 200]> want <[string range $want 0 200]>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
proc readall {f} { set h [open $f r] ; fconfigure $h -encoding utf-8 ; set d [read $h] ; close $h ; return $d }

unset ::env(MKS_CRASH_FATAL)            ;# (util.tcl sets it: here the handler itself is under test)
set dir [tmp mks_crash_test] ; file delete -force $dir
set ::env(MKS_CRASH_DIR) $dir
check dir_override [::crash::dir] $dir

# ---- breadcrumbs ----------------------------------------------------------------------------------------------------------
for {set i 0} {$i < 100} {incr i} { ::crash::crumb "step $i" }
check ring_buffer_is_bounded [llength $::crash::crumbs] $::crash::crumbMax
ok ring_buffer_keeps_the_newest [string match "*step 99" [lindex $::crash::crumbs end]]
::crash::crumb "line one\nline two"
ok crumb_is_one_line [expr {[string first "\n" [lindex $::crash::crumbs end]] < 0}]

# ---- what goes into a report -----------------------------------------------------------------------------------------------
set ::env(HOME) /home/alice_secret
set ::env(USER) alice_secret
proc deep {sql} { inner $sql }
proc inner {sql} { error "no such column" }
catch {deep "SELECT salary FROM payroll WHERE name = 'Bob Private'"}
set info $::errorInfo
ok errorinfo_really_contains_the_sql [string match "*Bob Private*" $info]
set text [::crash::build "no such column in /home/alice_secret/data/payroll.mk" $info Unhandled]
ok report_has_version [string match "*Version:    $::version::current*" $text]
ok report_has_system [string match "*System:     $::tcl_platform(os)*" $text]
ok report_has_tcl [string match "*Tcl / Tk:   [info patchlevel]*" $text]
ok report_has_stack [expr {[string match "*inner line 1*" $text] && [string match "*deep line 1*" $text]}] $text
ok report_has_breadcrumbs [string match "*step 99*" $text]
ok report_has_no_sql [expr {![string match "*Bob Private*" $text] && ![string match "*payroll WHERE*" $text] && ![string match "*SELECT*" $text]}] $text
ok report_has_no_home [expr {![string match "*alice_secret*" $text]}] $text
ok report_shortens_db_paths [expr {[string match "*<folder>/<file>.mk*" $text] && ![string match "*payroll*" $text]}] $text
ok report_says_so [string match "*Nothing in this report comes from your databases*" $text]
# a very long message is cut
ok long_message_cut [expr {[string length [::crash::build [string repeat x 5000] "" Unhandled]] < 3000}]

# ---- found by the code review ---------------------------------------------------------------------------------------------
# a user name is text, not a pattern: these used to make the scrubber itself fail, so no report and no dialog appeared at all
foreach u {"Bob (Work" "Ann[x" "J.R. Smith" "a+b*c?" "x|y"} {
    set ::env(USER) $u
    set rc [catch {::crash::scrub "failed for $u in /home/$u/x.mk"} out]
    check "scrub_survives_user_name_$u" $rc 0
    ok "scrub_hides_user_name_$u" [expr {![string match "*$u*" $out]}] $out
}
set ::env(USER) alice_secret
# a value that sneaks into an error message stays out; plain names stay in (they make the message useful)
check scrub_quoted_value  [::crash::scrub "bad value 'Jane Roe 123-45-6789' for column"] "bad value '...' for column"
check scrub_double_quoted [::crash::scrub {expected "Credit Card 4111 1111" got x}] {expected "..." got x}
check scrub_keeps_names   [::crash::scrub {can't read "count": no such variable}] {can't read "count": no such variable}
check scrub_keeps_command [::crash::scrub {invalid command name "::store::nosuch"}] {invalid command name "::store::nosuch"}
check scrub_apostrophe_is_not_a_quote [::crash::scrub "isn't it 'odd' that it's fine"] "isn't it 'odd' that it's fine"
# paths with spaces, bare database names, Windows paths
check scrub_path_with_spaces [::crash::scrub "couldn't open /home/x/Clients Q3/acme corp.mk: no such file"] "couldn't open <folder>/<file>.mk: no such file"
check scrub_windows_path [::crash::scrub {failed C:\Program Files\App\y.exe: boom}] {failed <folder>/<file>.exe: boom}
check scrub_bare_db_names [::crash::scrub "no such table in customers.metakit and sales.mk4"] "no such table in <file>.metakit and <file>.mk4"
check scrub_leaves_and_or [::crash::scrub "read and/or write"] "read and/or write"
# rotation: a pile of "unexpected-end" reports (every kill or power cut adds one) must not push out a crash report
set rd [file join [::crash::ensureDir]] ; foreach x [glob -nocomplain -directory $rd *.txt] { file delete $x }
set ::crash::keep 5
for {set i 0} {$i < 8} {incr i} { ::crash::save "end $i" unexpected-end ; after 5 }
set fresh [::crash::save "the real crash" crash]
ok newest_crash_report_survives_many_unexpected_ends [file exists $fresh]
check each_kind_is_pruned_separately [llength [glob -directory $rd unexpected-end-*.txt]] 5
set ::crash::keep 20
foreach x [glob -nocomplain -directory $rd *.txt] { file delete $x }

# ---- saving and rotation ---------------------------------------------------------------------------------------------------
lassign [::crash::record "boom" $info] f t
ok report_file_written [file exists $f]
check file_equals_text [readall $f] $t
ok report_is_in_the_crash_dir [string match "$dir/*" $f]
set ::crash::keep 5
for {set i 0} {$i < 12} {incr i} { ::crash::save "x$i" crash ; after 5 }
ok rotation_keeps_only_the_newest [expr {[llength [glob -directory $dir *.txt]] <= 5}] [glob -directory $dir *.txt]
set ::crash::keep 20
# two reports in the same second do not overwrite each other
set a [::crash::save one crash] ; set b [::crash::save two crash]
ok no_overwrite [expr {$a ne $b && [readall $a] eq "one" && [readall $b] eq "two"}]

# ---- issue link ---------------------------------------------------------------------------------------------------------------
set u [::crash::issueUrl [string repeat "line of report\n" 1000]]
ok issue_url_host [string match "https://github.com/$::version::repo/issues/new?title=*&body=*" $u]
ok issue_url_is_bounded [expr {[string length $u] < 12000}] [string length $u]
ok issue_url_has_no_raw_newline_or_space [expr {![regexp {[\s]} $u]}]
check urlencode_ascii [::crash::urlEncode "a b&c=d/e"] "a%20b%26c%3Dd%2Fe"
check urlencode_utf8 [::crash::urlEncode [format %c 233]] "%C3%A9"

# ---- the handler: recorded once, never loops -------------------------------------------------------------------------------
file delete -force $dir ; file mkdir $dir
array unset ::crash::seen
::crash::handle "same problem" $info background
::crash::handle "same problem" $info background
::crash::handle "another problem" $info background
check handler_dedupes_by_signature [llength [glob -directory $dir crash-*.txt]] 2
# through the real bgerror path
::crash::install
file delete -force $dir ; file mkdir $dir
array unset ::crash::seen
after 0 {error "background boom"}
update
update
check bgerror_goes_to_the_reporter [llength [glob -nocomplain -directory $dir crash-*.txt]] 1
ok bgerror_report_names_the_error [string match "*background boom*" [readall [lindex [glob -directory $dir crash-*.txt] 0]]]
# an error inside the handler's own machinery must not loop or throw
rename ::crash::dialog ::crash::dialog_real
proc ::crash::dialog {args} { error "the dialog itself broke" }
set ::tk_version 8.6
array unset ::crash::seen
check handler_survives_a_broken_dialog [catch {::crash::handle "x" "" background}] 0
check handler_not_stuck_afterwards $::crash::inHandler 0
unset ::tk_version
rename ::crash::dialog {} ; rename ::crash::dialog_real ::crash::dialog

# ---- sessions that ended without a clean exit ------------------------------------------------------------------------------
file delete -force $dir ; file mkdir $dir
set kit [info nameofexecutable]
# a session left behind by a process that no longer exists
set h [open $dir/running-2000000000.log w]
puts $h "started 2026-01-01 10:00:00 version 1.0.0"
puts $h "10:00:01 database opened" ; puts $h "10:00:05 query executed" ; puts $h "10:00:06 committed"
close $h
set dead [::crash::start]
check one_dead_session [llength $dead] 1
check dead_session_pid [lindex $dead 0 1] 2000000000
ok own_marker_exists [file exists $dir/running-[pid].log]
set files [::crash::reportDead $dead]
check one_report [llength $files] 1
set rep [readall [lindex $files 0]]
ok dead_report_says_unexpected [string match "*ended unexpectedly*" $rep]
ok dead_report_has_the_crumbs [expr {[string match "*database opened*" $rep] && [string match "*committed*" $rep]}] $rep
ok dead_marker_removed [expr {![file exists $dir/running-2000000000.log]}]
ok dead_report_in_dir [string match "$dir/unexpected-end-*" [lindex $files 0]]
# our own marker follows the breadcrumbs
::crash::crumb "something happened"
ok marker_records_crumbs [string match "*something happened*" [readall $dir/running-[pid].log]]
::crash::cleanExit
ok clean_exit_removes_the_marker [expr {![file exists $dir/running-[pid].log]}]
check second_start_finds_nothing [llength [::crash::start]] 0
::crash::cleanExit

# a live neighbour is not a dead session; a REAL killed process is
file delete -force $dir ; file mkdir $dir
set ready $dir/ready1
set pidA [exec $kit $here/crash_session_child.tcl $dir $ready &]
for {set i 0} {$i < 100 && ![file exists $ready]} {incr i} { after 100 }
ok child_started [file exists $ready]
check live_neighbour_not_reported [llength [::crash::start]] 0
::crash::cleanExit
if {$::tcl_platform(platform) eq "windows"} { catch {exec taskkill /F /PID $pidA} } else { catch {exec kill -9 $pidA} }
for {set i 0} {$i < 100} {incr i} { after 100 ; if {![::store::pidAlive $pidA]} break }
set dead [::crash::start]
check killed_session_found [llength $dead] 1
set files [::crash::reportDead $dead]
set rep [readall [lindex $files 0]]
ok killed_session_report_has_crumbs [expr {[string match "*query executed*" $rep] && [string match "*committed*" $rep]}] $rep
::crash::cleanExit

file delete -force $dir
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]        ;# (explicit: a Windows GUI tclkit would otherwise wait in its event loop)
