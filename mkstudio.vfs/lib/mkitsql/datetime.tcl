# datetime.tcl -- DATE / TIME / TIMESTAMP and INTERVAL support for mkit-sql.
#
# Metakit has no date type: dates are stored as ISO-8601 text ("2026-03-05",
# "2026-03-05 14:30:00", "14:30:00") and compare correctly as text.
#
# An INTERVAL value exists only while a query runs.  Internally it is the string
#     U+FDD0 "ivl:" <months> ":" <seconds>      (U+FDD0 never occurs in data - see expr.tcl - so no text is ever mistaken for an interval)
# (months and seconds are kept apart because a month has no fixed length).  It is shown
# as  "1 year 2 mons 3 days 04:05:06"  and cannot be stored in a column.

namespace eval ::mkitsql {
    variable ivUnitSecs {second 1 minute 60 hour 3600 day 86400 week 604800}
}

# Seconds are kept to the microsecond (as PostgreSQL does): float noise from dividing or scaling must not make two equal intervals different
# strings (equality, GROUP BY, DISTINCT and joins see the string) or print as 59.9999999.
proc ::mkitsql::ivMake {m s} {
    set m [expr {entier($m)}]
    if {![string is integer -strict $s]} { set s [expr {round($s * 1e6) / 1e6}] }
    if {$s == entier($s) && abs($s) < 1e15} { set s [expr {entier($s)}] } else { set s [expr {double($s)}] }
    return $::mkitsql::IV$m:$s
}
# A string that sorts (as text) in the order of the intervals' length of time with 30-day months, equal lengths by months: equal intervals are
# adjacent however the sort is run (in memory, or in runs merged from files), which a bare total would not give.
proc ::mkitsql::ivSortKey {v} {
    if {![isIv $v]} { return $v }                          ;# already converted (a spilled run is sorted again)
    lassign [ivSplit $v] m s
    # (padded by hand: `format %d` of a number beyond a machine word is not exact on every Tcl - Tcl 9, 64-bit Windows Tcl 8)
    set a [expr {$m * 2592000000000 + round($s * 1000000) + 1000000000000000000000000000000}]
    set b [expr {$m + 1000000000000000000}]
    return [string repeat 0 [expr {31 - [string length $a]}]]$a[string repeat 0 [expr {19 - [string length $b]}]]$b
}
proc ::mkitsql::ivSplit {v} {
    if {![::mkitsql::isIv $v] || ![regexp {^.....(-?\d+):(-?[0-9.eE+-]+)$} $v -> m s]} {
        fail "'[string range $v 0 40]' is not an interval"
    }
    return [list $m $s]
}
# seconds with 30-day months: the convention used to compare and sort intervals
proc ::mkitsql::ivTotal {v} {
    # already converted (sorting converts a key once; a spilled run may be sorted again)
    if {![isIv $v] && [string is double -strict $v]} { return $v }
    lassign [ivSplit $v] m s
    expr {$m * 2592000.0 + $s}
}

# Human-readable form:  1 year 2 mons 3 days 04:05:06
proc ::mkitsql::ivFormat {v} {
    lassign [ivSplit $v] m s
    set parts {}
    set y [expr {$m / 12}] ; set mo [expr {$m % 12}]
    if {$m < 0 && $mo != 0} { set mo [expr {$mo - 12}] ; incr y }       ;# truncate toward zero
    if {$y} { lappend parts "$y year[expr {abs($y) == 1 ? {} : {s}}]" }
    if {$mo} { lappend parts "$mo mon[expr {abs($mo) == 1 ? {} : {s}}]" }
    set neg [expr {$s < 0}]
    set a [expr {abs($s)}]
    set d [expr {entier($a / 86400)}]
    set rem [expr {$a - $d * 86400}]
    if {$d} { lappend parts "[expr {$neg ? -$d : $d}] day[expr {$d == 1 ? {} : {s}}]" }
    if {$rem > 0 || ![llength $parts]} {
        set hh [expr {entier($rem / 3600)}] ; set mi [expr {entier(($rem - $hh * 3600) / 60)}]
        set ss [expr {$rem - $hh * 3600 - $mi * 60}]
        if {$ss == entier($ss)} { set sss [format %02d [expr {entier($ss)}]] } else { set sss [format %09.6f $ss] ; set sss [string trimright $sss 0] }
        lappend parts "[expr {$neg ? {-} : {}}][format %02d $hh]:[format %02d $mi]:$sss"
    }
    return [join $parts " "]
}

# Parse the text of an interval literal.  `from`/`to` are the optional SQL qualifier
# (YEAR TO MONTH, DAY TO SECOND ...); without one, PostgreSQL-style text is accepted
# ('3 days', '1 year 2 months', '-5 hours', '1 day 02:30:00').  Returns {months seconds}.
proc ::mkitsql::ivParse {str from to} {
    variable ivUnitSecs
    set str [string trim $str]
    # leading zeros are decimal here ('08' DAY is 8 days), never octal
    regsub -all {(^|[^0-9.])0+(?=[0-9])} $str {\1} str
    set from [string tolower $from] ; set to [string tolower $to]
    set bad "Invalid interval '$str'"
    if {$from ne ""} {
        set sign 1
        if {[regexp {^([-+])(.*)$} $str -> sg rest]} { set str [string trim $rest] ; if {$sg eq "-"} { set sign -1 } }
        if {$to eq ""} {
            if {![regexp {^\d+(\.\d+)?$} $str]} { fail "$bad: expected a number of ${from}s" }
            if {$from eq "year"} { return [list [expr {$sign * entier($str * 12)}] 0] }
            if {$from eq "month"} { return [list [expr {$sign * entier($str)}] 0] }
            return [list 0 [expr {$sign * $str * [dict get $ivUnitSecs $from]}]]
        }
        if {$from eq "year" && $to eq "month"} {
            if {![regexp {^(\d+)-(\d+)$} $str -> y mo]} { fail "$bad: expected YEAR-MONTH, for example '1-2'" }
            return [list [expr {$sign * ([scan $y %d] * 12 + [scan $mo %d])}] 0]
        }
        set d 0 ; set h 0 ; set mi 0 ; set sec 0
        switch -- "$from $to" {
            "day hour"    { if {![regexp {^(\d+)\s+(\d+)$} $str -> d h]} { fail "$bad: expected 'D H'" } }
            "day minute"  { if {![regexp {^(\d+)\s+(\d+):(\d+)$} $str -> d h mi]} { fail "$bad: expected 'D H:M'" } }
            "day second"  { if {![regexp {^(\d+)\s+(\d+):(\d+):(\d+(?:\.\d+)?)$} $str -> d h mi sec]} { fail "$bad: expected 'D H:M:S'" } }
            "hour minute" { if {![regexp {^(\d+):(\d+)$} $str -> h mi]} { fail "$bad: expected 'H:M'" } }
            "hour second" { if {![regexp {^(\d+):(\d+):(\d+(?:\.\d+)?)$} $str -> h mi sec]} { fail "$bad: expected 'H:M:S'" } }
            "minute second" { if {![regexp {^(\d+):(\d+(?:\.\d+)?)$} $str -> mi sec]} { fail "$bad: expected 'M:S'" } }
            default { fail "Unsupported interval qualifier [string toupper $from] TO [string toupper $to]" }
        }
        foreach v {d h mi} { set $v [scan [set $v] %d] }
        return [list 0 [expr {$sign * ($d * 86400 + $h * 3600 + $mi * 60 + $sec)}]]
    }
    # PostgreSQL style
    set m 0 ; set s 0 ; set any 0
    set rest $str
    while {$rest ne ""} {
        if {[regexp {^\s*([-+]?\d+):(\d+)(?::(\d+(?:\.\d+)?))?(.*)$} $rest -> hh mi ss rest2]} {
            set sg [expr {[string index $hh 0] eq "-" ? -1 : 1}]
            set hh [expr {abs([scan [string trimleft $hh +-] %d])}]
            if {$ss eq ""} { set ss 0 }
            set s [expr {$s + $sg * ($hh * 3600 + [scan $mi %d] * 60 + $ss)}]
            set rest $rest2 ; set any 1 ; continue
        }
        if {[regexp -nocase {^\s*([-+]?\d+(?:\.\d+)?)\s*([a-z]+)(.*)$} $rest -> n u rest2]} {
            switch -glob -- [string tolower $u] {
                y - yr - yrs - year - years { set m [expr {$m + entier($n * 12)}] }
                mon - mons - month - months { set m [expr {$m + entier($n)}] }
                w - week - weeks { set s [expr {$s + $n * 604800}] }
                d - day - days { set s [expr {$s + $n * 86400}] }
                h - hr - hrs - hour - hours { set s [expr {$s + $n * 3600}] }
                min - mins - minute - minutes { set s [expr {$s + $n * 60}] }
                sec - secs - second - seconds { set s [expr {$s + $n}] }
                default { fail "$bad: unknown unit '$u'" }
            }
            set rest $rest2 ; set any 1 ; continue
        }
        fail $bad
    }
    if {!$any} { fail $bad }
    return [list $m $s]
}

# ---- dates -----------------------------------------------------------------
# Parse "YYYY-MM-DD", "YYYY-MM-DD HH:MM:SS[.fff]" or "HH:MM:SS" -> dict
proc ::mkitsql::dtParse {v} {
    if {[regexp {^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?\s*$} $v -> y m d hh mi ss]} {
        set kind [expr {$hh eq "" ? "date" : "timestamp"}]
        if {$hh eq ""} { set hh 0 ; set mi 0 } 
        if {$ss eq ""} { set ss 0 }
        set y [scan $y %d] ; set m [scan $m %d] ; set d [scan $d %d] ; set hh [scan $hh %d] ; set mi [scan $mi %d]
        dtCheck $kind $v $y $m $d $hh $mi $ss
        return [dict create kind $kind y $y m $m d $d hh $hh mi $mi ss [normNum $ss]]
    }
    if {[regexp {^\s*(\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*$} $v -> hh mi ss]} {
        if {$ss eq ""} { set ss 0 }
        set hh [scan $hh %d] ; set mi [scan $mi %d]
        dtCheck time $v 1970 1 1 $hh $mi $ss
        return [dict create kind time y 1970 m 1 d 1 hh $hh mi $mi ss [normNum $ss]]
    }
    fail "'[string range $v 0 40]' is not a date or time (expected YYYY-MM-DD, YYYY-MM-DD HH:MM:SS or HH:MM:SS)"
}
# A calendar date / clock time must exist: month 1-12, a day the month has, hour 0-23, minute and second
# 0-59, year 1-9999.  `what` is date, timestamp or time.
proc ::mkitsql::dtCheck {what v y m d hh mi ss} {
    set bad ""
    if {$what ne "time"} {
        if {$y < 1 || $y > 9999} { set bad "the year must be 0001 to 9999" } \
        elseif {$m < 1 || $m > 12} { set bad "there is no month $m" } \
        elseif {$d < 1 || $d > [daysInMonth $y $m]} { set bad "[format %04d-%02d $y $m] has no day $d" }
    }
    if {$bad eq "" && $what ne "date"} {
        if {$hh < 0 || $hh > 23} { set bad "the hour must be 0 to 23" } \
        elseif {$mi < 0 || $mi > 59} { set bad "the minute must be 0 to 59" } \
        elseif {$ss < 0 || $ss >= 60} { set bad "the second must be 0 to 59" }
    }
    if {$bad ne ""} { fail "Invalid $what '[string range $v 0 40]': $bad" }
}
proc ::mkitsql::daysInMonth {y m} {
    switch -- $m { 4 - 6 - 9 - 11 { return 30 } 2 { return [expr {($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0)) ? 29 : 28}] } }
    return 31
}
# Days since 1970-01-01 for a calendar date (proleptic Gregorian).  Plain integer arithmetic:
# nothing here depends on [clock], so results are identical on every Tcl version.
proc ::mkitsql::daysFromCivil {y m d} {
    if {$m <= 2} { incr y -1 }
    set era [expr {$y / 400}]                      ;# integer division floors, as needed for y < 0
    set yoe [expr {$y - $era * 400}]
    set doy [expr {(153 * ($m + ($m > 2 ? -3 : 9)) + 2) / 5 + $d - 1}]
    set doe [expr {$yoe * 365 + $yoe / 4 - $yoe / 100 + $doy}]
    return [expr {$era * 146097 + $doe - 719468}]
}
# {y m d} for a day count
proc ::mkitsql::civilFromDays {z} {
    incr z 719468
    set era [expr {$z / 146097}]
    set doe [expr {$z - $era * 146097}]
    set yoe [expr {($doe - $doe / 1460 + $doe / 36524 - $doe / 146096) / 365}]
    set y [expr {$yoe + $era * 400}]
    set doy [expr {$doe - (365 * $yoe + $yoe / 4 - $yoe / 100)}]
    set mp [expr {(5 * $doy + 2) / 153}]
    set d [expr {$doy - (153 * $mp + 2) / 5 + 1}]
    set m [expr {$mp + ($mp < 10 ? 3 : -9)}]
    if {$m <= 2} { incr y }
    return [list $y $m $d]
}
proc ::mkitsql::dtEpoch {p} {
    dict with p {}
    if {$m < 1 || $m > 12 || $d < 1 || $d > [daysInMonth $y $m]} { fail "Invalid date [format %04d-%02d-%02d $y $m $d]" }
    return [expr {[daysFromCivil $y $m $d] * 86400 + $hh * 3600 + $mi * 60 + $ss}]
}
# value + (months, seconds); month arithmetic clamps to the end of the month (Jan 31 + 1 month = Feb 28)
proc ::mkitsql::dtAdd {v months secs} {
    set p [dtParse $v]
    set kind [dict get $p kind]
    if {$kind eq "time"} {
        if {$months} { fail "A month interval cannot be added to a TIME" }
        set t [expr {(([dict get $p hh] * 3600 + [dict get $p mi] * 60 + [dict get $p ss]) + $secs)}]
        set t [expr {$t - floor($t / 86400.0) * 86400}]
        return [fmtSecs $t]
    }
    if {$months} {
        set tot [expr {[dict get $p y] * 12 + [dict get $p m] - 1 + $months}]
        set y [expr {entier(floor($tot / 12.0))}] ; set m [expr {$tot - $y * 12 + 1}]
        set d [dict get $p d]
        set dm [daysInMonth $y $m]
        if {$d > $dm} { set d $dm }
        dict set p y $y ; dict set p m $m ; dict set p d $d
    }
    set e [expr {[dtEpoch $p] + $secs}]
    set whole [expr {$kind eq "date" && $secs == entier($secs) && entier($secs) % 86400 == 0}]
    set ef [expr {entier(floor($e))}]
    set days [expr {$ef / 86400}] ; set rem [expr {$ef - $days * 86400}]
    lassign [civilFromDays $days] y m d
    if {$y < 1 || $y > 9999} { fail "The date is out of range (years 0001 to 9999)" }
    set out [format %04d-%02d-%02d $y $m $d]
    if {!$whole} {
        append out [format " %02d:%02d:%02d" [expr {$rem / 3600}] [expr {$rem % 3600 / 60}] [expr {$rem % 60}]]
        set frac [expr {$e - floor($e)}]
        if {$frac > 0} { append out [string trimleft [format %.6f $frac] 0] }
    }
    return $out
}
proc ::mkitsql::fmtSecs {t} {
    set h [expr {entier($t / 3600)}] ; set mi [expr {entier(($t - $h * 3600) / 60)}] ; set s [expr {$t - $h * 3600 - $mi * 60}]
    if {$s == entier($s)} { return [format %02d:%02d:%02d $h $mi [expr {entier($s)}]] }
    return [format %02d:%02d:%09.6f $h $mi $s]
}

# ---- runtime procs ------------------------------------------------------------
::mkitsql::defstrict iv_add {a b} { lassign [::mkitsql::ivSplit $a] m1 s1 ; lassign [::mkitsql::ivSplit $b] m2 s2 ; ::mkitsql::ivMake [expr {$m1 + $m2}] [expr {$s1 + $s2}] }
::mkitsql::defstrict iv_sub {a b} { lassign [::mkitsql::ivSplit $a] m1 s1 ; lassign [::mkitsql::ivSplit $b] m2 s2 ; ::mkitsql::ivMake [expr {$m1 - $m2}] [expr {$s1 - $s2}] }
::mkitsql::defstrict iv_neg {a} { lassign [::mkitsql::ivSplit $a] m s ; ::mkitsql::ivMake [expr {-$m}] [expr {-$s}] }
# scale an interval by a factor: whole months stay months, the fractional month becomes days of 30 days (as PostgreSQL does)
proc ::mkitsql::ivScale {a f} {
    lassign [ivSplit $a] m s
    set mm [expr {$m * double($f)}]
    set whole [expr {$mm < 0 ? -entier(-$mm) : entier($mm)}]
    set frac [expr {$mm - $whole}]
    if {abs($frac) < 1e-9} { set frac 0 }
    return [ivMake $whole [expr {$s * double($f) + $frac * 2592000}]]
}
::mkitsql::defstrict iv_mul {a n} { ::mkitsql::ivScale $a $n }
::mkitsql::defstrict iv_div {a n} {
    if {$n == 0} { ::mkitsql::fail "Division by zero" }
    ::mkitsql::ivScale $a [expr {1.0 / $n}]
}
::mkitsql::defstrict iv_fmt {a} { ::mkitsql::ivFormat $a }
::mkitsql::defstrict dt_add_iv {d iv} { lassign [::mkitsql::ivSplit $iv] m s ; ::mkitsql::dtAdd $d $m $s }
::mkitsql::defstrict dt_sub_iv {d iv} { lassign [::mkitsql::ivSplit $iv] m s ; ::mkitsql::dtAdd $d [expr {-$m}] [expr {-$s}] }
::mkitsql::defstrict dt_sub {a b} {
    set pa [::mkitsql::dtParse $a] ; set pb [::mkitsql::dtParse $b]
    ::mkitsql::ivMake 0 [expr {[::mkitsql::dtEpoch $pa] - [::mkitsql::dtEpoch $pb]}]
}
::mkitsql::defstrict cast_interval {v} {
    if {[::mkitsql::isIv $v]} { return $v }
    lassign [::mkitsql::ivParse $v "" ""] m s
    ::mkitsql::ivMake $m $s
}
# equality is exact (months and seconds both equal), so it agrees with GROUP BY, DISTINCT, joins and IN, which see the same two parts;
# ordering compares the length of time with 30-day months
foreach {nm op} {eq eq ne ne} {
    ::mkitsql::defstrict ${nm}_i {a b} "expr {\[::mkitsql::ivSplit \$a\] $op \[::mkitsql::ivSplit \$b\]}"
}
foreach {nm op} {lt < le <= gt > ge >=} {
    ::mkitsql::defstrict ${nm}_i {a b} "expr {\[::mkitsql::ivTotal \$a\] $op \[::mkitsql::ivTotal \$b\]}"
}

# EXTRACT(field FROM interval)
proc ::mkitsql::ivExtract {field v} {
    lassign [ivSplit $v] m s
    switch -- $field {
        YEAR   { return [expr {entier($m / 12)}] }
        MONTH  { return [expr {entier($m - entier($m / 12) * 12)}] }
        DAY    { return [expr {entier($s / 86400)}] }
        HOUR   { return [expr {entier(($s - entier($s / 86400) * 86400) / 3600)}] }
        MINUTE { return [expr {entier(($s - entier($s / 3600) * 3600) / 60)}] }
        SECOND { set r [expr {$s - entier($s / 60) * 60}] ; if {$r == entier($r)} { return [expr {entier($r)}] } ; return $r }
        EPOCH  { return [ivTotal $v] }
    }
    fail "Unknown EXTRACT field '$field' for an interval"
}

# Is `v` an INTERVAL value?  Intervals carry the prefix  U+FDD0 "ivl:" ; no data can start with it.
proc ::mkitsql::isIv {v} { string equal -length 5 $v $::mkitsql::IV }
