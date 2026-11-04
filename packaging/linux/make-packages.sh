#!/bin/sh
# Build the Linux packages from a starpack:   packaging/linux/make-packages.sh <version> <starpack> <outdir>
#   <outdir>/mkstudio_<version>_amd64.deb            (version 1.0.0-rc.1 becomes 1.0.0~rc.1 for dpkg: it sorts BEFORE 1.0.0)
#   <outdir>/MKStudio-<version>-linux-x86_64.tar.gz  (binary, launcher, icons, install.sh for ~/.local)
set -e
VER=$1 ; BIN=$2 ; OUT=$3
[ -n "$VER" ] && [ -f "$BIN" ] && [ -n "$OUT" ] || { echo "usage: $0 <version> <starpack> <outdir>"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ICONS=$HERE/../icons
mkdir -p "$OUT"
DEBVER=$(echo "$VER" | sed 's/-/~/')
W=$(mktemp -d) ; trap 'rm -rf "$W"' EXIT

# ---- .deb
P=$W/deb
mkdir -p "$P/DEBIAN" "$P/usr/bin" "$P/usr/share/applications" "$P/usr/share/doc/mkstudio"
install -m 0755 "$BIN" "$P/usr/bin/mkstudio"
install -m 0644 "$HERE/mkstudio.desktop" "$P/usr/share/applications/mkstudio.desktop"
for n in 16 32 48 64 128 256 512; do
  mkdir -p "$P/usr/share/icons/hicolor/${n}x${n}/apps"
  install -m 0644 "$ICONS/icon-$n.png" "$P/usr/share/icons/hicolor/${n}x${n}/apps/mkstudio.png"
done
install -m 0644 "$HERE/../../LICENSE" "$P/usr/share/doc/mkstudio/copyright"
install -m 0644 "$HERE/../../THIRD_PARTY_NOTICES" "$P/usr/share/doc/mkstudio/THIRD_PARTY_NOTICES"
cat > "$P/usr/share/doc/mkstudio/README" <<DOC
MK Studio $VER - a workbench for Metakit databases.
https://github.com/atyr647/mkstudio
DOC
SIZE=$(du -sk "$P/usr" | cut -f1)
cat > "$P/DEBIAN/control" <<CTL
Package: mkstudio
Version: $DEBVER
Section: database
Priority: optional
Architecture: amd64
Depends: libc6 (>= 2.28), libx11-6, libxft2, libfontconfig1
Installed-Size: $SIZE
Maintainer: atyr647 <atyr647@users.noreply.github.com>
Homepage: https://github.com/atyr647/mkstudio
Description: Workbench for Metakit databases
 Browse, query (standard SQL), design and edit Metakit databases. One self-contained
 program (a Tcl/Tk starpack); only the usual X11 libraries are needed.
CTL
cat > "$P/DEBIAN/postinst" <<'PI'
#!/bin/sh
set -e
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q 2>/dev/null || true
exit 0
PI
chmod 0755 "$P/DEBIAN/postinst"
dpkg-deb --root-owner-group --build "$P" "$OUT/mkstudio_${DEBVER}_amd64.deb" >/dev/null

# ---- tar.gz
T=$W/MKStudio-$VER-linux-x86_64
mkdir -p "$T"
install -m 0755 "$BIN" "$T/mkstudio"
install -m 0644 "$HERE/mkstudio.desktop" "$T/mkstudio.desktop"
install -m 0644 "$ICONS/icon-256.png" "$T/mkstudio.png"
install -m 0644 "$HERE/../../LICENSE" "$T/LICENSE"
install -m 0644 "$HERE/../../THIRD_PARTY_NOTICES" "$T/THIRD_PARTY_NOTICES"
cat > "$T/install.sh" <<'INS'
#!/bin/sh
# Install for the current user only (no root): program in ~/.local/bin, launcher and icon in ~/.local/share.
set -e
D=$(cd "$(dirname "$0")" && pwd)
B=${XDG_DATA_HOME:-$HOME/.local/share}
mkdir -p "$HOME/.local/bin" "$B/applications" "$B/icons/hicolor/256x256/apps"
install -m 0755 "$D/mkstudio" "$HOME/.local/bin/mkstudio"
install -m 0644 "$D/mkstudio.png" "$B/icons/hicolor/256x256/apps/mkstudio.png"
sed "s|^Exec=.*|Exec=$HOME/.local/bin/mkstudio %F|" "$D/mkstudio.desktop" > "$B/applications/mkstudio.desktop"
echo "Installed: ~/.local/bin/mkstudio (make sure ~/.local/bin is on your PATH) and a launcher entry."
INS
chmod 0755 "$T/install.sh"
tar -C "$W" -czf "$OUT/MKStudio-$VER-linux-x86_64.tar.gz" "MKStudio-$VER-linux-x86_64"
ls -l "$OUT"
