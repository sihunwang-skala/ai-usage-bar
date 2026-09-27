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

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
