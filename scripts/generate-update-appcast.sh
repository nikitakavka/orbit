#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_PATH="${1:-$ROOT_DIR/dist/Orbit.app.zip}"
OUTPUT_PATH="${2:-$ROOT_DIR/website/appcast.xml}"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin}"
PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-}"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Update archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

if [[ ! -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]]; then
  echo "Sparkle generate_appcast tool not found. Run 'swift package resolve' first." >&2
  exit 1
fi

if [[ -z "$PRIVATE_KEY_FILE" ]]; then
  echo "Set SPARKLE_PRIVATE_KEY_FILE to the private Ed25519 key file." >&2
  exit 1
fi

if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "Sparkle private key file not found: $PRIVATE_KEY_FILE" >&2
  exit 1
fi

if [[ -L "$PRIVATE_KEY_FILE" ]]; then
  echo "Refusing to use a symlink as the Sparkle private key file." >&2
  exit 1
fi

if [[ ! -O "$PRIVATE_KEY_FILE" ]]; then
  echo "Sparkle private key file must be owned by the current user." >&2
  exit 1
fi

PRIVATE_KEY_MODE="$(stat -f '%Lp' "$PRIVATE_KEY_FILE")"
PRIVATE_KEY_MODE_DECIMAL=$((8#$PRIVATE_KEY_MODE))
if (( (PRIVATE_KEY_MODE_DECIMAL & 077) != 0 )); then
  echo "Sparkle private key permissions are too open ($PRIVATE_KEY_MODE). Run: chmod 600 \"$PRIVATE_KEY_FILE\"" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d -t orbit-appcast-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/archive" "$WORK_DIR/extracted"

ditto -x -k "$ARCHIVE_PATH" "$WORK_DIR/extracted"
APP_BUNDLE="$(find "$WORK_DIR/extracted" -maxdepth 1 -type d -name '*.app' -print -quit)"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
if [[ -z "$APP_BUNDLE" || ! -f "$INFO_PLIST" ]]; then
  echo "No top-level macOS app found in $ARCHIVE_PATH" >&2
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/nikitakavka/orbit/releases/download/$RELEASE_TAG/}"

EMBEDDED_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw "$INFO_PLIST" 2>/dev/null || true)"
if [[ -z "$EMBEDDED_PUBLIC_KEY" ]]; then
  echo "The archived app does not contain SUPublicEDKey; refusing to publish it as an update." >&2
  exit 1
fi

if [[ "$(plutil -extract SURequireSignedFeed raw "$INFO_PLIST" 2>/dev/null || true)" != "true" ||
      "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$INFO_PLIST" 2>/dev/null || true)" != "true" ]]; then
  echo "The archived app must require signed feeds and verification before extraction." >&2
  exit 1
fi

KEY_CHECK_SCRIPT="$WORK_DIR/derive-public-key.swift"
cat >"$KEY_CHECK_SCRIPT" <<'SWIFT'
import CryptoKit
import Foundation

let privateKeyPath = CommandLine.arguments[1]
let encoded = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let raw = Data(base64Encoded: encoded), raw.count == 32 else {
    throw NSError(domain: "OrbitRelease", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Private key must be a base64-encoded 32-byte Ed25519 key."
    ])
}
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
print(privateKey.publicKey.rawRepresentation.base64EncodedString())
SWIFT

if ! DERIVED_PUBLIC_KEY="$(swift "$KEY_CHECK_SCRIPT" "$PRIVATE_KEY_FILE")"; then
  echo "Could not read the Sparkle private key." >&2
  exit 1
fi

if [[ "$DERIVED_PUBLIC_KEY" != "$EMBEDDED_PUBLIC_KEY" ]]; then
  echo "The private update key does not match SUPublicEDKey embedded in the archived app." >&2
  exit 1
fi

ARCHIVE_BASENAME="$(basename "$ARCHIVE_PATH")"
cp "$ARCHIVE_PATH" "$WORK_DIR/archive/$ARCHIVE_BASENAME"
if [[ -n "$RELEASE_NOTES_PATH" ]]; then
  if [[ ! -f "$RELEASE_NOTES_PATH" ]]; then
    echo "Release notes not found: $RELEASE_NOTES_PATH" >&2
    exit 1
  fi
  cp "$RELEASE_NOTES_PATH" "$WORK_DIR/archive/${ARCHIVE_BASENAME%.*}.md"
fi
if [[ -f "$OUTPUT_PATH" ]]; then
  cp "$OUTPUT_PATH" "$WORK_DIR/archive/appcast.xml"
fi

APPCAST_ARGS=(
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"
  --maximum-versions 5
  --maximum-deltas 0
  --link "https://github.com/nikitakavka/orbit/releases/tag/$RELEASE_TAG"
  -o "$WORK_DIR/archive/appcast.xml"
)

"$SPARKLE_TOOLS_DIR/generate_appcast" \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  "${APPCAST_ARGS[@]}" \
  "$WORK_DIR/archive"

OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"
cp "$WORK_DIR/archive/appcast.xml" "$OUTPUT_PATH"
if [[ -n "$RELEASE_NOTES_PATH" ]]; then
  cp "$WORK_DIR/archive/${ARCHIVE_BASENAME%.*}.md" "$OUTPUT_DIR/${ARCHIVE_BASENAME%.*}.md"
fi

echo "Generated appcast: $OUTPUT_PATH"
echo "Version: $VERSION (build $BUILD_NUMBER)"
echo "Download URL: $DOWNLOAD_URL_PREFIX$ARCHIVE_BASENAME"
