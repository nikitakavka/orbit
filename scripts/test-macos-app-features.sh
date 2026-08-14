#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d -t orbit-feature-test)"
APP_NAME="OrbitFeatureTest"
BUNDLE_ID="com.orbit.menubar.featuretest"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
SPARKLE_TOOLS_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  pkill -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  rm -rf "$INSTALLED_APP" "$TEST_ROOT"
}
trap cleanup EXIT

# This script intentionally avoids Git/SwiftPM credential helpers and the Keychain.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never
export GH_PROMPT_DISABLED=1

mkdir -p "$TEST_ROOT/old" "$TEST_ROOT/new" "$TEST_ROOT/feed" "$HOME/Applications"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"

cat >"$TEST_ROOT/generate-key.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT

umask 077
swift "$TEST_ROOT/generate-key.swift" >"$TEST_ROOT/keypair"
head -n 1 "$TEST_ROOT/keypair" >"$TEST_ROOT/private.key"
tail -n 1 "$TEST_ROOT/keypair" >"$TEST_ROOT/public.key"
PUBLIC_KEY="$(<"$TEST_ROOT/public.key")"

build_test_app() {
  local output_dir="$1"
  local version="$2"
  local build_number="$3"

  APP_NAME="$APP_NAME" \
  BUNDLE_ID="$BUNDLE_ID" \
  VERSION="$version" \
  BUILD_NUMBER="$build_number" \
  CREATE_ZIP=1 \
  SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY" \
  SPARKLE_FEED_URL="http://localhost:$PORT/appcast.xml" \
    "$ROOT_DIR/scripts/build-macos-app.sh" "$output_dir" >/dev/null
}

echo "[1/5] Building old and new temporary apps"
build_test_app "$TEST_ROOT/old" 9.0.0 9000
build_test_app "$TEST_ROOT/new" 9.0.1 9001

for app in "$TEST_ROOT/old/$APP_NAME.app" "$TEST_ROOT/new/$APP_NAME.app"; do
  if [[ "$(plutil -extract SUAutomaticallyUpdate raw "$app/Contents/Info.plist")" != "false" ]]; then
    echo "Automatic update archive downloads must remain disabled." >&2
    exit 1
  fi
done

cp "$TEST_ROOT/new/$APP_NAME.app.zip" "$TEST_ROOT/feed/$APP_NAME.app.zip"
SPARKLE_PRIVATE_KEY_FILE="$TEST_ROOT/private.key" \
DOWNLOAD_URL_PREFIX="http://localhost:$PORT/" \
RELEASE_TAG=v9.0.1 \
  "$ROOT_DIR/scripts/generate-update-appcast.sh" \
    "$TEST_ROOT/new/$APP_NAME.app.zip" \
    "$TEST_ROOT/feed/appcast.xml" >/dev/null

echo "[2/5] Verifying the signed update archive"
SIGNATURE="$(python3 - "$TEST_ROOT/feed/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
enclosure = ET.parse(sys.argv[1]).find('.//enclosure')
print(enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'])
PY
)"
RELEASE_LINK="$(python3 - "$TEST_ROOT/feed/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
link = ET.parse(sys.argv[1]).find('.//item/link')
print(link.text if link is not None else '')
PY
)"
if [[ "$RELEASE_LINK" != "https://github.com/nikitakavka/orbit/releases/tag/v9.0.1" ]]; then
  echo "Appcast is missing its GitHub release link." >&2
  exit 1
fi
"$SPARKLE_TOOLS_DIR/sign_update" \
  --ed-key-file "$TEST_ROOT/private.key" \
  --verify "$TEST_ROOT/feed/$APP_NAME.app.zip" "$SIGNATURE"

rm -rf "$INSTALLED_APP"
ditto "$TEST_ROOT/old/$APP_NAME.app" "$INSTALLED_APP"

echo "[3/5] Registering and unregistering the temporary Login Item"
"$INSTALLED_APP/Contents/MacOS/$APP_NAME" --test-launch-at-login

echo "[4/5] Serving the localhost update feed"
python3 -m http.server "$PORT" \
  --bind 127.0.0.1 \
  --directory "$TEST_ROOT/feed" \
  >"$TEST_ROOT/http.log" 2>&1 &
SERVER_PID=$!
sleep 1

ORBIT_TEST_AUTO_INSTALL_UPDATE=1 \
ORBIT_DB_PATH="$TEST_ROOT/orbit-test.sqlite" \
ORBIT_ENABLE_NOTIFICATIONS=0 \
  "$INSTALLED_APP/Contents/MacOS/$APP_NAME" --test-automatic-update \
  >"$TEST_ROOT/app.log" 2>&1 &

echo "[5/5] Waiting for signed in-app update 9000 → 9001"
for _ in $(seq 1 60); do
  CURRENT_BUILD="$(plutil -extract CFBundleVersion raw "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || echo missing)"
  if [[ "$CURRENT_BUILD" == "9001" ]]; then
    codesign --verify --deep --strict "$INSTALLED_APP"
    echo "macOS feature integration tests: ok"
    exit 0
  fi
  sleep 1
done

echo "Automatic update timed out." >&2
echo "--- app log ---" >&2
tail -100 "$TEST_ROOT/app.log" >&2 || true
echo "--- HTTP log ---" >&2
tail -100 "$TEST_ROOT/http.log" >&2 || true
exit 1
