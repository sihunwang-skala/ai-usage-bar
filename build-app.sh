#!/bin/zsh
# release 바이너리를 빌드하고 dist/AIUsageBar.app 번들로 조립합니다.
set -euo pipefail
cd "${0:A:h}"

echo "==> swift build -c release"
swift build -c release

APP="dist/AIUsageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/AIUsageBar" "$APP/Contents/MacOS/AIUsageBar"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 로컬 인증서(./setup-signing.sh)가 있으면 그걸로 서명해 빌드가 바뀌어도 macOS 권한이 유지되게 한다.
SIGN_ID="AI Usage Bar Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "==> codesign ($SIGN_ID)"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "==> ad-hoc codesign (권한이 빌드마다 풀림: ./setup-signing.sh 실행 권장)"
    codesign --force --deep --sign - "$APP"
fi

echo "==> done: $APP"
