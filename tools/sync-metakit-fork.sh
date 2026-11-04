#!/bin/bash
# Keep an exact copy of the Metakit fork with 64-bit file positions (https://github.com/atyr647/metakit) in tools/vendor/, the Metakit that is
# compiled into every runtime (tools/build-kit.sh).  Nothing is fetched at build time.
#
#   tools/sync-metakit-fork.sh <fork checkout>            take the checkout's HEAD (it must be committed: the copy names a real commit)
#   tools/sync-metakit-fork.sh --check <fork checkout>    fail unless the vendored copy is byte for byte that checkout's HEAD
#
# The copy is `git archive` of the commit (gzip -n: the same commit always gives the same bytes), named after the commit; tools/vendor/METAKIT-FORK
# records repository, commit, file and SHA-256, which build-kit.sh checks before it uses the file.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
vendor="$here/vendor"
check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
src=${1:?usage: sync-metakit-fork.sh [--check] <fork checkout>}
[ -d "$src/.git" ] || [ -f "$src/.git" ] || { echo "$src is not a git checkout" >&2; exit 1; }
if [ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]; then echo "$src has uncommitted changes: the copy must name a real commit" >&2; exit 1; fi
commit=$(git -C "$src" rev-parse HEAD)
short=${commit:0:12}
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
tmp=$(mktemp "${TMPDIR:-/tmp}/metakit-fork.XXXXXX")
trap 'rm -f "$tmp"' EXIT
git -C "$src" archive --format=tar --prefix=metakit-2.4.9.7/ "$commit" | gzip -n > "$tmp"
sum=$(sha256 "$tmp")
file="metakit-fork-$short.tar.gz"
if [ "$check" = 1 ]; then
    want=$(sed -n 's/^sha256 //p' "$vendor/METAKIT-FORK")
    have_commit=$(sed -n 's/^commit //p' "$vendor/METAKIT-FORK")
    if [ "$have_commit" != "$commit" ]; then echo "the vendored copy is of $have_commit, the checkout is at $commit" >&2; exit 1; fi
    [ "$sum" = "$want" ] || { echo "the vendored copy differs from commit $commit (sha256 $want, want $sum)" >&2; exit 1; }
    echo "the vendored Metakit fork is byte for byte commit $short"
    exit 0
fi
rm -f "$vendor"/metakit-fork-*.tar.gz
cp "$tmp" "$vendor/$file" ; chmod 644 "$vendor/$file"
branch=$(git -C "$src" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
[ "$branch" = HEAD ] && branch=${FORK_BRANCH:-ccr-7001915e-qdjw33}      # (a detached checkout: the branch the commit was taken from)
cat > "$vendor/METAKIT-FORK" <<EOT
Metakit with 64-bit file positions (files over 2 GiB), compiled into every runtime by tools/build-kit.sh
repository https://github.com/atyr647/metakit
branch ${branch}
commit $commit
file $file
sha256 $sum
EOT
echo "vendored $file ($(wc -c < "$vendor/$file") bytes) = commit $short"
