# AI Usage Bar 설치 안내

macOS 메뉴 막대에서 Claude/Codex 사용량을 보여주는 앱입니다. 모델에 프롬프트를 보내지 않아
모델 토큰을 소모하지 않습니다. (비용·위험이 전혀 없다는 뜻은 아닙니다. README의 "Accuracy and limitations"를 읽어 주세요.)

## 1. 필요 조건

- macOS 13 이상
- Claude Desktop 또는 [Claude Code CLI](https://docs.claude.com/claude-code) 설치 + 로그인
  ```bash
  claude auth status
  ```
  (Claude 실시간 조회는 처음 실행할 때 동의해야만 켜져요. 동의하지 않아도 로컬 기록으로 표시해요.)
- [Codex CLI](https://github.com/openai/codex) 설치 + 로그인
  ```bash
  codex login status
  ```
- Xcode Command Line Tools (없다면 `xcode-select --install`)

> 둘 중 하나만 쓰셔도 됩니다. 처음 실행할 때 어떤 서비스를 추적할지 물어봅니다.

## 2. 설치

```bash
git clone https://github.com/sihunwang-skala/ai-usage-bar.git
cd ai-usage-bar
./install.sh
```

빌드 후 `/Applications/AI Usage Bar.app`으로 설치되고, 로그인할 때마다 자동으로 실행되도록
등록됩니다.

## 3. "확인되지 않은 개발자" 경고가 뜰 때

Apple Developer 정식 서명이 아니라 이 Mac에서 만든 서명(또는 ad-hoc 서명)이라, macOS가 처음 실행 시 아래처럼 경고를
띄울 수 있습니다.

1. **시스템 설정 → 개인정보 보호 및 보안**으로 이동
2. 아래쪽에 "AI Usage Bar이(가) 차단되었습니다" 같은 안내가 보이면 **"그래도 열기"** 클릭
3. 한 번 열면 이후로는 경고 없이 정상 실행됩니다

(또는 앱 아이콘을 우클릭 → "열기" → 경고창에서 "열기"를 눌러도 됩니다.)

## 4. 처음 실행

- 메뉴 막대에 아이콘이 나타나기 전에, "어떤 서비스를 추적할까요?" 팝업이 한 번 뜹니다.
  **둘 다 / Claude만 / Codex만** 중 고르면 됩니다.
- 나중에 마음이 바뀌면 메뉴(숫자 클릭 또는 우클릭) → **서비스 선택**에서 언제든 바꿀 수
  있습니다.
- 알림 권한을 묻는 팝업도 뜰 수 있습니다 — 사용률 임계치(기본 20/40/60/80/90/95%) 알림을 받으려면
  허용해 주세요.
- "Claude 사용량을 실시간으로 볼까요?" 창에서 기본(엔터) 선택은 **허용 안 함**입니다. 허용하면 Claude Code 로그인 정보를
  사용해 Anthropic 사용량 서버에 요청해요(비공식 주소라 약관 허용 여부가 불확실해요).

## 5. 업데이트와 제거

```bash
cd ai-usage-bar
git pull && ./install.sh     # 업데이트 (실행 중인 앱을 멈추고 교체한 뒤 다시 시작, 설정은 유지)
./uninstall.sh               # 제거 (설정·로그는 남김)
./uninstall.sh --purge       # 설정·로그까지 삭제
```

화면 기록·손쉬운 사용 권한은 시스템 설정 → 개인정보 보호 및 보안에서 직접 빼 주세요.

## 문제가 있을 때

- 메뉴 막대에 안 보임: `ps aux | grep "[A]IUsageBar"`, `launchctl print gui/$(id -u)/com.aiusagebar.app`
- 숫자가 `—`로 뜸: 위 1번의 로그인 확인 명령을 다시 실행해 보세요.
- 그 외에는 [README](README.md)의 문제 해결 섹션을 참고하세요.
