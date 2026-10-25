#!/bin/sh
# Builds DevPanel.app (release, ad-hoc signed); accepts an optional output directory.
#
#   apps/mac/scripts/bundle.sh            # build/DevPanel.app
#   apps/mac/scripts/bundle.sh /absolute/output/directory
#   VERSION=0.4.1-dev apps/mac/scripts/bundle.sh
#
# Never starts the app, the daemon or any project.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

VERSION=${VERSION:-0.4.1}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
OUTPUT_DIR=${1:-"$HERE/build"}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
APP="$OUTPUT_DIR/DevPanel.app"
WORK="$OUTPUT_DIR/work"

echo "==> swift build -c release"
swift build -c release --product DevPanel
BIN_DIR=$(swift build -c release --show-bin-path)

echo "==> assembling $APP"
rm -rf "$APP" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"
cp "$BIN_DIR/DevPanel" "$APP/Contents/MacOS/DevPanel"

echo "==> icon"
if swift scripts/make-icon.swift "$WORK/AppIcon.iconset" && iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "warning: icon generation failed; bundling without an icon" >&2
  ICON_KEY=""
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.devpanel.app</string>
  <key>CFBundleName</key><string>DevPanel</string>
  <key>CFBundleDisplayName</key><string>DevPanel</string>
  <key>CFBundleExecutable</key><string>DevPanel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  $ICON_KEY
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>DevPanel</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

rm -rf "$WORK"
echo "==> done: $APP"
