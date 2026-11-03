#!/bin/sh
# Build "MK Studio.app" and a .dmg from a macOS starpack (run on a Mac):
#   packaging/macos/make-dmg.sh <version> <starpack> <outdir>
# The app is signed ad hoc (no Apple developer certificate), so on first start macOS asks you to confirm:
# right-click the app > Open.  The README says so.
set -e
VER=$1 ; BIN=$2 ; OUT=$3
[ -n "$VER" ] && [ -f "$BIN" ] && [ -n "$OUT" ] || { echo "usage: $0 <version> <starpack> <outdir>"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ARCH=$(uname -m)
BASE=${VER%%-*}                       # 1.0.0-rc.1 -> 1.0.0 (CFBundleShortVersionString must be numeric)
W=$(mktemp -d) ; trap 'rm -rf "$W"' EXIT
APP="$W/stage/MK Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/mkstudio" && chmod +x "$APP/Contents/MacOS/mkstudio"
cp "$HERE/../icons/mkstudio.icns" "$APP/Contents/Resources/mkstudio.icns"
cp "$HERE/../../LICENSE" "$HERE/../../THIRD_PARTY_NOTICES" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MK Studio</string>
  <key>CFBundleDisplayName</key><string>MK Studio</string>
  <key>CFBundleIdentifier</key><string>io.github.atyr647.mkstudio</string>
  <key>CFBundleExecutable</key><string>mkstudio</string>
  <key>CFBundleIconFile</key><string>mkstudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BASE</string>
  <key>CFBundleVersion</key><string>$BASE</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MK Studio $VER</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Metakit database</string>
      <key>CFBundleTypeExtensions</key><array><string>mk</string><string>mk4</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
# A starpack carries its payload after the Mach-O image.  codesign signs such a file fine on its own (the wrap step in CI
# does), but refuses to seal the whole bundle around it ("main executable failed strict validation").  So: try the bundle
# first; if that is refused, sign the executable alone - Apple silicon only insists on a valid signature on the executable
# - and say so.  What counts is that the finished app runs, which CI tests from the mounted .dmg.
if ! codesign --force --deep --sign - "$APP"; then
  echo "note: the bundle could not be sealed around the starpack; signing the executable alone"
  codesign --force --sign - "$APP/Contents/MacOS/mkstudio"
fi
codesign --verify --deep "$APP" || echo "note: codesign --verify is not clean for a bundle around an appended starpack; the app is tested by running it"
ln -s /Applications "$W/stage/Applications"
mkdir -p "$OUT"
DMG="$OUT/MKStudio-$VER-macos-$ARCH.dmg"
rm -f "$DMG"
hdiutil create -volname "MK Studio $VER" -srcfolder "$W/stage" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
