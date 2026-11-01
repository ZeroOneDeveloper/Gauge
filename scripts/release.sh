#!/bin/bash
set -euo pipefail
GAUGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$GAUGE_ROOT"

GAUGE_SIGN_IDENTITY="${GAUGE_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Developer ID Application:/ && !/CSSMERR_/ {print $2; exit}')}"
if [[ -z "$GAUGE_SIGN_IDENTITY" || "$GAUGE_SIGN_IDENTITY" == "-" ]]; then
    printf 'A Developer ID Application certificate is required for release packaging.\n' >&2
    exit 1
fi
export GAUGE_SIGN_IDENTITY
export GAUGE_ARCH=universal
export GAUGE_RELEASE=1
"$GAUGE_ROOT/scripts/build.sh"

GAUGE_APP="$GAUGE_ROOT/dist/Gauge.app"
GAUGE_DMG="$GAUGE_ROOT/dist/Gauge-macOS-universal.dmg"
GAUGE_ZIP="$GAUGE_ROOT/dist/Gauge-macOS-universal.zip"
GAUGE_STAGE="$(/usr/bin/mktemp -d "$GAUGE_ROOT/.build/release-stage.XXXXXX")"
trap '/bin/rm -rf "$GAUGE_STAGE"' EXIT

notarize() {
    local artifact="$1"
    local report="$2"
    /usr/bin/xcrun notarytool submit "$artifact" --keychain-profile "$GAUGE_NOTARY_PROFILE" \
        --wait --timeout 20m --output-format json > "$report"
    if [[ "$(/usr/bin/plutil -extract status raw -o - "$report")" != "Accepted" ]]; then
        printf 'Notarization did not succeed. Inspect %s before publishing.\n' "$report" >&2
        exit 1
    fi
}

if [[ -n "${GAUGE_NOTARY_PROFILE:-}" ]]; then
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$GAUGE_APP" "$GAUGE_STAGE/notary-upload.zip"
    notarize "$GAUGE_STAGE/notary-upload.zip" "$GAUGE_ROOT/.build/notary-app.json"
    /usr/bin/xcrun stapler staple "$GAUGE_APP"
    /usr/bin/xcrun stapler validate "$GAUGE_APP"
    /bin/rm "$GAUGE_STAGE/notary-upload.zip"
fi

/usr/bin/ditto "$GAUGE_APP" "$GAUGE_STAGE/Gauge.app"
/bin/ln -s /Applications "$GAUGE_STAGE/Applications"
/bin/cat > "$GAUGE_STAGE/설치 방법 - Installation.txt" <<'INSTALL'
Gauge

1. Gauge.app을 Applications 폴더로 드래그하세요.
2. 응용 프로그램 폴더에서 Gauge를 실행하세요.
3. 계정 추가로 Claude / Codex 계정을 연결하세요.

Drag Gauge.app into Applications, then launch Gauge from Applications.
Use Add account to connect your Claude / Codex subscriptions.

Downloads and help: https://github.com/ZeroOneDeveloper/Gauge
INSTALL
if [[ -z "${GAUGE_NOTARY_PROFILE:-}" ]]; then
    /bin/cat >> "$GAUGE_STAGE/설치 방법 - Installation.txt" <<'INSTALL'

이 버전은 Developer ID로 서명했으며 Apple 공증은 아직 완료하지 않았습니다.
첫 실행이 차단되면 시스템 설정 > 개인정보 보호 및 보안에서 Gauge의
'확인 없이 열기(Open Anyway)'를 선택하세요.

This build is Developer ID signed but has not been notarized by Apple.
If first launch is blocked, use System Settings > Privacy & Security > Open Anyway.
INSTALL
fi

/usr/bin/hdiutil create -volname Gauge -srcfolder "$GAUGE_STAGE" -format UDZO -ov "$GAUGE_DMG"
/usr/bin/codesign --force --sign "$GAUGE_SIGN_IDENTITY" --timestamp "$GAUGE_DMG"
if [[ -n "${GAUGE_NOTARY_PROFILE:-}" ]]; then
    notarize "$GAUGE_DMG" "$GAUGE_ROOT/.build/notary-dmg.json"
    /usr/bin/xcrun stapler staple "$GAUGE_DMG"
    /usr/bin/xcrun stapler validate "$GAUGE_DMG"
    /usr/sbin/spctl --assess --type execute "$GAUGE_APP"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$GAUGE_APP" "$GAUGE_ZIP"
(
    cd "$GAUGE_ROOT/dist"
    /usr/bin/shasum -a 256 Gauge-macOS-universal.dmg Gauge-macOS-universal.zip > SHA256SUMS.txt
)
/usr/bin/codesign --verify --deep --strict "$GAUGE_APP"
/usr/bin/codesign --verify --strict "$GAUGE_DMG"
printf '\nRelease files:\n%s\n%s\n%s\n' "$GAUGE_DMG" "$GAUGE_ZIP" "$GAUGE_ROOT/dist/SHA256SUMS.txt"
