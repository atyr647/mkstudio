#!/bin/bash
# Build a current Tcl/Tk 8.6 + Metakit tclkit with KitCreator.  Used by CI for the Linux and Windows runtimes
# (the macOS job does the same steps inline, natively on each Mac).
#
#   tools/build-kit.sh linux   WORKDIR     native build (CI runs it in a glibc 2.28 container so it runs on old distros)
#   tools/build-kit.sh windows WORKDIR     mingw-w64 cross-build from Linux
#
# Prints the path of the finished kit on its last line.  Everything downloaded is pinned and checked:
# KitCreator by revision + SHA-256 of the tarball, zlib by SHA-256 (KitCreator pins its own sources the same way).
set -euo pipefail

platform=${1:?usage: build-kit.sh linux|windows WORKDIR}
work=${2:?usage: build-kit.sh linux|windows WORKDIR}
TCL_VERSION=${TCL_VERSION:-8.6.16}

# KitCreator trunk, 2024-05-21 "Upgrade to Tcl/Tk 8.6.14" (a later Tcl version is only a download name for it)
KC_UUID=97a1e6339fc8869c
KC_SHA256=725d38479f6823a69b7c6043784544c7705a04387c5b15549e2c1e4ba96a52da
# KitCreator still pins zlib 1.2.8 (2013); use the current release instead
ZLIB_VERSION=1.3.1
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fetch() {  # url file sha256
    curl -fsSL --retry 3 -o "$2" "$1"
    got=$(sha256 "$2")
    if [ "$got" != "$3" ]; then echo "SHA-256 mismatch for $1: got $got, want $3" >&2; exit 1; fi
}

mkdir -p "$work"; cd "$work"
rm -rf kitcreator kc.tgz zlib.tgz
fetch "https://kitcreator.rkeene.org/fossil/tarball/kitcreator.tar.gz?uuid=${KC_UUID}" kc.tgz "$KC_SHA256"
tar xzf kc.tgz
fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" zlib.tgz "$ZLIB_SHA256"
cd kitcreator

sed -i -e "s|^version=.*|version=\"${ZLIB_VERSION}\"|" \
       -e "s|^url=.*|url=\"https://github.com/madler/zlib/releases/download/v\${version}/zlib-\${version}.tar.gz\"|" \
       -e "s|^sha256=.*|sha256='${ZLIB_SHA256}'|" zlib/build.sh
grep -q "sha256='${ZLIB_SHA256}'" zlib/build.sh || { echo "could not pin zlib in KitCreator" >&2; exit 1; }

# a repository checkout (not a release tarball) needs kitsh's generated files
bash build/pre.sh

# Metakit is old C++ and kitsh uses K&R-style C parameter lists: keep the compilers in the dialects they were written for
export CXXFLAGS="-std=c++11 -Wno-register -Wno-deprecated -w"
export CFLAGS="-w -std=gnu99"

case $platform in
linux)
    # the C++ runtime goes in statically: the kit must not need a newer libstdc++ than the user's machine has
    export KC_KITSH_LDFLAGS="-static-libgcc -static-libstdc++"
    ./kitcreator "$TCL_VERSION" --enable-64bit || fail=1
    ;;
windows)
    [ -n "${TCLKIT:-}" ] || { echo "TCLKIT must name a Tclkit that runs on this machine (it fills the Windows kit's virtual file system)" >&2; exit 1; }
    export TCLKIT
    # the win32 thread model needs no libwinpthread DLL; libgcc/libstdc++ are linked in so the .exe stands alone
    export AR=x86_64-w64-mingw32-ar CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++
    export RANLIB=x86_64-w64-mingw32-ranlib RC=x86_64-w64-mingw32-windres STRIP=x86_64-w64-mingw32-strip
    export PKG_CONFIG_PATH=/dev/null/null PKG_CONFIG_DIR=/dev/null/null
    export KC_KITSH_LDFLAGS="-static-libgcc -static-libstdc++"
    # what Tcl cannot detect when cross-compiling (the same answers KitCreator's own make-kit-win64 relies on)
    export ac_cv_func_memcmp_working=yes tcl_cv_strstr_unbroken=ok tcl_cv_strtoul_unbroken=ok
    export tcl_cv_strtod_unbroken=ok tcl_cv_strtod_buggy=ok
    ./kitcreator "$TCL_VERSION" --host=x86_64-w64-mingw32 || fail=1
    ;;
*) echo "unknown platform $platform" >&2; exit 1 ;;
esac

if [ "${fail:-0}" = 1 ] || [ ! -f "tclkit-${TCL_VERSION}" ]; then
    echo "::error::KitCreator failed"
    # Tk tries several build directories in turn, so the LAST error is for the wrong platform; show the first
    for p in tcl tk mk4tcl zlib kitsh; do
        if [ -f "$p/build.log" ]; then
            echo "::group::$p/build.log - first errors"
            grep -n -m8 -i -B2 -A6 'error\|No such file\|not found\|cannot' "$p/build.log" | head -80 || true
            echo "::endgroup::"
            echo "::group::$p/build.log - last 30 lines"; tail -30 "$p/build.log"; echo "::endgroup::"
        fi
    done
    exit 1
fi

out="$work/tclkit-${TCL_VERSION}-$platform-x86_64"
[ "$platform" = windows ] && out="$out.exe"
cp "tclkit-${TCL_VERSION}" "$out"
chmod +x "$out"
echo "$out"
