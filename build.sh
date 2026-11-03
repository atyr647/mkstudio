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
#   KIT=/path/to/that/tclkit tclkit tools/wrap.tcl <copy of that tclkit> mkstudio.vfs dist/mkstudio-macos
#   codesign --force --sign - dist/mkstudio-macos
#
# Runtimes come from tools/fetch-runtimes.sh (SHA1-verified).  Wrapping only
# appends the application's Metakit payload to a runtime, so any platform's
# starpack can be built on any platform that has the Linux kit (or a kit that
# can run on the build machine - set KIT).
set -e
cd "$(dirname "$0")"
what=${1:-linux}
./tools/fetch-runtimes.sh $( [ "$what" = linux ] && echo linux || echo all ) >/dev/null
KIT=${KIT:-tools/ext/tclkit-8.6.3-linux-x86_64}
mkdir -p dist
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

wrap() {  # runtime output
    cp "$1" "$TMP/runtime"            # a copy: a running tclkit mounts its own path as a vfs
    "$KIT" tools/wrap.tcl "$TMP/runtime" mkstudio.vfs "$2"
    chmod +x "$2"
}
case $what in
    linux)   wrap tools/ext/tclkit-8.6.3-linux-x86_64     dist/mkstudio-linux-x86_64 ;;
    windows) wrap tools/ext/tclkit-8.6.3-win32-x86_64.exe dist/mkstudio-windows-x86_64.exe ;;
    macos)   echo "macOS starpacks are built by CI on a Mac (see the comment at the top of this file)."; exit 1 ;;
    all)     "$0" linux; "$0" windows ;;
    *)       echo "usage: $0 [linux|windows|all]"; exit 1 ;;
esac
