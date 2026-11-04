#!/bin/bash
# Compile the native flush library (native/mksync/mksync.c) for one platform.
#
#   tools/build-native.sh linux   OUTDIR      -> OUTDIR/mksync-linux-x86_64.so      (CI: inside the glibc 2.28 container)
#   tools/build-native.sh windows OUTDIR      -> OUTDIR/mksync-windows-x86_64.dll   (mingw-w64 cross-build from Linux)
#   tools/build-native.sh macos   OUTDIR      -> OUTDIR/mksync-macos-<arch>.dylib   (natively, on each Mac)
#
# It needs only Tcl's HEADERS and the source of its stub-library initialiser: both come from the Tcl source archive that
# tools/seed-tcl-sources.sh downloads and checks against its pinned SHA-256 (the same archive the runtimes are built from).  The result
# is linked against the Tcl STUBS, not against a particular Tcl: one binary loads into every Tcl 8.5 / 8.6 / 9 of its platform.
# Prints the path of the finished library on its last line.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
platform=${1:?usage: build-native.sh linux|windows|macos OUTDIR}
out=${2:?usage: build-native.sh linux|windows|macos OUTDIR}
TCL_VERSION=${TCL_VERSION:-8.6.16}
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/mksync-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
TCL_ONLY=1 "$here/seed-tcl-sources.sh" "$work" "$TCL_VERSION" >&2
tar xzf "$work/tcl/src/tcl$TCL_VERSION.tar.gz" -C "$work"
src="$work/tcl$TCL_VERSION"
[ -f "$src/generic/tclStubLib.c" ] || { echo "build-native.sh: the Tcl archive has no generic/tclStubLib.c" >&2; exit 1; }
common=(-O2 -Wall -Wextra -DUSE_TCL_STUBS "-I$src/generic" "$root/native/mksync/mksync.c" "$src/generic/tclStubLib.c")
case $platform in
linux)
    lib="$out/mksync-linux-x86_64.so"
    ${CC:-gcc} "${common[@]}" -I"$src/unix" -DHAVE_UNISTD_H=1 -DHAVE_SYS_TIME_H=1 -fvisibility=hidden -shared -fPIC -o "$lib"
    strip --strip-unneeded "$lib" 2>/dev/null || true
    ;;
windows)
    lib="$out/mksync-windows-x86_64.dll"
    x86_64-w64-mingw32-gcc "${common[@]}" -I"$src/win" -shared -static-libgcc -o "$lib"
    x86_64-w64-mingw32-strip --strip-unneeded "$lib" 2>/dev/null || true
    ;;
macos)
    arch=$(uname -m)
    lib="$out/mksync-macos-$arch.dylib"
    cc "${common[@]}" -I"$src/unix" -I"$src/macosx" -DHAVE_UNISTD_H=1 -DHAVE_SYS_TIME_H=1 -fvisibility=hidden -dynamiclib -undefined dynamic_lookup -o "$lib"
    ;;
*) echo "unknown platform $platform" >&2; exit 1 ;;
esac
echo "$lib"
