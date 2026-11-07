# AI Usage Bar

A macOS menu bar app that shows your **Claude** and **Codex (ChatGPT)** subscription usage —
5-hour and weekly limits — as one compact item, without spending a model token to check.

## Screenshots / 스크린샷

**Menu bar / 메뉴 막대** — Codex (left) and Claude (right): top = 5-hour remaining %, bottom = weekly remaining %.

![Menu bar: Codex 100/84, Claude 27/81](docs/menu-bar.png)

**Detail menu / 상세 메뉴** — reset times, last refresh, plan and model, refresh interval, service selection, colors, alert thresholds, and notification settings.

<img src="docs/detail-menu.png" alt="Detail menu with Claude and Codex usage, reset times, and settings" width="460">

Each service gets its own icon + two stacked numbers (top: 5-hour remaining %, bottom: weekly
remaining %). Only use one of the two services? Pick just that one on first launch (or change it
anytime from the menu) — no need to see a useless "100/100" block for a service you don't use.

> The numbers are **remaining percentages**. In the preview above, Codex has 56% / 13% left
> and Claude has 100% / 93% left. Orange is the 5-hour window; blue is the weekly window.

## Features

- Live 5-hour / weekly remaining percentage for both Claude and Codex
- Claude Desktop account-wide usage, with Claude Code's local monitor as a fallback
- Pick which service(s) to track on first launch, change anytime via the menu
- Configurable refresh interval (30s / 1min / 5min), picked from the menu
- Hover for exact reset date/time; click the menu for plan, model, and reasoning effort
- Native macOS notifications when usage crosses a configurable threshold, plus a built-in test action
- Keeps the Claude block visible while disconnected so setup is always reachable
- Launches at login and restarts itself if it crashes (LaunchAgent)
- No Dock icon — lives in the menu bar only

### Clicking

- **Click the Claude or GPT icon**: opens the place you choose under **Icon click action** in the menu. GPT: web Chat / Codex / Projects, or the ChatGPT desktop app (default: web Projects). Claude: a new Code or Chat window on the desktop you're looking at, a jump to your last window, or web Chat / Claude Code / Projects (default: new Code window)
- **Click the numbers, or right-click**: opens the detail menu (5h / weekly / refresh / quit)

## Why it never costs you a token

This app never sends a prompt or generates a response.

- **Codex**: talks to the official Codex CLI's `codex app-server --stdio` over JSON-RPC
  (`account/rateLimits/read`, `config/read`) and checks `codex login status` for login state.
- **Claude**: queries Anthropic's usage endpoint (`/api/oauth/usage`, undocumented) with the OAuth token
  Claude Code already stores, once every 60 seconds at most. Usage is per account, so the numbers are
  current no matter whether you used the web, Claude Desktop, or the terminal. If that fails, it falls
  back to Claude Desktop's local `plan-usage-history.json`, Claude Code's
  `~/.claude/state/usage-monitor.json`, and finally (only if values are stale, with Accessibility
  permission) the usage indicators Claude Desktop displays. The reason for any failure is shown in the
  menu's status line.

Neither path ever calls the model, so running this continuously costs zero tokens and doesn't
consume your 5-hour/weekly quota.

## Data and privacy

- Never reads browser cookies or conversation contents.
- **Claude live usage is opt-in.** On first launch the app asks for your consent. If you allow it, the app reads
  the Claude Code login token that is already stored on your Mac (`~/.claude/.credentials.json` or the macOS
  Keychain item `Claude Code-credentials`; macOS asks for permission) and sends it **only** to
  `api.anthropic.com` to read your usage. When the token expires, the app renews it and writes the renewed
  token back to the same place, so your Claude Code login keeps working. The token is not logged, and it is not
  stored anywhere else or sent anywhere else.
- If you do not allow it, the app only uses the local usage records that Claude Desktop and Claude Code already
  leave on your Mac, which can be a little behind. You can change your choice any time from the menu.
- Clicking a task-done notification switches to the desktop (Space) where that Claude session is open. It does
  this by reading Claude window titles (Screen Recording permission) and pressing the system's Space-switch
  keyboard shortcuts (Accessibility permission). Nothing is recorded, stored, or sent anywhere.
- Codex usage continues to come from the official local Codex app-server.

`codex app-server` is currently marked experimental by the Codex CLI; a future CLI protocol
change may require an app update.

## Requirements

- macOS 13+
- Claude Desktop signed in (Claude Code CLI is optional)
- [Codex CLI](https://github.com/openai/codex) installed and logged in (for the Codex block)
- Xcode Command Line Tools + Swift 6+ (only needed to build from source)

## Install

```bash
git clone https://github.com/sihunwang-skala/ai-usage-bar.git
cd ai-usage-bar
./install.sh
```

This builds a release binary, packages it as `AI Usage Bar.app`, copies it to `/Applications`,
and registers a LaunchAgent so it starts automatically at login. See
[INSTALL.md](INSTALL.md) for a step-by-step walkthrough, including how to get past the
"unidentified developer" Gatekeeper warning on first launch.

To uninstall:

```bash
./uninstall.sh
```

### Custom CLI locations

If `codex` or `claude` aren't at their default Homebrew paths, set an environment variable
before running the app (edit the LaunchAgent plist at
`~/Library/LaunchAgents/com.aiusagebar.app.plist` to add an `EnvironmentVariables` dict):

```
CODEX_PATH=/absolute/path/to/codex
CLAUDE_PATH=/absolute/path/to/claude
```

## Development

Quick iteration without the full `.app` bundle (menu bar UI works, but native notifications
require the bundled `.app` — see below):

```bash
./run.sh
```

Build the distributable `.app`:

```bash
./build-app.sh          # produces dist/AIUsageBar.app
```

Full rebuild + reinstall + restart the running LaunchAgent:

```bash
./install.sh
```

> Notifications use `UNUserNotificationCenter`, which requires the app to run from inside a
> real `.app` bundle with a `CFBundleIdentifier` (set in `Resources/Info.plist`). Running the
> raw binary via `run.sh` will not show notifications.

## Notification hook (optional)

If you use Claude Code hook scripts to send "task done" notifications, they can work with this app:

- **Jump to the right desktop.** Make the notification open `aiusagebar://claude-session?id=<Claude Desktop session id>`
  (the `local_…` id). AI Usage Bar then switches to the desktop (Space) where that session is open.
  This needs Screen Recording (to read window titles) and Accessibility (to press the Space-switch shortcuts).
  Turn on "Switch to Desktop N" in System Settings → Keyboard → Keyboard Shortcuts → Mission Control for one-step jumps;
  without it the app moves one desktop at a time.
- **Avoid double notifications.** The menu item **Task-done notifications** stores your choice. A hook can read it with
  `defaults read com.aiusagebar.app taskNotificationSource`; `claude` means "use Claude's own notifications, so don't send one".

The hook scripts themselves are not included in this repository.

## Troubleshooting

### Not showing up in the menu bar

```bash
ps aux | grep "[A]IUsageBar"
launchctl print gui/$(id -u)/com.aiusagebar.app
```

### A block shows `— —` or an old timestamp

- Claude: choose **Claude Desktop 최신 사용량 연결…**, grant Accessibility permission once,
  then choose it again. Without permission the app shows Claude's local history and marks old
  records in the detail menu. Stale values never trigger alerts.
- Codex: run `codex login status` to confirm login.

### No notifications

Choose **알림 테스트** from the app menu. If it reports that notifications are disabled, enable
System Settings → Notifications → AI Usage Bar. Notifications only work when running from the
installed `.app` bundle (see Development section above).

## License & Copyright

Copyright © 2026 Sihun Wang. All rights reserved.

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).

- **You may:** download and use this app for personal and other noncommercial purposes, and study or modify
  the source for your own noncommercial use.
- **You may not:** use it commercially, or sell it or repackage it as your own, without prior written permission
  from the author.
- Everything original to this project — source code, documentation, designs, the app icon, and the name
  "AI Usage Bar" — belongs to the author.

For commercial licensing, collaboration, or other inquiries, please contact the repository owner.

### Trademarks, logos, and third-party materials

- **Claude**, **Claude Code**, **Anthropic**, and their logos are trademarks of **Anthropic, PBC**.
  **ChatGPT**, **Codex**, **OpenAI**, and their logos are trademarks of **OpenAI**.
- The Claude and ChatGPT/Codex icons shown in the menu bar and in the screenshots are the
  **official logos and app icons of Anthropic and OpenAI**. They are used only to identify those services
  (nominative use). All rights to them belong to their respective owners. They are **not** covered by this
  project's license and remain subject to the owners' brand guidelines.
- The app itself does not bundle those icons. It reads them from your own installed Claude and Codex apps.
- This project is an independent, unofficial tool. It is **not affiliated with, endorsed by, or sponsored by**
  Anthropic or OpenAI.
- If a rights holder objects to the use of any logo or name, please contact the repository owner and it will be
  removed promptly.
- This project has no third-party code dependencies.

### Disclaimer

- The app relies on **undocumented endpoints and private macOS APIs** that can change or stop working at any time.
- Using your login token with an unofficial tool may not be permitted by the provider's terms of service.
  That is why the feature is opt-in. Please review Anthropic's and OpenAI's terms yourself. **You use this
  at your own risk and responsibility.**
- The software is provided "as is", without warranty of any kind, and the author is not liable for any damages
  (see the [LICENSE](LICENSE)).
- Usage numbers are for reference only and may differ from the official figures.

## 라이선스 및 저작권

Copyright © 2026 Sihun Wang. All rights reserved.

[PolyForm Noncommercial License 1.0.0](LICENSE)에 따라 배포됩니다.

- **가능한 것:** 개인적·비영리 목적으로 이 앱을 다운로드해 사용할 수 있고, 본인의 비영리 사용을 위해 소스를
  살펴보거나 수정할 수 있습니다.
- **불가능한 것:** 저작자의 사전 서면 허가 없이 상업적으로 이용하거나, 판매하거나, 자기 것처럼 다시 포장해
  배포할 수 없습니다.
- 소스 코드, 문서, 디자인, 앱 아이콘, "AI Usage Bar"라는 이름 등 이 프로젝트 고유의 결과물은 모두
  저작자의 것입니다.

상업적 라이선스, 협업 및 기타 문의는 저장소 소유자에게 연락해 주세요.

### 상표, 로고 및 제3자 자료

- **Claude**, **Claude Code**, **Anthropic** 및 관련 로고는 **Anthropic, PBC**의 상표이고, **ChatGPT**, **Codex**, **OpenAI** 및 관련 로고는 **OpenAI**의 상표입니다.
- 메뉴 막대와 스크린샷에 보이는 Claude와 ChatGPT/Codex 아이콘은 각각 Anthropic과 OpenAI의 **공식 로고 및 앱 아이콘**입니다. 해당 서비스를 구분하는 용도로만 사용했으며(지칭 목적의 사용), 모든 권리는 각 소유자에게 있습니다. 이 프로젝트의 라이선스 적용 대상이 **아니며** 각 소유자의 브랜드 가이드라인을 따릅니다.
- 앱 자체는 이 아이콘 파일을 포함하지 않고, 사용자의 컴퓨터에 설치된 Claude와 Codex 앱에서 읽어옵니다.
- 이 프로젝트는 독립적인 비공식 도구이며 Anthropic 또는 OpenAI와 **제휴, 후원, 승인 관계가 없습니다.**
- 권리자가 로고나 이름의 사용에 이의를 제기하면 저장소 소유자에게 연락해 주세요. 즉시 삭제하겠습니다.
- 이 프로젝트에는 서드파티 코드 의존성이 없습니다.

### 면책 조항

- 이 앱은 **비공식 엔드포인트와 macOS 비공개 API**에 의존하며, 언제든 바뀌거나 동작하지 않을 수 있습니다.
- 로그인 토큰을 비공식 도구에 쓰는 것은 서비스 제공자의 약관에서 허용되지 않을 수 있습니다. 그래서 이 기능은 사용자가 동의해야만 켜집니다. Anthropic과 OpenAI의 약관은 직접 확인해 주세요. **사용에 따른 위험과 책임은 사용자에게 있습니다.**
- 소프트웨어는 어떠한 보증 없이 "있는 그대로" 제공되며, 저작자는 어떠한 손해에 대해서도 책임지지 않습니다([LICENSE](LICENSE) 참고).
- 표시되는 사용량 수치는 참고용이며 공식 수치와 다를 수 있습니다.
