#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/dist}"
APP_NAME="${APP_NAME:-Orbit}"
BUNDLE_ID="${BUNDLE_ID:-com.orbit.menubar}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
ICON_SVG="${ICON_SVG:-$ROOT_DIR/docs/images/orbit-app-icon.svg}"
CREATE_ZIP="${CREATE_ZIP:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
ORBIT_RELEASE_BUILD="${ORBIT_RELEASE_BUILD:-0}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://nikitakavka.github.io/orbit/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_PUBLIC_ED_KEY_FILE="${SPARKLE_PUBLIC_ED_KEY_FILE:-}"

APP_DIR="$OUT_DIR/$APP_NAME.app"
ZIP_PATH="$OUT_DIR/$APP_NAME.app.zip"
BIN_PATH="$ROOT_DIR/.build/release/orbit-menubar"
SPARKLE_FRAMEWORK_PATH="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_FRAMEWORK_VERSION_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"

if [[ ! -f "$ICON_SVG" ]]; then
  echo "Icon SVG not found: $ICON_SVG" >&2
  exit 1
fi

if [[ "$ORBIT_RELEASE_BUILD" != "0" && "$ORBIT_RELEASE_BUILD" != "1" ]]; then
  echo "ORBIT_RELEASE_BUILD must be 0 or 1" >&2
  exit 1
fi

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" && -n "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
  echo "Set only one of SPARKLE_PUBLIC_ED_KEY or SPARKLE_PUBLIC_ED_KEY_FILE." >&2
  exit 1
fi

if [[ -n "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
  if [[ ! -f "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
    echo "Sparkle public key file not found: $SPARKLE_PUBLIC_ED_KEY_FILE" >&2
    exit 1
  fi
  SPARKLE_PUBLIC_ED_KEY="$(<"$SPARKLE_PUBLIC_ED_KEY_FILE")"
fi
SPARKLE_PUBLIC_ED_KEY="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | tr -d '\r\n')"

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  DECODED_PUBLIC_KEY_LENGTH="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | /usr/bin/base64 -D 2>/dev/null | wc -c | tr -d '[:space:]')"
  if [[ "$DECODED_PUBLIC_KEY_LENGTH" != "32" ]]; then
    echo "SPARKLE_PUBLIC_ED_KEY must be a base64-encoded 32-byte Ed25519 public key." >&2
    exit 1
  fi
elif [[ "$ORBIT_RELEASE_BUILD" == "1" ]]; then
  echo "Release builds require SPARKLE_PUBLIC_ED_KEY_FILE (preferred) or SPARKLE_PUBLIC_ED_KEY." >&2
  exit 1
fi

if [[ "$ORBIT_RELEASE_BUILD" == "1" && "$SPARKLE_FEED_URL" != https://* ]]; then
  echo "Release builds require an HTTPS SPARKLE_FEED_URL." >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  echo "BUILD_NUMBER must contain one to three dot-separated integers: $BUILD_NUMBER" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "[1/7] Building orbit-menubar (release)"
(cd "$ROOT_DIR" && swift build -c release --product orbit-menubar >/dev/null)

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Built binary not found: $BIN_PATH" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK_PATH" ]]; then
  echo "Sparkle.framework not found: $SPARKLE_FRAMEWORK_PATH" >&2
  exit 1
fi

echo "[2/7] Creating app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "[3/7] Embedding Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK_PATH" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

echo "[4/7] Generating AppIcon.icns from $(basename "$ICON_SVG")"
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

echo "[5/7] Writing Info.plist"
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
  <string>$BUILD_NUMBER</string>
  <key>OrbitGitCommit</key>
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
  <key>NSLocalNetworkUsageDescription</key>
  <string>Orbit uses SSH to connect to your cluster login node and read your SLURM queue.</string>
</dict>
</plist>
PLIST

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$APP_DIR/Contents/Info.plist"
  plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$APP_DIR/Contents/Info.plist"
  plutil -insert SUEnableAutomaticChecks -bool YES "$APP_DIR/Contents/Info.plist"
  plutil -insert SUAutomaticallyUpdate -bool NO "$APP_DIR/Contents/Info.plist"
  plutil -insert SUScheduledCheckInterval -integer 43200 "$APP_DIR/Contents/Info.plist"
  plutil -insert SURequireSignedFeed -bool YES "$APP_DIR/Contents/Info.plist"
  plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$APP_DIR/Contents/Info.plist"
  if [[ "$SPARKLE_FEED_URL" == http://localhost:* || "$SPARKLE_FEED_URL" == http://127.0.0.1:* ]]; then
    plutil -insert NSAppTransportSecurity -xml '<dict><key>NSAllowsLocalNetworking</key><true/></dict>' "$APP_DIR/Contents/Info.plist"
  fi
else
  echo "Warning: SPARKLE_PUBLIC_ED_KEY is empty; in-app updates are disabled in this build." >&2
fi

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

echo "[6/7] Code signing"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  # Preserve Sparkle's shipped helper signatures and entitlements. Only the
  # containing app needs a fresh ad-hoc signature after its plist is created.
  codesign --force --sign - "$APP_DIR"
else
  # Sparkle helpers must be signed inside-out. Do not use codesign --deep for
  # signing because it can strip helper-specific entitlements.
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK_VERSION_DIR/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$CODESIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK_VERSION_DIR/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK_VERSION_DIR/Autoupdate"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK_VERSION_DIR/Updater.app"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

touch "$APP_DIR"
if command -v /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister >/dev/null 2>&1; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "[7/7] Packaging zip"
if [[ "$CREATE_ZIP" == "1" ]]; then
  rm -f "$ZIP_PATH"
  COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
  echo "Built zip: $ZIP_PATH"
else
  echo "CREATE_ZIP=$CREATE_ZIP → skipping zip"
fi

echo "Built app: $APP_DIR"
echo "Open with: open \"$APP_DIR\""
