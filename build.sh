#!/bin/sh
# Builds Bodega.app next to this script. SwiftPM scratch lives outside Google Drive to avoid sync churn.
set -eu
cd "$(dirname "$0")"
SCRATCH="${TMPDIR:-/tmp}/bodega-build"
VERSION=0.2.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)  # commit count: ties a build to its commit
swift build -c release --scratch-path "$SCRATCH"
mkdir -p build.noindex  # Spotlight skips *.noindex: only ~/Applications shows up
APP=build.noindex/Bodega.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/Bodega" "$APP/Contents/MacOS/Bodega"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Bodega</string>
  <key>CFBundleIdentifier</key><string>local.bodega</string>
  <key>CFBundleExecutable</key><string>Bodega</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign -s - --force "$APP"
echo "Built $(pwd)/$APP"
if [ "${1:-}" = "--install" ]; then
  # rm first: ditto merges into an existing bundle and would keep stale files.
  rm -rf "$HOME/Applications/Bodega.app"
  ditto "$APP" "$HOME/Applications/Bodega.app"
  echo "Installed $HOME/Applications/Bodega.app"
fi
