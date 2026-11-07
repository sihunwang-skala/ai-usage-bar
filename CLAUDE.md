# AI Usage Bar — 개발 메모

## 개요
macOS 메뉴바 앱(Swift 6, SwiftPM, macOS 13+). Claude / Codex(ChatGPT)의 5시간·주간 잔량을 모델 토큰 소모 없이 표시하고, 임계치 알림을 보낸다.
- 빌드: `./build-app.sh` → `dist/AIUsageBar.app`. 설치·재시작: `./install.sh`(LaunchAgent `com.aiusagebar.app`).
- 서명: `./setup-signing.sh`로 이 Mac 전용 인증서를 한 번 만들면 빌드해도 macOS 권한(화면 기록·손쉬운 사용)이 유지된다. 없으면 ad-hoc 서명이라 빌드마다 권한이 풀린다.
- 알림은 .app 번들로 실행해야 동작한다. 로그: `~/Library/Logs/AIUsageBar/ai-usage-bar.log`.

## 구조
- `Claude/ClaudeOAuthUsageReader.swift`: 사용량 API(`/api/oauth/usage`, 비공식). 토큰은 `~/.claude/.credentials.json` 또는 키체인 `Claude Code-credentials`. 만료되면 refresh token으로 갱신해 같은 곳에 다시 저장한다. **사용자가 동의한 경우에만** 동작(`PrivacyPreferences`).
- `Combined/CombinedStatusController.swift`: 메뉴바 UI·메뉴·갱신 타이머. 실시간 조회는 최소 2분 간격, 429면 15분 쉼.
- `Claude/ClaudeWindowFocuser.swift`: 알림 클릭 시 해당 Claude 세션 창이 있는 Space로 이동(번호 단축키 점프 + 필요하면 ^←/^→), Claude "새 창" 메뉴 누르기. 권한: 화면 기록(창 제목), 손쉬운 사용(키 입력).
- `IconClickAction.swift`: 메뉴바 아이콘 클릭 시 열 곳(웹/데스크톱) 선택지. 메뉴 "아이콘 클릭 동작".
- `Localization.swift`: `tr(영어, 한국어)`. 시스템 언어가 한국어일 때만 한국어, 그 외 영어. 메뉴 "언어 / Language"에서 바꿈.
- `PrivacyPreferences.swift`, `NotificationPreferences.swift`: 동의·알림 설정.

## 알림 훅 연동 (선택)
Claude Code 훅 스크립트가 아래 두 가지로 이 앱과 연동할 수 있다(스크립트 자체는 저장소에 없다).
- 클릭 주소: `aiusagebar://claude-session?id=<Desktop 세션 ID(local_…)>` → 그 세션이 열린 창이 있는 Space로 이동.
- 설정값: `defaults read com.aiusagebar.app taskNotificationSource` 가 `claude`면 훅은 알림을 보내지 않는다(Claude 자체 알림과 중복 방지).

## 알아둘 점
- 사용량 API와 Space 전환(CGS·단축키 합성)은 비공식·비공개 방식이라 macOS/Claude 업데이트로 깨질 수 있다.
- 한 번 겪은 함정: 앱 프로세스가 launchd 밖에서 떠 있으면 `install.sh`가 새 빌드로 교체하지 못한다. 중복 방지(`AppDelegate`)가 있다.
- 법적 고지는 README 하단(라이선스·상표·면책)에 있다. 라이선스: PolyForm Noncommercial 1.0.0.
