#!/bin/sh
# Keep mkstudio.vfs/lib/kitfmt (Ribbon's kit reader, behind the Kit tab) identical to a known commit of atyr647/ribbon.
#
#   tools/sync-kitfmt.sh /path/to/ribbon-checkout      copy its kit/kitfmt package files here (and four golden kits to
#                                                       tests/kits) and record the commit in mkstudio.vfs/lib/kitfmt/SOURCE
#   tools/sync-kitfmt.sh --check /path/to/checkout     fail unless the files here are byte for byte what that commit has
#
# Vendored (copied, not fetched at build time) like mkit-sql (tools/sync-mkitsql.sh): a release is exactly what was tested.
# Only the Tcl package is copied; its optional C helper (kit/kitfmt/helper) is not part of the starpack, so hashing uses
# sha256sum / shasum when present and kitfmt's pure-Tcl SHA-256 otherwise.
set -e
cd "$(dirname "$0")/.."
DEST=mkstudio.vfs/lib/kitfmt
FILES="kitfmt.tcl sha256.tcl pkgIndex.tcl"
KITS="app.kit app-header.kit system.kit bad-chunk.kit"     # Ribbon's golden kits, for tests/test_kit.tcl (tests/kits)
if [ "$1" = "--check" ]; then
    SRC=${2:?usage: $0 --check /path/to/ribbon-checkout   (checked out at the commit named in $DEST/SOURCE)}
    want=$(sed -n 's/^commit //p' "$DEST/SOURCE")
    have=$(git -C "$SRC" rev-parse HEAD)
    [ "$want" = "$have" ] || { echo "checkout is at $have, SOURCE names $want"; exit 1; }
    bad=0
    for f in $FILES; do cmp -s "$SRC/kit/kitfmt/$f" "$DEST/$f" || { echo "DIFFERS: $f"; bad=1; }; done
    for k in $KITS; do cmp -s "$SRC/kit/kitfmt/tests/golden/$k" "tests/kits/$k" || { echo "DIFFERS: tests/kits/$k"; bad=1; }; done
    for f in "$DEST"/*.tcl; do
        case " $FILES " in *" $(basename "$f") "*) ;; *) echo "EXTRA here: $(basename "$f")"; bad=1;; esac
    done
    [ $bad = 0 ] && echo "mkstudio.vfs/lib/kitfmt is identical to ribbon $want"
    exit $bad
fi
SRC=${1:?usage: $0 /path/to/ribbon-checkout | --check [checkout]}
[ -f "$SRC/kit/kitfmt/kitfmt.tcl" ] || { echo "not a ribbon checkout: $SRC"; exit 1; }
git -C "$SRC" diff --quiet HEAD -- kit/kitfmt || { echo "the checkout has uncommitted changes in kit/kitfmt: commit them first"; exit 1; }
mkdir -p "$DEST"
rm -f "$DEST"/*.tcl
for f in $FILES; do cp "$SRC/kit/kitfmt/$f" "$DEST/$f"; done
mkdir -p tests/kits
for k in $KITS; do cp "$SRC/kit/kitfmt/tests/golden/$k" "tests/kits/$k"; done
ver=$(sed -n 's/^ *variable version \(.*\)$/\1/p' "$DEST/kitfmt.tcl" | head -1)
printf 'kitfmt %s\ncommit %s\nrepository https://github.com/atyr647/ribbon (kit/kitfmt)\n' "$ver" "$(git -C "$SRC" rev-parse HEAD)" > "$DEST/SOURCE"
echo "copied kitfmt $ver ($(git -C "$SRC" rev-parse --short HEAD)) into $DEST"
