#!/bin/sh
# Launch a packaged starpack with a database open and make sure it keeps running.
#   tests/smoke_starpack.sh [starpack] [kit-to-make-the-sample-db]     (Linux; needs xvfb-run)
# CI runs the equivalent natively on the Windows and macOS runners.
set -e
cd "$(dirname "$0")/.."
BIN=${1:-dist/mkstudio-linux-x86_64}
KIT=${2:-tools/ext/tclkit-8.6.3-linux-x86_64}
DB=$(mktemp -u).mk
export HOME=$(mktemp -d)
"$KIT" tests/make_sample.tcl "$DB"
set +e
xvfb-run -a timeout 8 "$BIN" "$DB" 2> "$HOME/err.txt"
code=$?
set -e
if [ "$code" -ne 124 ]; then echo "FAIL: starpack exited early with code $code"; cat "$HOME/err.txt"; exit 1; fi
if [ -s "$HOME/err.txt" ]; then echo "FAIL: stderr not empty"; cat "$HOME/err.txt"; exit 1; fi
echo "starpack smoke test passed (ran 8s, no errors)"
