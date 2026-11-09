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

    private static let claudeTokenRenewalKey = "claudeTokenRenewal"

    /// 만료된 Claude Code 로그인을 이 앱이 대신 갱신해 Claude Code 저장소에 다시 써도 되는지. 기본 꺼짐.
    /// 갱신하면 refresh token이 바뀌므로 위 동의와 따로 묻는다.
    static var claudeTokenRenewal: Bool {
        get { UserDefaults.standard.bool(forKey: claudeTokenRenewalKey) }
        set { UserDefaults.standard.set(newValue, forKey: claudeTokenRenewalKey) }
    }

    /// 갱신 허용 여부를 묻는다. 허용하면 true.
    @discardableResult
    static func askClaudeTokenRenewal() -> Bool {
        let alert = NSAlert()
        alert.messageText = tr("Renew expired sign-in automatically?", "만료된 로그인을 자동으로 갱신할까요?")
        alert.informativeText = tr("""
        Claude Code's sign-in expires every few hours. If you don't open Claude Code for a while, live lookups pause.

        If you allow it:
        • AI Usage Bar renews it when it expires
        • The renewed sign-in is saved to the same place Claude Code keeps it

        Please note:
        • This changes Claude Code's own sign-in. If saving fails, run `claude auth login` again
        • This is an unofficial tool and may be outside Anthropic's terms. Please check them first

        It is off by default.
        """, """
        Claude Code 로그인은 몇 시간마다 만료돼요. 한동안 Claude Code를 열지 않으면 실시간 조회가 멈춰요.

        허용하면
        • 만료됐을 때 AI Usage Bar가 대신 갱신해요
        • 갱신된 로그인을 Claude Code가 쓰는 같은 곳에 다시 저장해요

        알아 두세요
        • Claude Code의 로그인 자체가 바뀌어요. 저장에 실패하면 `claude auth login`으로 다시 로그인해야 해요
        • 비공식 도구라 Anthropic 약관 밖일 수 있어요. 켜기 전에 약관을 확인해 주세요

        기본값은 꺼짐이에요.
        """)
        alert.addButton(withTitle: tr("Keep off", "켜지 않음"))
        alert.addButton(withTitle: tr("Allow renewal", "갱신 허용"))
        NSApp.activate(ignoringOtherApps: true)
        let allowed = alert.runModal() == .alertSecondButtonReturn
        claudeTokenRenewal = allowed
        return allowed
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
        // 기본(엔터) 버튼은 "허용 안 함"이다. 로그인 정보를 쓰는 기능은 사용자가 직접 눌러야만 켜진다.
        alert.addButton(withTitle: tr("No thanks", "허용 안 함"))
        alert.addButton(withTitle: tr("Allow", "허용"))
        NSApp.activate(ignoringOtherApps: true)
        let allowed = alert.runModal() == .alertSecondButtonReturn
        claudeTokenConsent = allowed
        return allowed
    }
}
