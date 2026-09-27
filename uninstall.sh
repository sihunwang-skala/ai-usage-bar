#!/bin/zsh
# AI Usage Bar의 자동 실행을 끄고 /Applications에서 제거합니다.
set -euo pipefail

LABEL="com.aiusagebar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/AI Usage Bar.app"

uid=$(id -u)
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP"

echo "==> 제거 완료"
