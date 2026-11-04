#!/bin/sh
# Keep mkstudio.vfs/lib/mkitsql (the query engine inside the starpack) identical to a known commit of atyr647/mkit-sql.
#
#   tools/sync-mkitsql.sh /path/to/mkit-sql-checkout     copy that checkout's mkitsql/*.tcl here and record its commit in
#                                                         mkstudio.vfs/lib/mkitsql/SOURCE
#   tools/sync-mkitsql.sh --check [/path/to/checkout]    fail unless the files here are byte for byte what the commit named
#                                                         in SOURCE contains (CI runs this against a fresh clone)
#
# The engine is vendored (copied, not fetched at build time) so a release is exactly what was tested, offline and forever.
set -e
cd "$(dirname "$0")/.."
DEST=mkstudio.vfs/lib/mkitsql
if [ "$1" = "--check" ]; then
    SRC=${2:?usage: $0 --check /path/to/mkit-sql-checkout   (checked out at the commit named in $DEST/SOURCE)}
    want=$(sed -n 's/^commit //p' "$DEST/SOURCE")
    have=$(git -C "$SRC" rev-parse HEAD)
    [ "$want" = "$have" ] || { echo "checkout is at $have, SOURCE names $want"; exit 1; }
    bad=0
    for f in "$SRC"/mkitsql/*.tcl "$SRC"/mkitsql/pkgIndex.tcl; do
        b=$(basename "$f")
        cmp -s "$f" "$DEST/$b" || { echo "DIFFERS: $b"; bad=1; }
    done
    for f in "$DEST"/*.tcl; do
        [ -f "$SRC/mkitsql/$(basename "$f")" ] || { echo "EXTRA here: $(basename "$f")"; bad=1; }
    done
    [ $bad = 0 ] && echo "mkstudio.vfs/lib/mkitsql is identical to mkit-sql $want"
    exit $bad
fi
SRC=${1:?usage: $0 /path/to/mkit-sql-checkout | --check [checkout]}
[ -d "$SRC/mkitsql" ] || { echo "not a mkit-sql checkout: $SRC"; exit 1; }
git -C "$SRC" diff --quiet HEAD -- mkitsql || { echo "the checkout has uncommitted changes in mkitsql/: commit them first (the vendored copy must name a real commit)"; exit 1; }
mkdir -p "$DEST"
rm -f "$DEST"/*.tcl
cp "$SRC"/mkitsql/*.tcl "$DEST"/
ver=$(sed -n 's/^ *variable version \(.*\)$/\1/p' "$DEST/mkitsql.tcl" | head -1)
printf 'mkit-sql %s\ncommit %s\nrepository https://github.com/atyr647/mkit-sql\n' "$ver" "$(git -C "$SRC" rev-parse HEAD)" > "$DEST/SOURCE"
echo "copied mkit-sql $ver ($(git -C "$SRC" rev-parse --short HEAD)) into $DEST"
