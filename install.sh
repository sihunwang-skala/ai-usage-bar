#!/bin/zsh
# AI Usage Bar를 빌드해서 /Applications에 설치하고, 로그인 시 자동 실행되도록 등록합니다.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="AI Usage Bar.app"
DEST="/Applications/$APP_NAME"
LABEL="com.aiusagebar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/AIUsageBar"

echo "==> 빌드"
./build-app.sh

echo "==> /Applications에 설치"
rm -rf "$DEST"
cp -R "dist/AIUsageBar.app" "$DEST"

echo "==> 로그 디렉터리 준비"
mkdir -p "$LOG_DIR"

echo "==> LaunchAgent 등록"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/AIUsageBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/ai-usage-bar.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/ai-usage-bar.err.log</string>
</dict>
</plist>
PLIST_EOF

uid=$(id -u)
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$PLIST"
launchctl kickstart -k "gui/$uid/$LABEL"

echo "==> 설치 완료: $DEST"
echo "    로그: $LOG_DIR"
echo "    끄려면: ./uninstall.sh"
