#!/bin/zsh
# AI Usage Bar를 빌드해서 /Applications에 설치하고, 로그인 시 자동 실행되도록 등록합니다.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="AI Usage Bar.app"
DEST="/Applications/$APP_NAME"
LABEL="com.aiusagebar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/AIUsageBar"

echo "==> 필요 도구 확인"
if ! xcode-select -p &>/dev/null || ! command -v swift &>/dev/null; then
    echo ""
    echo "  Xcode Command Line Tools가 설치돼 있지 않아요."
    echo "  아래 명령을 먼저 실행하고, 설치 창이 끝나면 이 스크립트를 다시 실행해주세요."
    echo ""
    echo "    xcode-select --install"
    echo ""
    exit 1
fi
if ! command -v claude &>/dev/null && ! command -v codex &>/dev/null; then
    echo ""
    echo "  ⚠︎  Claude Code CLI, Codex CLI 둘 다 안 보여요. 이 앱은 둘 중 하나가"
    echo "     설치·로그인 돼 있어야 사용량을 보여줄 수 있어요 (설치는 계속 진행합니다)."
    echo ""
fi

echo "==> 빌드"
./build-app.sh

echo "==> /Applications에 설치"
rm -rf "$DEST"
cp -R "dist/AIUsageBar.app" "$DEST"

echo "==> 격리 속성 제거 (macOS '확인되지 않은 개발자' 경고 방지)"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

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
sleep 0.5
# 방금 bootout한 직후라 launchd가 아직 정리 중이면 bootstrap이 가끔
# "Input/output error"로 실패한다 — 한 번 더 시도하면 대부분 해결된다.
if ! launchctl bootstrap "gui/$uid" "$PLIST" 2>/dev/null; then
    sleep 1.5
    launchctl bootstrap "gui/$uid" "$PLIST"
fi
launchctl kickstart -k "gui/$uid/$LABEL"

echo "==> 설치 완료: $DEST"
echo "    로그: $LOG_DIR"
echo "    끄려면: ./uninstall.sh"
