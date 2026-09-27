# AI Usage Bar 설치 안내

macOS 메뉴 막대에서 Claude/Codex 사용량을 보여주는 앱입니다. 모델에 프롬프트를 보내지 않아
토큰을 전혀 소모하지 않습니다.

## 1. 필요 조건

- macOS 13 이상
- [Claude Code CLI](https://docs.claude.com/claude-code) 설치 + 로그인
  ```bash
  claude auth status
  ```
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

Apple Developer 정식 서명이 아니라 ad-hoc 서명이라, macOS가 처음 실행 시 아래처럼 경고를
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
- 알림 권한을 묻는 팝업도 뜰 수 있습니다 — 사용률 임계치(25/75/80/90%) 알림을 받으려면
  허용해 주세요.

## 5. 제거

```bash
cd ai-usage-bar
./uninstall.sh
```

## 문제가 있을 때

- 메뉴 막대에 안 보임: `ps aux | grep "[A]IUsageBar"`, `launchctl print gui/$(id -u)/com.aiusagebar.app`
- 숫자가 `—`로 뜸: 위 1번의 로그인 확인 명령을 다시 실행해 보세요.
- 그 외에는 [README](README.md)의 문제 해결 섹션을 참고하세요.
