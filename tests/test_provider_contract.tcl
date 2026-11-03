# Runs the provider contract suite (tests/provider_contract.tcl) against the built-in engine's streaming results.
#   tclkit tests/test_provider_contract.tcl
# To check another engine, source provider_contract.tcl and call provider_contract::run with that engine's factory.
set here [file dirname [file normalize [info script]]]
source $here/util.tcl
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }
source $here/provider_contract.tcl
set f [tmp pcontract.mk] ; foreach x [glob -nocomplain $f*] { file delete $x }
set tag [store::openFile $f -create]
store::createView $tag t {{id I {}} {name S {}} {score D {}}}
for {set i 0} {$i < 300} {incr i} { store::appendRow $tag.t {id name score} [list $i "name [expr {$i % 13}]" [expr {($i * 7) % 11}]] }
store::commit $tag
set ::mkql::lazyMin 10
proc factory {sql} {
    global tag
    set r [mkql::run $sql $tag]
    if {![dict exists $r provider]} { error "not streamed: $sql" }
    return [list [dict get $r provider] [{*}[dict get $r provider] rows 0 100000]]
}
# NOTE: expected rows come from the provider itself on a fresh read of an ORDER BY query whose order is fully
# determined by the data, and are cross-checked against the reference executor below.
set total 0 ; set bad 0
foreach {label sql} {
    "plain scan"            "SELECT score, name FROM t"
    "ordered"               "SELECT score, id FROM t ORDER BY score, id"
    "filtered, descending"  "SELECT id, name FROM t WHERE id >= 50 ORDER BY id DESC"
    "computed column"       "SELECT id, id * 2 AS twice FROM t"
} {
    lassign [provider_contract::run "built-in: $label" [list factory $sql] {store::setCell $tag.t 0 name "changed behind its back"} {store::rollback $tag}] p f
    incr total $p ; incr bad $f
}
# the expected rows really are what the reference executor returns
source $here/mkql_reference.tcl
foreach sql {"SELECT score, name FROM t" "SELECT id, id * 2 AS twice FROM t"} {
    set stmt [lindex [mkql::parseScript $sql] 0 0]
    lassign [factory $sql] p rows
    set refRows [dict get [mkqlref::execSelect [lindex $stmt 1] $tag] rows]
    if {$rows ne $refRows} { incr bad ; puts "FAIL provider rows differ from the reference for: $sql" } else { incr total }
    {*}$p destroy
}
puts "$total passed, $bad failed"
exit [expr {$bad ? 1 : 0}]
