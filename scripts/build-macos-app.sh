#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/dist}"
APP_NAME="${APP_NAME:-Orbit}"
BUNDLE_ID="${BUNDLE_ID:-com.orbit.menubar}"
VERSION="${VERSION:-1.0.0}"
ICON_SVG="${ICON_SVG:-$ROOT_DIR/docs/images/orbit-app-icon.svg}"
CREATE_ZIP="${CREATE_ZIP:-1}"

APP_DIR="$OUT_DIR/$APP_NAME.app"
ZIP_PATH="$OUT_DIR/$APP_NAME.app.zip"
BIN_PATH="$ROOT_DIR/.build/release/orbit-menubar"

if [[ ! -f "$ICON_SVG" ]]; then
  echo "Icon SVG not found: $ICON_SVG" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[1/6] Building orbit-menubar (release)"
(cd "$ROOT_DIR" && swift build -c release --product orbit-menubar >/dev/null)

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Built binary not found: $BIN_PATH" >&2
  exit 1
fi

echo "[2/6] Creating app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "[3/6] Generating AppIcon.icns from $(basename "$ICON_SVG")"
TMP_DIR="$(mktemp -d -t orbit-app-build-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

qlmanage -t -s 1024 -o "$TMP_DIR" "$ICON_SVG" >/dev/null 2>&1
RENDERED_PNG="$(find "$TMP_DIR" -maxdepth 1 -name '*.png' | head -n 1)"

if [[ -z "$RENDERED_PNG" ]]; then
  echo "Failed to render PNG from SVG via qlmanage" >&2
  exit 1
fi

ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$RENDERED_PNG" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
  SIZE2X=$((SIZE * 2))
  sips -z "$SIZE2X" "$SIZE2X" "$RENDERED_PNG" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"

echo "[4/6] Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>$GIT_SHA</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "[5/6] Ad-hoc code signing"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

touch "$APP_DIR"
if command -v /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister >/dev/null 2>&1; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "[6/6] Packaging zip"
if [[ "$CREATE_ZIP" == "1" ]]; then
  rm -f "$ZIP_PATH"
  COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
  echo "Built zip: $ZIP_PATH"
else
  echo "CREATE_ZIP=$CREATE_ZIP → skipping zip"
fi

echo "Built app: $APP_DIR"
echo "Open with: open \"$APP_DIR\""
