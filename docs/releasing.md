# Releasing Orbit updates

Orbit uses [Sparkle 2](https://sparkle-project.org/) for signed, in-app updates. Sparkle checks the signed appcast automatically, but Orbit does not download the release ZIP until the user reviews the release notes and chooses **Download & Install**. Sparkle then verifies the ZIP's EdDSA signature before extraction, replaces `Orbit.app`, and relaunches it. The update prompt also links to the matching GitHub release. This does not require an Apple Developer Program membership.

## One-time signing-key setup

Generate the key outside the repository:

```bash
./scripts/generate-update-keypair.sh "$HOME/.config/orbit-release"
```

This does not access Keychain. It creates:

- `sparkle-private.key` — secret; required to sign every future update
- `sparkle-public.txt` — embedded into every update-enabled Orbit build

Back up the private key securely and never commit it. Without Developer ID signing, losing or changing this key breaks the trusted update path for existing installations.

## Build a release

Use a user-facing version and a numeric build number that is greater than every previous release:

```bash
ORBIT_RELEASE_BUILD=1 \
SPARKLE_PUBLIC_ED_KEY_FILE="$HOME/.config/orbit-release/sparkle-public.txt" \
VERSION=1.1.0 \
BUILD_NUMBER=110 \
./scripts/build-macos-app.sh
```

The build script:

- embeds `Sparkle.framework`
- configures the production feed at `https://nikitakavka.github.io/orbit/appcast.xml`
- requires signed feeds, signed release notes, and pre-extraction archive verification
- enables background update checks while disabling automatic archive downloads
- signs Sparkle's helpers inside-out for Developer ID builds, preserving their entitlements
- ad-hoc signs and verifies the complete app when no `CODESIGN_IDENTITY` is supplied
- fails an official `ORBIT_RELEASE_BUILD=1` build if its public key or HTTPS feed is missing
- creates `dist/Orbit.app.zip`

For Developer ID distribution later, set `CODESIGN_IDENTITY` to the certificate name.

## Generate the appcast

After choosing the release tag, generate the signed feed entry:

```bash
SPARKLE_PRIVATE_KEY_FILE="$HOME/.config/orbit-release/sparkle-private.key" \
RELEASE_TAG=v1.1.0 \
./scripts/generate-update-appcast.sh \
  dist/Orbit.app.zip \
  website/appcast.xml
```

Then:

1. Create the matching GitHub release, for example `v1.1.0`.
2. Upload `dist/Orbit.app.zip` without renaming it.
3. Commit and deploy `website/appcast.xml` through GitHub Pages.
4. Test **Settings → General → Check for Updates…** from an older Orbit build.

The appcast script accepts the private key only through `SPARKLE_PRIVATE_KEY_FILE`. It rejects symlinks, files not owned by the current user, and files readable by group or other users. It also derives the public key and verifies that it matches `SUPublicEDKey` in the archived app before signing.

## Tests

Run unit tests:

```bash
swift test
```

Run the real macOS integration test:

```bash
./scripts/test-macos-app-features.sh
```

The integration script uses a temporary key and a unique temporary app. It verifies that:

- the app can register and unregister itself using `SMAppService.mainApp`
- the update ZIP has a valid EdDSA signature
- Sparkle discovers and downloads a localhost update
- Sparkle replaces build `9000` with build `9001`
- the replaced app still has a valid ad-hoc code signature

It removes the temporary app and private key afterward.

## First update-enabled release

Users on versions released before Sparkle was embedded must install the first update-enabled release manually. Once that release is installed, later releases can use **Install and Relaunch** inside Orbit.
