#!/usr/bin/env bash
set -euo pipefail
umask 077

OUTPUT_DIR="${1:-}"
if [[ -z "$OUTPUT_DIR" ]]; then
  echo "Usage: $0 /secure/path/for/orbit-update-keys" >&2
  exit 1
fi

PRIVATE_KEY_PATH="$OUTPUT_DIR/sparkle-private.key"
PUBLIC_KEY_PATH="$OUTPUT_DIR/sparkle-public.txt"

if [[ -e "$PRIVATE_KEY_PATH" || -e "$PUBLIC_KEY_PATH" ]]; then
  echo "Refusing to overwrite an existing update key in $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
TEMP_SCRIPT="$(mktemp -t orbit-generate-update-key).swift"
trap 'rm -f "$TEMP_SCRIPT"' EXIT

cat >"$TEMP_SCRIPT" <<'SWIFT'
import CryptoKit
import Foundation

let privateKeyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let publicKeyURL = URL(fileURLWithPath: CommandLine.arguments[2])
let privateKey = Curve25519.Signing.PrivateKey()
let privateValue = privateKey.rawRepresentation.base64EncodedString() + "\n"
let publicValue = privateKey.publicKey.rawRepresentation.base64EncodedString() + "\n"
try privateValue.write(to: privateKeyURL, atomically: true, encoding: .utf8)
try publicValue.write(to: publicKeyURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicKeyURL.path)
SWIFT

swift "$TEMP_SCRIPT" "$PRIVATE_KEY_PATH" "$PUBLIC_KEY_PATH"

echo "Generated Orbit update signing keypair without Keychain access."
echo "Private key: $PRIVATE_KEY_PATH"
echo "Public key:  $PUBLIC_KEY_PATH"
echo "Back up the private key securely. Losing it breaks the trusted update path for existing installations."
