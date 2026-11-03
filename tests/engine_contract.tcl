# Contract test for a query engine plugged in behind ::engine (see engine.tcl).
#   tclsh tests/engine_contract.tcl                 (built-in MKQL; mock mk::)
#   REAL_MK=1 tclkit tests/engine_contract.tcl      (real Metakit)
# To test another engine, source it after engine.tcl below (it must redefine
# ::engine::parseScript / ::engine::execute and set the ::engine variables), and
# adjust the statements in `stmts` to your dialect.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
# source $here/../../my-sql-engine/engine.tcl

proc lmap_ {rows} { set o {} ; foreach r $rows { lappend o [llength $r] } ; return $o }
set pass 0 ; set fail 0
proc check {name ok {detail ""}} {
    global pass fail
    if {$ok} { incr pass } else { incr fail ; puts "FAIL $name  $detail" }
}
set f [tmp contract.mk] ; file delete $f
set db [store::createSample $f]

# statements in the dialect under test (edit these for another dialect)
array set stmts {
    select  "SELECT id, name, skills FROM employees WHERE id <= 3"
    agg     "SELECT dept, COUNT(*) FROM employees GROUP BY dept"
    insert  "INSERT INTO products (sku, name) VALUES ('Z-1', 'Zed')"
    bad     "SELEC 1"
    badsyn  "SELECT id FROM employees WHERE id = = 1"
    unknown "SELECT * FROM no_such_view"
}

# ---- variables ----
foreach v {name keywords functions types tokenRe maxRows progressHook cancel} {
    check var_$v [info exists ::engine::$v]
}
check keywords_nonempty [expr {[llength $::engine::keywords] > 0}]
check tokenRe_groups [expr {[llength [regexp -inline -indices $::engine::tokenRe "x"]] == 9}] "tokenRe needs exactly 8 capture groups"

# ---- parseScript ----
set parsed [::engine::parseScript "$stmts(select); $stmts(agg);"]
check parse_count [expr {[llength $parsed] == 2}]
lassign [lindex $parsed 0] h a b txt
check parse_offsets [expr {$a == 0 && $b > $a && [string match "SELECT*" $txt]}]
check parse_empty [expr {[llength [::engine::parseScript "   -- just a comment\n"]] == 0}]
check syntax_raises [catch {::engine::parseScript $stmts(bad)} m o]
set code [expr {[info exists o] ? [dict get $o -errorcode] : ""}]
check syntax_code [expr {[lindex $code 0] eq "MKQL" && [lindex $code 1] eq "SYNTAX" && [string is integer -strict [lindex $code 2]] && [lindex $code 3] > 0}] $code
catch {::engine::parseScript $stmts(badsyn)} m o
check syntax_pos [expr {[lindex [dict get $o -errorcode] 2] == [string first "= =" $stmts(badsyn)] + 2}] [dict get $o -errorcode]

# ---- execute: rowset ----
set r [::engine::execute [lindex [::engine::parseScript $stmts(select)] 0 0] $db]
check rs_kind [expr {[dict get $r kind] eq "rowset"}]
foreach k {cols types rows rowids drill source truncated editable} { check rs_has_$k [dict exists $r $k] }
set nc [llength [dict get $r cols]]
check rs_types_len [expr {[llength [dict get $r types]] == $nc}]
check rs_row_width [expr {[lsearch -not -exact [lmap_ [dict get $r rows]] $nc] < 0}]
check rs_rowids_1to1 [expr {[llength [dict get $r rowids]] in {0 3}}]
check rs_subview [expr {[dict get $r drill] eq "2 skills"}] [dict get $r drill]
check rs_source [expr {[dict get $r source] ne ""}]
set r2 [::engine::execute [lindex [::engine::parseScript $stmts(agg)] 0 0] $db]
check agg_no_rowids [expr {[llength [dict get $r2 rowids]] == 0}]
check agg_not_editable [expr {![dict get $r2 editable]}]

# ---- execute: message ----
set m [::engine::execute [lindex [::engine::parseScript $stmts(insert)] 0 0] $db]
check msg_kind [expr {[dict get $m kind] eq "message" && [dict get $m text] ne ""}]
check msg_effect [expr {[store::size $db.products] == 9}]

# ---- errors ----
check exec_error [catch {::engine::execute [lindex [::engine::parseScript $stmts(unknown)] 0 0] $db} em]
check exec_msg [expr {$em ne ""}]

# ---- cancel + progress ----
set ::engine::progressHook {incr ::ticks}
set ::ticks 0
::engine::execute [lindex [::engine::parseScript "SELECT * FROM employees"] 0 0] $db
set ::engine::progressHook {set ::engine::cancel 1}
set cancelled [catch {
    store::createView $db big {{n I {}}}
    for {set i 0} {$i < 3000} {incr i} { store::appendRow $db.big {n} [list $i] }
    ::engine::execute [lindex [::engine::parseScript "SELECT * FROM big WHERE n >= 0"] 0 0] $db
} em]
check cancel_aborts $cancelled $em
set ::engine::progressHook {} ; set ::engine::cancel 0
check cancel_resets [expr {![catch {::engine::execute [lindex [::engine::parseScript "SELECT * FROM big LIMIT 5"] 0 0] $db}]}]

puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
