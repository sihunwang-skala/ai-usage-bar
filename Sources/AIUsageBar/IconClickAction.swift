import AppKit

/// 메뉴 막대의 GPT 아이콘을 눌렀을 때 어디를 열지. 메뉴의 "아이콘 클릭 동작"에서 고른다.
enum GPTIconTarget: String, CaseIterable {
    case webChat, webCodex, webProjects, desktopApp

    private static let key = "gptIconTarget"
    static var current: GPTIconTarget {
        get { GPTIconTarget(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .webProjects }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .webChat: tr("Web · Chat", "웹 · 채팅")
        case .webCodex: tr("Web · Codex", "웹 · Codex")
        case .webProjects: tr("Web · Projects", "웹 · 프로젝트")
        case .desktopApp: tr("Desktop app · ChatGPT / Codex", "데스크톱 앱 · ChatGPT / Codex")
        }
    }

    @MainActor func perform() {
        let chat = URL(string: "https://chatgpt.com/")!
        let codex = URL(string: "https://chatgpt.com/codex")!
        switch self {
        case .webChat: WebDashboardOpener.open(chat)
        case .webCodex: WebDashboardOpener.open(codex)
        case .webProjects: WebDashboardOpener.open(WebDashboardOpener.codexProjectURL)
        // 이 Mac에서는 ChatGPT 앱과 Codex 앱이 같은 앱(com.openai.codex) 하나다.
        case .desktopApp: WebDashboardOpener.openApp(bundleIdentifier: "com.openai.codex", fallback: chat)
        }
    }
}

/// 메뉴 막대의 Claude 아이콘을 눌렀을 때 어디를 열지. Claude에서 Codex에 해당하는 것은 Claude Code(코드 탭)다.
enum ClaudeIconTarget: String, CaseIterable {
    case webChat, webCode, webProjects, desktopCodeNewWindow, desktopChatNewWindow, desktopLastWindow

    private static let key = "claudeIconTarget"
    static var current: ClaudeIconTarget {
        get { ClaudeIconTarget(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .desktopCodeNewWindow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .webChat: tr("Web · Chat", "웹 · 채팅")
        case .webCode: tr("Web · Code", "웹 · 코드")
        case .webProjects: tr("Web · Projects", "웹 · 프로젝트")
        case .desktopCodeNewWindow: tr("Desktop app · Code (new window on this desktop)", "데스크톱 앱 · 코드 (현재 데스크톱에 새 창)")
        case .desktopChatNewWindow: tr("Desktop app · Chat (new window on this desktop)", "데스크톱 앱 · 채팅 (현재 데스크톱에 새 창)")
        case .desktopLastWindow: tr("Desktop app · Last used window", "데스크톱 앱 · 마지막으로 쓰던 창")
        }
    }

    @MainActor func perform() {
        switch self {
        case .desktopCodeNewWindow:
            ClaudeWindowFocuser.shared.openNewWindow(then: URL(string: "claude://code/new?source=desktop_action")!)
        case .desktopChatNewWindow:
            ClaudeWindowFocuser.shared.openNewWindow(then: URL(string: "claude://claude.ai/new?surface=chat&source=desktop_action")!)
        case .desktopLastWindow:
            ClaudeWindowFocuser.shared.focus()
        case .webChat: WebDashboardOpener.open(URL(string: "https://claude.ai/new")!)
        case .webCode: WebDashboardOpener.open(URL(string: "https://claude.ai/code")!)
        case .webProjects: WebDashboardOpener.open(URL(string: "https://claude.ai/projects")!)
        }
    }
}
