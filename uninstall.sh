#!/bin/zsh
# AI Usage Bar의 자동 실행을 끄고 /Applications에서 제거합니다.
#   ./uninstall.sh          앱과 LaunchAgent만 제거 (설정·로그는 남김)
#   ./uninstall.sh --purge  설정(UserDefaults)과 로그도 함께 삭제
# 시스템 권한(화면 기록·손쉬운 사용)은 앱이 지울 수 없으니 시스템 설정 → 개인정보 보호 및 보안에서 직접 빼 주세요.
# 이 앱은 키체인 항목이나 Claude/Codex 로그인 파일을 새로 만들지 않아서 지울 것이 없습니다.
set -euo pipefail

LABEL="com.aiusagebar.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/AI Usage Bar.app"
LOG_DIR="$HOME/Library/Logs/AIUsageBar"

uid=$(id -u)
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
# launchd 밖에서 떠 있는 복사본이 남아 있을 수 있다.
pkill -x AIUsageBar 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP"

if [[ "${1:-}" == "--purge" ]]; then
    defaults delete "$LABEL" 2>/dev/null || true
    rm -rf "$LOG_DIR"
    echo "==> 설정과 로그도 삭제했어요"
fi

echo "==> 제거 완료"
