import AppKit

@MainActor
enum WebDashboardOpener {
    /// Claude Desktop understands claude://claude.ai paths and keeps settings
    /// navigation inside the app. Opening its usage screen also prompts Claude
    /// to refresh the local account-wide usage history that AI Usage Bar reads.
    static let claudeUsageURL = URL(string: "claude://claude.ai/new#settings/usage")!
    static let codexUsageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
    /// ChatGPT 프로젝트 목록 페이지. 아이콘을 누르면 기본 브라우저로 이 페이지를 연다.
    static let codexProjectURL = URL(string: "https://chatgpt.com/projects")!

    /// Opens an https URL in the user's default web browser even when a native AI app has
    /// registered itself as another capable handler for the same domain.
    static func open(_ url: URL) {
        guard url.scheme == "https" else {
            NSWorkspace.shared.open(url)
            return
        }
        let neutralWebURL = URL(string: "https://example.com")!
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: neutralWebURL) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: browserURL,
            configuration: configuration
        ) { _, _ in }
    }

    /// 앱을 앞으로 가져온다(마지막으로 쓰던 창이 그대로 나온다). 설치돼 있지 않으면 `fallback` URL을 연다.
    static func openApp(bundleIdentifier: String, fallback: URL) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            open(fallback)
            return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
