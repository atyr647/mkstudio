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
    variable types {
        S {String  string}  I {Integer int}  L {Long long}
        F {Float   float}   D {Double  double}  B {Bytes bytes}
        V {Subview subview}
    }
    array set file {} ; array set ro {} ; array set dirty {}
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

proc ::store::tags {} { variable tags ; return $tags }
proc ::store::exists {tag} { variable tags ; expr {[lsearch -exact $tags $tag] >= 0} }
proc ::store::path {tag}     { variable file ; return $file($tag) }
proc ::store::readonly {tag} { variable ro   ; return $ro($tag) }
proc ::store::dirty {tag}    { variable dirty; return $dirty($tag) }
proc ::store::touch {tag}    { variable dirty; incr dirty($tag) }

proc ::store::fileSize {tag} {
    if {[catch {file size [path $tag]} n]} { return 0 }
    return $n
}

# Open (or, when -create is given, create) a Metakit datafile.  Returns the tag.
# Files are always opened with -nocommit so nothing is written until the user
# commits -- closing a file never silently saves.
proc ::store::openFile {path args} {
    variable tags ; variable file ; variable ro ; variable dirty
    set create 0 ; set readonly 0
    foreach a $args {
        switch -- $a { -create {set create 1} -readonly {set readonly 1} }
    }
    set path [file normalize $path]
    foreach t $tags {
        if {$file($t) eq $path} { error "File is already open as '$t'." }
    }
    if {!$create && ![file exists $path]} { error "File not found: $path" }
    set tag [makeTag $path]
    set opts {-nocommit}
    if {$readonly} { lappend opts -readonly }
    if {[catch {mk::file open $tag $path {*}$opts}]} {
        # very old Mk4tcl without -nocommit: fall back to the plain open
        mk::file open $tag $path {*}[expr {$readonly ? {-readonly} : {}}]
    }
    lappend tags $tag
    set file($tag) $path ; set ro($tag) $readonly ; set dirty($tag) 0
    return $tag
}

proc ::store::closeFile {tag} {
    variable tags ; variable file ; variable ro ; variable dirty
    catch {mk::file close $tag}
    set i [lsearch -exact $tags $tag]
    if {$i >= 0} { set tags [lreplace $tags $i $i] }
    unset -nocomplain file($tag) ro($tag) dirty($tag)
}

proc ::store::commit {tag} {
    variable dirty
    mk::file commit $tag
    set dirty($tag) 0
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
}

# -- reading structure -------------------------------------------------------
proc ::store::views {tag} { lsort -dictionary [mk::file views $tag] }

proc ::store::hasView {tag name} {
    expr {[lsearch -exact [mk::file views $tag] $name] >= 0}
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

proc ::store::layout {path} { parseLayout [mk::view layout $path] }
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

# Delete rows by index. Deleting from the highest index down keeps the rest valid.
proc ::store::deleteRows {path indices} {
    foreach i [lsort -integer -decreasing -unique $indices] {
        mk::row delete $path!$i
    }
    touchPath $path
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
# The rebuilt column ends up last in the layout.
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
    restructure $path [concat $base [list $N]]
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

