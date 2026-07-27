#!/bin/bash
# Assembles Octavo.app from the SwiftPM executable. SwiftPM builds a bare binary;
# a GUI app needs the bundle layout, an Info.plist and a signature.
set -euo pipefail

CONFIGURATION="${1:-release}"
# Injectable so the release workflow can stamp the git tag into the bundle. A bare local
# run keeps 0.1 (1), so nothing about `./Scripts/make-app.sh` changes.
OCTAVO_VERSION="${OCTAVO_VERSION:-0.1}"
OCTAVO_VERSION="${OCTAVO_VERSION#v}"  # tolerate a raw tag name such as v0.2.1
OCTAVO_BUILD="${OCTAVO_BUILD:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Octavo.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product Octavo
BINARY="$(swift build -c "$CONFIGURATION" --product Octavo --show-bin-path)/Octavo"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Octavo"

# Committed, not generated here — Scripts/make-icon.swift redraws it when the artwork
# changes. Must land before codesign so the signature seals it.
cp "$ROOT/Resources/Octavo.icns" "$APP/Contents/Resources/Octavo.icns"

# Unquoted delimiter: the body carries no $, backtick or backslash of its own, so the two
# version substitutions below are the only expansions.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleName</key><string>Octavo</string>
    <key>CFBundleDisplayName</key><string>Octavo</string>
    <key>CFBundleIdentifier</key><string>org.octavo.Octavo</string>
    <key>CFBundleExecutable</key><string>Octavo</string>
    <key>CFBundleIconFile</key><string>Octavo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${OCTAVO_VERSION}</string>
    <key>CFBundleVersion</key><string>${OCTAVO_BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Sync your calibre library with Kindle e-readers</string>
</dict>
</plist>
PLIST

# A malformed injected version would otherwise get sealed into the signature.
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature is enough for a locally built app; USB access needs no entitlement
# because the MTP interface is unclaimed by any system driver.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "$APP ($OCTAVO_VERSION build $OCTAVO_BUILD)"
du -sh "$APP" | cut -f1 | xargs echo "Size:"
