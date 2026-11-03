#!/bin/sh
# Build the MK Studio starpack:   ./build.sh [output]      (default: dist/mkstudio-linux-x86_64)
# Uses the tclkit in tools/ both to run the wrapper and as the runtime, so no
# sdx.kit is needed.  To target another platform, set RUNTIME to that platform's
# tclkit (it must include Tk and Mk4tcl) and run this script with a tclkit that
# can execute on the build machine (KIT).
set -e
cd "$(dirname "$0")"
KIT=${KIT:-tools/tclkit-8.6.3-linux-x86_64}
RUNTIME=${RUNTIME:-$KIT}
OUT=${1:-dist/mkstudio-linux-x86_64}
mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp -d)
cp "$RUNTIME" "$TMP/runtime"      # a copy: a running tclkit mounts its own path as a vfs
"$KIT" tools/wrap.tcl "$TMP/runtime" mkstudio.vfs "$OUT"
chmod +x "$OUT"
rm -rf "$TMP"
