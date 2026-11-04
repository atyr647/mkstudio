#!/bin/bash
# Build the Mk4tcl of the Metakit fork with 64-bit file positions (https://github.com/atyr647/metakit, branch ccr-7001915e-qdjw33) as a shared
# library, in a Tcl package directory the tests can use - MK Studio is then run on THAT Metakit instead of the one inside the runtime.
#
#   tools/build-metakit-fork.sh <fork-source-dir> <output-dir>
#   TCLLIBPATH=<output-dir> tclsh8.6 tests/test_wide.tcl         (EXPECT_WIDE=1 makes the test insist that it really is the fork)
#
# Needs g++, make and the Tcl 8.6 development files (Debian/Ubuntu: apt install g++ make tcl8.6-dev).  FORK_SELFTEST=1 also runs the fork's own
# test suite (regress and twide: the wide marks, crashes after every single write).  Prints the output directory on the last line.
set -euo pipefail
src=${1:?usage: build-metakit-fork.sh <fork-source-dir> <output-dir>}
out=${2:?usage: build-metakit-fork.sh <fork-source-dir> <output-dir>}
TCLINC=${TCL_INCLUDE:-/usr/include/tcl8.6}
TCLLIB=${TCL_LIBDIR:-/usr/lib/x86_64-linux-gnu}
[ -f "$src/unix/configure" ] || { echo "build-metakit-fork.sh: $src is not a Metakit source tree" >&2; exit 1; }
src=$(cd "$src" && pwd)
mkdir -p "$out" && out=$(cd "$out" && pwd)
build="$out/build"
mkdir -p "$build" && cd "$build"
"$src/unix/configure" --with-tcl="$TCLINC,$TCLLIB" CC=g++ >configure.log 2>&1 || { tail -20 configure.log; exit 1; }
make -j4 >make.log 2>&1 || { tail -30 make.log; exit 1; }
# the Tcl binding is built against the stubs table: link it with the stubs library (one library for every Tcl 8.6)
g++ -shared -o Mk4tclS.so mk4tcl.o mk4too.o column.o custom.o derived.o fileio.o field.o format.o handler.o persist.o remap.o std.o store.o string.o table.o univ.o view.o viewx.o -lpthread "$TCLLIB/libtclstub8.6.a"
if [ "${FORK_SELFTEST:-0}" = 1 ]; then
    LD_LIBRARY_PATH="$build" make test 2>&1 | tail -15
fi
mkdir -p "$out/Mk4tcl"
printf 'package ifneeded Mk4tcl 2.4.9.7 [list load %s Mk4tcl]\n' "$build/Mk4tclS.so" > "$out/Mk4tcl/pkgIndex.tcl"
echo "built from $(git -C "$src" rev-parse HEAD 2>/dev/null || echo 'an unknown commit'): $build/Mk4tclS.so" >&2
echo "$out"
