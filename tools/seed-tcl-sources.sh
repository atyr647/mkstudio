#!/bin/sh
# Put VERIFIED Tcl and Tk source archives where KitCreator looks for them, so it never downloads them itself.
#
#   tools/seed-tcl-sources.sh <kitcreator-dir> <tcl-version>
#
# KitCreator carries a table of SHA-256 checksums for the Tcl/Tk versions it knew when the pinned revision was made (up to 8.6.14).
# For anything newer it downloads "http://prdownloads.sourceforge.net/..." with NO checksum at all (hash '-'): plain HTTP, nothing
# checked.  Here the archives are fetched over HTTPS and compared with the SHA-256 recorded below; a mismatch stops the build.
# The values were taken from the SourceForge files when they were pinned (trust on first use: the Tcl project publishes no checksums
# for these files).  To move to another version, download both archives once, look at the hashes, and add a line.
set -eu
kc=${1:?usage: seed-tcl-sources.sh <kitcreator-dir> <tcl-version>}
v=${2:?usage: seed-tcl-sources.sh <kitcreator-dir> <tcl-version>}
case $v in
    8.6.16)
        tcl_sha=91cb8fa61771c63c262efb553059b7c7ad6757afa5857af6265e4b0bdc2a14a5
        tk_sha=be9f94d3575d4b3099d84bc3c10de8994df2d7aa405208173c709cc404a7e5fe ;;
    8.6.18)                      # the last 8.6 release (2026-05-11)
        tcl_sha=14f9af32b1767ff718477a8f974ad03c34341097e6b43f4ce54644ee974e268e
        tk_sha=95cd528a80f5e4bdb557af9b14a7197d6860793a3894e25e7c9fad2ed05d4c3c ;;
    *) echo "seed-tcl-sources.sh: no pinned checksums for Tcl/Tk $v - add them (see the comment above)" >&2; exit 1 ;;
esac
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
get() {  # name archive-name wanted-sha256 destination
    mkdir -p "$(dirname "$4")"
    curl -fsSL --retry 3 -o "$4.part" "https://downloads.sourceforge.net/project/tcl/Tcl/$v/$2"
    got=$(sha256 "$4.part")
    if [ "$got" != "$3" ]; then rm -f "$4.part"; echo "SHA-256 of $2 is $got, expected $3" >&2; exit 1; fi
    mv "$4.part" "$4"
    echo "verified $2 ($3)"
}
get tcl "tcl$v-src.tar.gz" "$tcl_sha" "$kc/tcl/src/tcl$v.tar.gz"
if [ "${TCL_ONLY:-0}" != 1 ]; then get tk  "tk$v-src.tar.gz"  "$tk_sha"  "$kc/tk/src/tk$v.tar.gz"; fi   # (TCL_ONLY=1: only the headers are wanted)
