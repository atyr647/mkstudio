#!/bin/sh
# Build the MK Studio starpack.
#
#   ./build.sh <tclkit-runtime> <sdx.kit> [output]
#
# <tclkit-runtime>  a tclkit WITH Tk (e.g. tclkit-8.6.x-<platform>); it must
#                   include Mk4tcl (every standard tclkit does).
# <sdx.kit>         the SDX starkit tool.
#
# Result: ./mkstudio (or the name you give) - one self-contained executable.
set -e
[ $# -ge 2 ] || { echo "usage: $0 <tclkit-runtime> <sdx.kit> [output]"; exit 1; }
RUNTIME=$1; SDX=$2; OUT=${3:-mkstudio}
cd "$(dirname "$0")"
rm -rf build && mkdir build
cp -R mkstudio.vfs build/mkstudio.vfs
cp "$RUNTIME" build/runtime && chmod +x build/runtime
( cd build && "./runtime" "$(cd .. && cd "$(dirname "$SDX")" && pwd)/$(basename "$SDX")" \
      wrap "../$OUT" -vfs mkstudio.vfs -runtime runtime )
rm -rf build
echo "built ./$OUT"
