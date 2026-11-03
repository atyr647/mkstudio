#!/bin/sh
# Launch the packaged Linux starpack headless, opening a database, and make sure
# it is still running (no crash, no Tcl error on stderr) after a few seconds.
#   tests/smoke_starpack.sh [dist/mkstudio-linux-x86_64]
set -e
cd "$(dirname "$0")/.."
BIN=${1:-dist/mkstudio-linux-x86_64}
KIT=${KIT:-tools/ext/tclkit-8.6.3-linux-x86_64}
DB=$(mktemp -u).mk
export HOME=$(mktemp -d)
cat > "$HOME/mk.tcl" <<EOT
package require Mk4tcl
foreach f {store} { source mkstudio.vfs/lib/app-mkstudio/\$f.tcl }
store::createSample $DB
exit
EOT
"$KIT" "$HOME/mk.tcl"
set +e
xvfb-run -a timeout 8 "$BIN" "$DB" 2> "$HOME/err.txt"
code=$?
set -e
if [ "$code" -ne 124 ]; then echo "FAIL: starpack exited early with code $code"; cat "$HOME/err.txt"; exit 1; fi
if [ -s "$HOME/err.txt" ]; then echo "FAIL: stderr not empty"; cat "$HOME/err.txt"; exit 1; fi
echo "starpack smoke test passed (ran 8s, no errors)"
