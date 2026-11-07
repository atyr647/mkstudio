#!/bin/sh
# Keep mkstudio.vfs/lib/kitfmt (Ribbon's kit reader, behind the Kit tab) identical to a known commit of atyr647/ribbon.
#
#   tools/sync-kitfmt.sh RIBBON [COMMIT]     copy kit/kitfmt's package files (and four golden kits to tests/kits) out of COMMIT
#                                            (default HEAD) of a Ribbon clone, and record the commit and every file's hashes
#                                            in mkstudio.vfs/lib/kitfmt/SOURCE
#   tools/sync-kitfmt.sh --verify            no Ribbon needed: every vendored file has exactly the hashes SOURCE recorded,
#                                            nothing is missing or extra, and the version matches - what CI checks on every push
#   tools/sync-kitfmt.sh --check RIBBON      --verify, and the recorded hashes ARE the pinned commit's files in that clone (any
#                                            clone that has the commit; it need not be checked out at it)
#   tools/sync-kitfmt.sh --upstream RIBBON   does the clone's HEAD still carry this kitfmt?  exit 2 when it moved on (re-sync)
#   tools/sync-kitfmt.sh --compare SOURCE    do the files this pin and another one (mkit-sql's tests/vendor/kitfmt/SOURCE) both
#                                            carry agree?  exit 1 if the same commit is named with different files, 2 if the two
#                                            pins are different commits with different files
#
# Vendored (copied, not fetched at build time) like mkit-sql (tools/sync-mkitsql.sh): a release is exactly what was tested.
# Ribbon is a PRIVATE repository, so CI cannot always read it: each `file` line of SOURCE records the file's git blob id at the
# pinned commit (what `git ls-tree` and the GitHub API show for it) and its SHA-256, and --verify checks the copies against them
# without Ribbon.  The comparison with Ribbon itself (--check) runs in CI when the secret RIBBON_READ_TOKEN gives read access.
# Only the Tcl package is copied; its optional C helper (kit/kitfmt/helper) is not part of the starpack, so hashing uses
# sha256sum / shasum when present and kitfmt's pure-Tcl SHA-256 otherwise.
set -e
cd "$(dirname "$0")/.."
DEST=mkstudio.vfs/lib/kitfmt
SRCFILE=$DEST/SOURCE
FILES="kitfmt.tcl sha256.tcl pkgIndex.tcl"
KITS="app.kit app-header.kit system.kit bad-chunk.kit"     # Ribbon's golden kits, for tests/test_kit.tcl (tests/kits)
# "path in ribbon:path here" for every vendored file
PAIRS=""
for f in $FILES; do PAIRS="$PAIRS kit/kitfmt/$f:$DEST/$f"; done
for k in $KITS; do PAIRS="$PAIRS kit/kitfmt/tests/golden/$k:tests/kits/$k"; done

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
blob() { git hash-object --no-filters "$1"; }
pinned() { sed -n 's/^commit //p' "$1"; }
fileLines() { grep '^file ' "$1" || true; }

verify() {
    [ -f "$SRCFILE" ] || { echo "no $SRCFILE"; return 1; }
    bad=0 ; n=0
    while read -r _ b h rp lp; do
        [ -n "$lp" ] || continue
        n=$((n + 1))
        if [ ! -f "$lp" ]; then echo "MISSING: $lp"; bad=1; continue; fi
        [ "$(blob "$lp")" = "$b" ] || { echo "DIFFERS from the pin (git blob id): $lp"; bad=1; }
        [ "$(sha256 "$lp")" = "$h" ] || { echo "DIFFERS from the pin (SHA-256): $lp"; bad=1; }
    done <<EOF
$(fileLines "$SRCFILE")
EOF
    for p in $PAIRS; do
        grep -q "^file [0-9a-f]* [0-9a-f]* ${p%%:*} ${p#*:}\$" "$SRCFILE" || { echo "NOT RECORDED in SOURCE: ${p#*:}"; bad=1; }
    done
    for f in "$DEST"/*.tcl; do
        case " $FILES " in *" $(basename "$f") "*) ;; *) echo "EXTRA here: $f"; bad=1;; esac
    done
    ver=$(sed -n 's/^ *variable version \(.*\)$/\1/p' "$DEST/kitfmt.tcl" | head -1)
    [ "$(sed -n '1s/^kitfmt //p' "$SRCFILE")" = "$ver" ] || { echo "SOURCE names another version than kitfmt.tcl ($ver)"; bad=1; }
    grep -q "kitfmt $ver " "$DEST/pkgIndex.tcl" || { echo "pkgIndex.tcl does not provide kitfmt $ver"; bad=1; }
    [ -n "$(pinned "$SRCFILE")" ] || { echo "SOURCE names no commit"; bad=1; }
    [ $bad = 0 ] && echo "mkstudio.vfs/lib/kitfmt and tests/kits: $n files, all as pinned (kitfmt $ver, ribbon $(pinned "$SRCFILE"))"
    return $bad
}

case "$1" in
--verify)
    verify; exit $?
    ;;
--check)
    SRC=${2:?usage: $0 --check /path/to/ribbon-clone}
    verify || exit 1
    want=$(pinned "$SRCFILE")
    git -C "$SRC" cat-file -e "$want^{commit}" 2>/dev/null || { echo "the clone $SRC does not have commit $want (a shallow clone? fetch it)"; exit 1; }
    bad=0
    while read -r _ b h rp lp; do
        [ -n "$lp" ] || continue
        have=$(git -C "$SRC" rev-parse -q --verify "$want:$rp" 2>/dev/null || echo none)
        [ "$have" = "$b" ] || { echo "DIFFERS from ribbon $want: $lp (ribbon $rp: $have, recorded $b)"; bad=1; }
    done <<EOF
$(fileLines "$SRCFILE")
EOF
    for f in $(git -C "$SRC" ls-tree --name-only "$want" kit/kitfmt/ | sed -n 's|^kit/kitfmt/\(.*\.tcl\)$|\1|p'); do
        case " $FILES " in *" $f "*) ;; *) echo "NOT COPIED: ribbon $want has kit/kitfmt/$f (add it to FILES)"; bad=1;; esac
    done
    [ $bad = 0 ] && echo "and they are byte for byte ribbon $want"
    exit $bad
    ;;
--upstream)
    SRC=${2:?usage: $0 --upstream /path/to/ribbon-clone}
    head=$(git -C "$SRC" rev-parse HEAD)
    moved=""
    while read -r _ b h rp lp; do
        [ -n "$lp" ] || continue
        have=$(git -C "$SRC" rev-parse -q --verify "HEAD:$rp" 2>/dev/null || echo gone)
        [ "$have" = "$b" ] || moved="$moved $rp"
    done <<EOF
$(fileLines "$SRCFILE")
EOF
    if [ -n "$moved" ]; then
        echo "ribbon $head has a newer kitfmt than the pin ($(pinned "$SRCFILE")):$moved"
        echo "re-sync with: tools/sync-kitfmt.sh /path/to/ribbon"
        exit 2
    fi
    echo "ribbon $head carries the pinned kitfmt unchanged"
    exit 0
    ;;
--compare)
    OTHER=${2:?usage: $0 --compare /path/to/other/SOURCE}
    [ -f "$OTHER" ] || { echo "no $OTHER"; exit 1; }
    mine=$(pinned "$SRCFILE") ; theirs=$(pinned "$OTHER")
    differ="" ; common=0
    while read -r _ b h rp lp; do
        [ -n "$rp" ] || continue
        ob=$(fileLines "$OTHER" | awk -v p="$rp" '$4 == p { print $2 }')
        [ -n "$ob" ] || continue
        common=$((common + 1))
        [ "$ob" = "$b" ] || differ="$differ $rp"
    done <<EOF
$(fileLines "$SRCFILE")
EOF
    [ $common -gt 0 ] || { echo "$OTHER records no file this pin has (an older SOURCE without hashes): cannot compare"; exit 2; }
    if [ -z "$differ" ]; then echo "the same kitfmt in both pins ($common common files; ribbon $mine and $theirs)"; exit 0; fi
    echo "the pins carry different files:$differ (here ribbon $mine, $OTHER ribbon $theirs)"
    [ "$mine" = "$theirs" ] && { echo "both name the same commit: one of the copies is not that commit's"; exit 1; }
    exit 2
    ;;
-*)
    echo "usage: $0 RIBBON [COMMIT] | --verify | --check RIBBON | --upstream RIBBON | --compare SOURCE"; exit 1
    ;;
esac

SRC=${1:?usage: $0 /path/to/ribbon-clone [commit] | --verify | --check RIBBON | --upstream RIBBON | --compare SOURCE}
[ -d "$SRC/kit/kitfmt" ] || { echo "not a ribbon checkout: $SRC"; exit 1; }
commit=$(git -C "$SRC" rev-parse --verify "${2:-HEAD}^{commit}")
git -C "$SRC" cat-file -e "$commit:kit/kitfmt/kitfmt.tcl" || { echo "ribbon $commit has no kit/kitfmt/kitfmt.tcl"; exit 1; }
[ -n "$2" ] || git -C "$SRC" diff --quiet HEAD -- kit/kitfmt || echo "note: uncommitted changes in $SRC/kit/kitfmt are NOT copied (only what commit $commit has)"
mkdir -p "$DEST" tests/kits
rm -f "$DEST"/*.tcl
ver=$(git -C "$SRC" show "$commit:kit/kitfmt/kitfmt.tcl" | sed -n 's/^ *variable version \(.*\)$/\1/p' | head -1)
{
    printf 'kitfmt %s\ncommit %s\nrepository https://github.com/atyr647/ribbon (kit/kitfmt)\n' "$ver" "$commit"
    echo "# file <git blob id at that commit> <SHA-256> <path in ribbon> <path here>   (tools/sync-kitfmt.sh --verify checks them)"
    for p in $PAIRS; do
        git -C "$SRC" show "$commit:${p%%:*}" > "${p#*:}"            # the committed bytes, no checkout filters
        echo "file $(blob "${p#*:}") $(sha256 "${p#*:}") ${p%%:*} ${p#*:}"
    done
} > "$SRCFILE.tmp"
mv "$SRCFILE.tmp" "$SRCFILE"
echo "copied kitfmt $ver ($(git -C "$SRC" rev-parse --short "$commit")) into $DEST"
verify
