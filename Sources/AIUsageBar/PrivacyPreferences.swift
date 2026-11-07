import AppKit

/// 사용자의 동의가 필요한 기능의 선택을 저장한다.
@MainActor
enum PrivacyPreferences {
    private static let claudeTokenConsentKey = "claudeTokenConsent"

    /// Claude Code의 로그인 토큰을 읽어 Anthropic 사용량 서버에 보내도 되는지. 한 번도 안 물었으면 nil.
    static var claudeTokenConsent: Bool? {
        get { UserDefaults.standard.object(forKey: claudeTokenConsentKey) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: claudeTokenConsentKey) }
    }

    /// 현재 새로고침 주기(초). 메뉴에서 고른 값이다.
    private static var refreshSeconds: Int {
        let stored = UserDefaults.standard.double(forKey: "refreshIntervalSeconds")
        return Int(stored > 0 ? stored : 60)
    }

    private static func intervalText(_ seconds: Int) -> String {
        if seconds < 60 { return tr("\(seconds) seconds", "\(seconds)초") }
        return tr("\(seconds / 60) min", "\(seconds / 60)분")
    }

    /// 동의 창을 띄우고 결과를 저장한다. 허용하면 true.
    @discardableResult
    static func askClaudeTokenConsent() -> Bool {
        let every = intervalText(refreshSeconds)
        let alert = NSAlert()
        alert.messageText = tr("Show Claude usage in real time?", "Claude 사용량을 실시간으로 볼까요?")
        alert.informativeText = tr("""
        If you allow it, AI Usage Bar can show your Claude usage more accurately and faster. It checks every \(every) (you can change this in the menu; live lookups are spaced at least 2 minutes apart to go easy on the server).

        To do this, it uses the sign-in Claude Code already keeps on your Mac and only talks to Anthropic's usage service. Nothing is sent anywhere else or stored separately.

        Prefer not to? That's perfectly fine. Your usage still shows, based on the usage records Claude Desktop and Claude Code leave on your Mac, and it is re-checked every \(every) too. Those records update when you use the two apps, so numbers can lag a little if you haven't used them for a while.

        You can change this anytime from the menu. This is an unofficial tool, so it's also worth a quick look at Anthropic's terms.
        """, """
        허용해 주시면 Claude 사용량을 더 정확하고 빠르게 보여드려요. 메뉴에서 정한 주기(지금은 \(every)마다)로 확인하고, 서버에 부담이 가지 않도록 실시간 조회는 최소 2분 간격으로 해요.

        이를 위해 Claude Code가 이 Mac에 이미 저장해 둔 로그인 정보를 사용해서 Anthropic의 사용량 서비스에만 요청해요. 다른 곳에 보내거나 따로 저장하지 않아요.

        허용하지 않으셔도 괜찮아요. Claude Desktop과 Claude Code가 이 Mac에 남기는 사용량 기록으로 계속 표시하고, 같은 주기(\(every)마다)로 다시 확인해요. 이 기록은 두 앱을 쓸 때 갱신돼서, 한동안 쓰지 않았다면 조금 늦게 반영될 수 있어요.

        설정은 메뉴에서 언제든 바꿀 수 있어요. 이 앱은 비공식 도구이니 Anthropic 이용약관도 한 번 살펴봐 주세요.
        """)
        alert.addButton(withTitle: tr("Allow", "허용"))
        alert.addButton(withTitle: tr("No thanks", "허용 안 함"))
        NSApp.activate(ignoringOtherApps: true)
        let allowed = alert.runModal() == .alertFirstButtonReturn
        claudeTokenConsent = allowed
        return allowed
    }
}
