#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

APP_DIR="$PWD/dist/MSkill.app"
ICON_SOURCE="$PWD/Sources/MSkill/Resources/AppIcon.png"
ICONSET_DIR="$PWD/.build/MSkill.iconset"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$ICONSET_DIR"
cp .build/release/MSkill "$APP_DIR/Contents/MacOS/MSkill"
cp "$ICON_SOURCE" "$APP_DIR/Contents/Resources/AppIcon.png"
for icon_size in 16 32 128 256 512; do
  sips -z "$icon_size" "$icon_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${icon_size}x${icon_size}.png" >/dev/null
  retina_size=$((icon_size * 2))
  sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET_DIR" --output "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MSkill</string>
  <key>CFBundleDisplayName</key><string>MSkill</string>
  <key>CFBundleIdentifier</key><string>dev.mskill.app</string>
  <key>CFBundleExecutable</key><string>MSkill</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP_DIR"
echo "Built $APP_DIR"
