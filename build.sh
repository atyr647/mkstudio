#!/bin/sh
# Build MK Studio starpacks.
#
#   ./build.sh            Linux x86_64        -> dist/mkstudio-linux-x86_64
#   ./build.sh all        Linux + Windows
#   ./build.sh windows    -> dist/mkstudio-windows-x86_64.exe
#
# macOS starpacks are built by CI on a Mac (.github/workflows/build.yml): there is no usable prebuilt
# macOS tclkit - the old ones crash on current macOS - so a current one is compiled with KitCreator
# there.  To do it by hand on a Mac: build a tclkit (Tcl/Tk 8.6 + Metakit, --enable-aqua=yes), then
#   tools/build-native.sh macos native-out        (the flush library; optional - without it the program starts `sync` instead)
#   KIT=/path/to/that/tclkit tclkit tools/wrap.tcl <copy of that tclkit> mkstudio.vfs dist/mkstudio-macos native-out/mksync-macos-*.dylib
#   codesign --force --sign - dist/mkstudio-macos
#
# Runtimes: the current Tcl/Tk 8.6.16 kits (CI builds them with tools/build-kit.sh and puts them in tools/ext/) are
# used when present; otherwise the 2014 prebuilt ones from tools/fetch-runtimes.sh (SHA1-verified).  Set
# MKS_REQUIRE_CURRENT=1 to refuse that fallback (CI does).  Wrapping only
# appends the application's Metakit payload to a runtime, so any platform's
# starpack can be built on any platform that has the Linux kit (or a kit that
# can run on the build machine - set KIT).
set -e
cd "$(dirname "$0")"
what=${1:-linux}
./tools/fetch-runtimes.sh $( [ "$what" = linux ] && echo linux || echo all ) >/dev/null

# runtime CURRENT-KIT FALLBACK-KIT -> the one to use
runtime() {
    if [ -f "$1" ]; then echo "$1"; return; fi
    if [ "${MKS_REQUIRE_CURRENT:-0}" = 1 ]; then echo "build.sh: the current runtime $1 is missing (tools/build-kit.sh builds it)" >&2; exit 1; fi
    echo "build.sh: WARNING: $1 not found - using the 2014 runtime $2" >&2
    echo "$2"
}
linux_rt()   { runtime tools/ext/tclkit-8.6.16-linux-x86_64 tools/ext/tclkit-8.6.3-linux-x86_64; }
windows_rt() { runtime tools/ext/tclkit-8.6.16-windows-x86_64.exe tools/ext/tclkit-8.6.3-win32-x86_64.exe; }
case $what in all|macos) ;; *) KIT=${KIT:-$(linux_rt)} ;; esac   # the kit that does the wrapping (any runnable kit)
mkdir -p dist
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

wrap() {  # runtime output native-library-pattern
    [ -f "$1" ] || { echo "build.sh: no runtime to wrap onto" >&2; exit 1; }
    cp "$1" "$TMP/runtime"            # a copy: a running tclkit mounts its own path as a vfs
    # the compiled flush library for that platform, when CI built one (tools/build-native.sh); without it the program falls back
    # to starting `sync` / PowerShell, which is slower but just as safe
    # shellcheck disable=SC2086
    "$KIT" tools/wrap.tcl "$TMP/runtime" mkstudio.vfs "$2" $(ls $3 2>/dev/null || true)
    chmod +x "$2"
}
case $what in
    linux)   wrap "$(linux_rt)"   dist/mkstudio-linux-x86_64 "tools/ext/mksync-linux-*.so" ;;
    windows) wrap "$(windows_rt)" dist/mkstudio-windows-x86_64.exe "tools/ext/mksync-windows-*.dll" ;;
    macos)   echo "macOS starpacks are built by CI on a Mac (see the comment at the top of this file)."; exit 1 ;;
    all)     "$0" linux; "$0" windows ;;
    *)       echo "usage: $0 [linux|windows|all]"; exit 1 ;;
esac
