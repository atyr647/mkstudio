# util.tcl -- small helpers shared by the tests so they run on Linux, macOS and Windows.
#
#   tmp name        a path for a scratch file inside the platform's temp directory
#   MKS_TEST_LOG    when this environment variable names a file, everything the test
#                   prints is ALSO appended there.  The Windows tclkit is a GUI-subsystem
#                   program with no console, so CI reads the log instead of stdout.
proc tmpdir {} {
    foreach v {TMPDIR TEMP TMP RUNNER_TEMP} {
        if {[info exists ::env($v)] && [file isdirectory $::env($v)]} { return $::env($v) }
    }
    return /tmp
}
proc tmp {name} { return [file join [tmpdir] $name] }

if {[info exists ::env(MKS_TEST_LOG)] && [llength [info commands ::tcl_puts]] == 0} {
    rename puts ::tcl_puts
    proc puts {args} {
        if {[llength $args] > 0 && [lindex $args 0] ne "-nonewline" && [llength $args] == 1 || \
            ([llength $args] == 2 && [lindex $args 0] eq "stdout")} {
            catch {
                set h [open $::env(MKS_TEST_LOG) a]
                tcl_puts $h [lindex $args end] ; close $h
            }
        }
        catch {tcl_puts {*}$args}
    }
}
