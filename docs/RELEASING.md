# Publishing a release

Releases are built locally on a Mac. Signing keys and notarization credentials
stay in the maintainer's Keychain; none belong in Git or public CI logs.

## Build and package

Install Xcode with the macOS SDK and a valid Developer ID Application certificate.
Update `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist` before a new version.

```sh
swift test
./scripts/release.sh
```

The script builds a Universal 2 app (arm64 + x86_64), enables Hardened Runtime,
uses a secure Developer ID timestamp, and produces:

- `dist/Gauge-macOS-universal.dmg` — app plus an Applications shortcut
- `dist/Gauge-macOS-universal.zip` — app archive
- `dist/SHA256SUMS.txt` — SHA-256 checksums

`GAUGE_SIGN_IDENTITY` can select a specific Developer ID certificate. If omitted,
the build selects an installed valid Developer ID Application identity. Local
development builds still support ad-hoc signing through `scripts/build.sh`.

## Optional Apple notarization

Use an existing `notarytool` Keychain profile, or create one interactively using
Apple's documented `xcrun notarytool store-credentials` flow. Do not put passwords
or API keys in shell history, this repository, or issue reports.

```sh
GAUGE_NOTARY_PROFILE="your-existing-profile-name" ./scripts/release.sh
```

The script submits and verifies the app, staples its ticket, then packages,
submits, and staples the DMG. A notarization failure stops the release build.
Without a profile, it creates signed artifacts and includes the first-launch
instructions for a build that has not been notarized.

Reference: [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Verify and publish

Inspect the app, DMG contents, and checksums. Confirm the app has both architectures:

```sh
lipo -archs dist/Gauge.app/Contents/MacOS/Gauge
codesign --verify --deep --strict dist/Gauge.app
codesign --verify --strict dist/Gauge-macOS-universal.dmg
cd dist && shasum -a 256 -c SHA256SUMS.txt
```

Commit the source, tag that commit, and upload only the three intended assets:

```sh
git tag v1.1.0
git push origin main v1.1.0
gh release create v1.1.0 --verify-tag --title "Gauge v1.1.0" \
  --notes-file .build/release-notes.md \
  dist/Gauge-macOS-universal.dmg dist/Gauge-macOS-universal.zip dist/SHA256SUMS.txt
```

Release notes must state whether that release was notarized. Keep these asset
names stable so the README's `/releases/latest/download/…` links keep working.
Never attach local profiles, usage data, build logs, signing material, or private
screenshots to a release.
