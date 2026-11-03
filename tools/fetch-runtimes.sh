#!/bin/sh
# Download the tclkit runtimes used to build and test MK Studio into tools/ext/.
# Every file is checked against its published SHA1 (tclkits.rkeene.org names each
# file by its hash), so a corrupted or tampered download is rejected.
#
#   tools/fetch-runtimes.sh            all runtimes
#   tools/fetch-runtimes.sh linux      just the Linux 8.6 kit (enough to build and test)
set -e
cd "$(dirname "$0")"
mkdir -p ext
# macOS has shasum, not sha1sum
sha1() { if command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | cut -d' ' -f1; else shasum -a 1 "$1" | cut -d' ' -f1; fi; }
BASE=https://tclkits.rkeene.org/fossil/raw
want=${1:-all}

get() {  # name remote-name sha1
    out=ext/$1
    if [ -f "$out" ] && [ "$(sha1 "$out")" = "$3" ]; then echo "ok      $1"; return; fi
    echo "fetch   $1"
    curl -fsSL --retry 3 -o "$out.part" "$BASE/$2?name=$3"
    got=$(sha1 "$out.part")
    if [ "$got" != "$3" ]; then rm -f "$out.part"; echo "SHA1 mismatch for $1 (got $got)"; exit 1; fi
    mv "$out.part" "$out"; chmod +x "$out"
}

get tclkit-8.6.3-linux-x86_64        tclkit-8.6.3-rhel5-x86_64          36b5cb68899cfcb79417a29f9c6d8176ebae0d24
[ "$want" = linux ] && exit 0
get tclkit-8.5.17-linux-x86_64       tclkit-8.5.17-rhel5-x86_64         76a197fe41359daaf4f90a2001f46675b3667e26
get tclkit-8.6.3-win32-x86_64.exe    tclkit-8.6.3-win32-x86_64.exe      403c507437d0b10035c7839f22f5bb806ec1f491
# (No prebuilt macOS kit: the 2014 Tk 8.6.3 / 8.5.17 macOS builds crash on current macOS the first time a
# window is mapped.  CI builds a current Tcl/Tk 8.6 kit with KitCreator on the Mac itself - see
# .github/workflows/build.yml - and wraps the starpack with that.)
