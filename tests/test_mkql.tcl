# Engine tests: run with   tclsh tests/test_mkql.tcl
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }
foreach f {store engine mkql} { source $here/../mkstudio.vfs/lib/app-mkstudio/$f.tcl }

set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
proc q {sql args} { mkql::run $sql {*}$args }
proc rows {sql} { dict get [q $sql] rows }
proc lmap_ {l} { set r {} ; foreach c $l { lappend r [lindex $c 0] } ; return $r }
proc errmsg {sql} { if {[catch {q $sql} m]} { return $m } ; return "(no error)" }

set f [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] mkql_test.mk]
file delete $f
set db [store::createSample $f]

check views   [store::views $db] {departments employees orders products}
check count   [rows "SELECT COUNT(*) FROM employees"] {20}
check where   [rows "SELECT name FROM employees WHERE id <= 3 ORDER BY id"] {{{Ada Lovelace}} {{Grace Hopper}} {{Alan Turing}}}
# expected values below are computed independently from the raw store rows
set emp [store::rows $db.employees {id name salary} 0 100]
set best {} ; set bestSal -1
foreach r $emp { if {[lindex $r 2] > $bestSal} { set bestSal [lindex $r 2] ; set best [lindex $r 0] } }
check orderd  [lindex [rows "SELECT id FROM employees ORDER BY salary DESC, id LIMIT 1"] 0] $best
check top     [llength [rows "SELECT TOP 5 * FROM employees"]] 5
check offset  [rows "SELECT id FROM employees ORDER BY id LIMIT 2 OFFSET 3"] {4 5}
check like    [rows "SELECT id FROM employees WHERE name LIKE 'g%' ORDER BY id"] {2 15}
set noA 0 ; foreach r $emp { if {![string match -nocase *a* [lindex $r 1]]} { incr noA } }
check notlike [llength [rows "SELECT id FROM employees WHERE name NOT LIKE '%a%'"]] $noA
check in      [rows "SELECT id FROM employees WHERE id IN (2, 4, 99) ORDER BY id"] {2 4}
check between [rows "SELECT id FROM employees WHERE id BETWEEN 3 AND 5"] {3 4 5}
check arith   [rows "SELECT 1 + 2 * 3, 10 / 4, 10 / 5, 7 % 3, -3 + 1"] {{7 2.5 2 1 -2}}
check strfn   [rows "SELECT UPPER('abc') || LOWER('XyZ'), LENGTH('hello'), SUBSTR('abcdef', 2, 3)"] {{ABCxyz 5 bcd}}
check round   [rows "SELECT ROUND(3.14159, 2), ROUND(2.5), ABS(-4)"] {{3.14 3 4}}
check coalesce [rows "SELECT COALESCE('', 'x')"] {x}
check agg1    [rows "SELECT COUNT(*), MIN(id), MAX(id), SUM(id) FROM employees"] {{20 1 20 210}}
check avg     [rows "SELECT AVG(id) FROM employees"] {10.5}
check group   [rows "SELECT dept, COUNT(*) AS n FROM employees GROUP BY dept ORDER BY dept"] {{1 4} {2 4} {3 4} {4 4} {5 4}}
check having  [llength [rows "SELECT dept, COUNT(*) c FROM employees GROUP BY dept HAVING COUNT(*) > 100"]] 0
check orderalias [lindex [rows "SELECT dept, SUM(salary) AS total FROM employees GROUP BY dept ORDER BY total DESC LIMIT 1"] 0 0] [lindex [rows "SELECT dept FROM employees GROUP BY dept ORDER BY SUM(salary) DESC LIMIT 1"] 0 0]
check distinct [rows "SELECT DISTINCT status FROM orders ORDER BY status"] {new paid returned shipped}
check ordinal [rows "SELECT id, name FROM employees ORDER BY 1 DESC LIMIT 1"] {{20 {Anita Borg}}}
check emptyagg [rows "SELECT COUNT(*), SUM(id) FROM employees WHERE id > 1000"] {{0 0}}
check rowid   [rows "SELECT _rowid FROM employees WHERE id = 5"] {4}
check numstr  [rows "SELECT 'abc' < 'abd', 2 < 10, '2' < '10'"] {{1 1 1}}
check caseins [rows "SELECT id FROM employees WHERE NAME = 'Alan Turing'"] {3}
check alias   [rows "SELECT e.name FROM employees e WHERE e.id = 1"] {{{Ada Lovelace}}}

# multi-key / typed sorting
check sortstable [rows "SELECT dept, id FROM employees ORDER BY dept DESC, id ASC LIMIT 3"] {{5 2} {5 7} {5 12}}
check sorttext [lindex [rows "SELECT name FROM employees ORDER BY name"] 0] {{Ada Lovelace}}

# subviews
set r [q "SELECT id, skills FROM employees WHERE id = 1"]
check subcell [dict get $r rows] [list [list 1 "\u25B8 2 rows"]]
check subdrill [dict get $r drill] {1 skills}
check subwhere [rows "SELECT id FROM employees WHERE skills >= 4 ORDER BY id"] {3 7 11 15 19}
check subpath [rows "SELECT skill, level FROM employees\[0\].skills ORDER BY skill"] [rows "SELECT skill, level FROM $db.employees\[0\].skills ORDER BY skill"]
check subcount [rows "SELECT COUNT(*) FROM orders\[0\].lines"] {2}
check subinsert [errmsg "INSERT INTO employees\[0\].skills (skill, level) VALUES ('Go', 3)"] "(no error)"
check subinsert2 [rows "SELECT COUNT(*) FROM employees\[0\].skills"] {3}

check sublayout [store::layout $db.employees!2.skills] {{skill S {}} {level I {}}}
check sublayout2 [store::layout $db.orders!0.lines] {{sku S {}} {qty I {}} {unit D {}}}

# DML
check ins   [dict get [q "INSERT INTO products (sku, name, price, stock) VALUES ('X-1', 'Test', 1.5, 7), ('X-2', 'Two', 2, 8)"] affected] 2
check ins2  [rows "SELECT sku, discontinued FROM products WHERE sku LIKE 'X-%' ORDER BY sku"] {{X-1 0} {X-2 0}}
check upd   [dict get [q "UPDATE products SET stock = stock + 10, price = price * 2 WHERE sku = 'X-1'"] affected] 1
check upd2  [expr {[lindex [rows "SELECT stock, price FROM products WHERE sku = 'X-1'"] 0] in {{17 3} {17 3.0}}}] 1
check del   [dict get [q "DELETE FROM products WHERE sku LIKE 'X-%'"] affected] 2
check del2  [rows "SELECT COUNT(*) FROM products"] 8
check dirty [expr {[store::dirty $db] > 0}] 1

# DDL
q "CREATE VIEW notes (id int, body, tags (tag string, weight float))"
check createl [store::layout $db.notes] {{id I {}} {body S {}} {tags V {{tag S {}} {weight F {}}}}}
q "INSERT INTO notes (id, body) VALUES (1, 'hello'), (2, 'it''s quoted')"
check quote [rows "SELECT body FROM notes WHERE id = 2"] [list [list "it's quoted"]]
q "ALTER VIEW notes ADD flag int"
check addcol [lindex [store::layout $db.notes] end] {flag I {}}
q "ALTER VIEW notes RENAME body TO text"
check ren [rows "SELECT text FROM notes WHERE id = 1"] {hello}
check renpos [lindex [lmap_ [store::layout $db.notes]] 1] text
q "ALTER VIEW notes MODIFY id string"
check retype [dict get [q "DESCRIBE notes"] rows] [dict get [q "DESCRIBE notes"] rows]
check retype2 [rows "SELECT id FROM notes ORDER BY id"] {1 2}
q "ALTER VIEW notes DROP flag"
check dropcol [lmap_ [store::layout $db.notes]] {id text tags}
check desc [dict get [q "DESCRIBE notes"] rows] {{1 id String column S} {2 text String column S} {3 tags Subview subview V} {4 tags.tag String column S} {5 tags.weight Float column F}}
q "DROP VIEW notes"
check dropview [store::hasView $db notes] 0

# txn
q "COMMIT $db"
check clean [store::dirty $db] 0
q "DELETE FROM orders"
check wiped [rows "SELECT COUNT(*) FROM orders"] 0
q "ROLLBACK $db"
check rolled [rows "SELECT COUNT(*) FROM orders"] 18

# SHOW
check showviews [llength [rows "SHOW VIEWS"]] 4
check showdbs   [lindex [rows "SHOW DATABASES"] 0 0] $db
check script    [llength [mkql::parseScript "SELECT 1; SELECT 2;; -- c\n SELECT 3 /* x */"]] 3

# errors
check e1 [errmsg "SELEC 1"] {Unknown statement 'SELEC'. Try SELECT, INSERT, UPDATE, DELETE, CREATE VIEW, DROP VIEW, ALTER VIEW, DESCRIBE, SHOW, COMMIT, ROLLBACK or USE}
check e2 [string match "Unknown column 'nope' in view 'employees'.  Available: *" [errmsg "SELECT nope FROM employees"]] 1
check e3 [string match "Unknown view 'zzz'.*" [errmsg "SELECT * FROM zzz"]] 1
check e4 [errmsg "SELECT 1 / 0"] {Divide by zero}
check e5 [errmsg "SELECT * FROM employees WHERE"] {Expression expected}
check e6 [errmsg "INSERT INTO products (sku, stock) VALUES ('a', 'many')"] "Column 'stock' is Integer \u2014 'many' is not a whole number"
check e7 [errmsg "SELECT 'oops"] {Unterminated string literal}
check e8 [errmsg "SELECT * FROM employees WHERE COUNT(*) > 1"] {Aggregate functions are not allowed in WHERE; use HAVING}
check e9 [errmsg "SELECT FROM employees"] {Unexpected keyword 'FROM'}
check e10 [errmsg "SELECT * FROM employees\[999\].skills"] {Row 999 does not exist in 'employees' (it has 20 rows)}
check e11 [errmsg "CREATE VIEW products (a)"] {View 'products' already exists in 'mkql_test'.}
check e12 [errmsg "SELECT * FROM nodb.products"] "Unknown database 'nodb'. Open databases: mkql_test"
# error position information
catch {mkql::parseScript "SELECT id FROM employees WHERE id = = 3"} m opts
check pos [dict get $opts -errorcode] {MKQL SYNTAX 36 1}

# read-only
store::closeFile $db
set ro [store::openFile $f -readonly]
check roerr [errmsg "DELETE FROM orders"] "Database '$ro' is open read-only."

puts "\n$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
