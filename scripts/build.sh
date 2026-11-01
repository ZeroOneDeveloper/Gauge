#!/bin/bash
set -euo pipefail
GAUGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$GAUGE_ROOT"
GAUGE_SWIFT_ARGS=(-c release)
case "${GAUGE_ARCH:-native}" in
    native) ;;
    universal) GAUGE_SWIFT_ARGS+=(--arch arm64 --arch x86_64) ;;
    arm64|x86_64) GAUGE_SWIFT_ARGS+=(--arch "$GAUGE_ARCH") ;;
    *) printf 'Unsupported GAUGE_ARCH: %s\n' "$GAUGE_ARCH" >&2; exit 1 ;;
esac
/usr/bin/swift build "${GAUGE_SWIFT_ARGS[@]}"
GAUGE_BIN_DIR="$(/usr/bin/swift build "${GAUGE_SWIFT_ARGS[@]}" --show-bin-path)"
GAUGE_APP="$GAUGE_ROOT/dist/Gauge.app"
/bin/mkdir -p "$GAUGE_APP/Contents/MacOS" "$GAUGE_APP/Contents/Resources"
/bin/cp "$GAUGE_BIN_DIR/Gauge" "$GAUGE_APP/Contents/MacOS/Gauge"
/bin/cp "$GAUGE_ROOT/Resources/Info.plist" "$GAUGE_APP/Contents/Info.plist"
/bin/cp "$GAUGE_ROOT/LICENSE" "$GAUGE_APP/Contents/Resources/LICENSE"
/bin/cp "$GAUGE_ROOT/THIRD_PARTY_NOTICES.md" "$GAUGE_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/bin/mkdir -p "$GAUGE_APP/Contents/Resources/ProviderIcons"
/bin/cp "$GAUGE_ROOT/Sources/Gauge/Resources/ProviderIcons/claude.svg" "$GAUGE_APP/Contents/Resources/ProviderIcons/claude.svg"
/bin/cp "$GAUGE_ROOT/Sources/Gauge/Resources/ProviderIcons/codex.svg" "$GAUGE_APP/Contents/Resources/ProviderIcons/codex.svg"
/bin/cp "$GAUGE_ROOT/Sources/Gauge/Resources/ProviderIcons/codex.pdf" "$GAUGE_APP/Contents/Resources/ProviderIcons/codex.pdf"
/usr/bin/swift "$GAUGE_ROOT/scripts/make-icon.swift" "$GAUGE_ROOT/.build/Gauge.iconset"
/usr/bin/iconutil -c icns "$GAUGE_ROOT/.build/Gauge.iconset" -o "$GAUGE_APP/Contents/Resources/AppIcon.icns"
# A stable signing identity lets Keychain keep the user's Always Allow decision
# across updates. Ad-hoc signatures identify just one specific binary hash.
GAUGE_SIGN_IDENTITY="${GAUGE_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Developer ID Application:/ && !/CSSMERR_/ {print $2; exit}')}"
GAUGE_SIGN_IDENTITY="${GAUGE_SIGN_IDENTITY:--}"
GAUGE_SIGN_OPTIONS=(--timestamp=none)
if [[ "${GAUGE_RELEASE:-0}" == "1" ]]; then
    if [[ "$GAUGE_SIGN_IDENTITY" == "-" ]]; then
        printf 'Release builds require a Developer ID Application signing identity.\n' >&2
        exit 1
    fi
    GAUGE_SIGN_OPTIONS=(--options runtime --timestamp)
fi
/usr/bin/codesign --force --sign "$GAUGE_SIGN_IDENTITY" --identifier kr.uniquegood.gauge "${GAUGE_SIGN_OPTIONS[@]}" "$GAUGE_APP"
printf '\nBuilt: %s\n' "$GAUGE_APP"
