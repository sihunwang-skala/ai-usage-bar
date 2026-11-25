import AppKit

/// Codex 알림을 눌렀을 때 Codex 앱 창이 열려 있는 Space(가상 데스크탑)로 이동한다.
/// 마지막으로 쓰던 Codex 창을 기억해 두었다가 그 창의 Space로 간다(현재 화면의 창을 끌어오지 않는다).
/// Space 전환은 Claude와 같은 비공개 CGS 방식이라 macOS 업데이트로 깨질 수 있다.
@MainActor
final class CodexWindowFocuser {
    static let shared = CodexWindowFocuser()

    static let bundleIdentifier = "com.openai.codex"

    private var lastWindowID: CGWindowID?
    private var observers: [NSObjectProtocol] = []

    private var codexApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first
    }

    func startTracking() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let bundleID = Self.bundleIdentifier
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == bundleID else { return }
                Task { @MainActor in self?.recordFrontWindow() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.codexApp?.isActive == true else { return }
                self?.recordFrontWindow()
            }
        })
        recordFrontWindow()
    }

    private func recordFrontWindow() {
        guard let pid = codexApp?.processIdentifier,
              let id = ClaudeWindowFocuser.claudeWindowIDs(pid: pid, onScreenOnly: true).first else { return }
        lastWindowID = id
    }

    /// 알림 클릭 시 호출. Codex가 꺼져 있으면 앱만 연다.
    func focus() {
        guard let app = codexApp else {
            WebDashboardOpener.openApp(bundleIdentifier: Self.bundleIdentifier, fallback: URL(string: "https://chatgpt.com/codex")!)
            return
        }
        let pid = app.processIdentifier
        let all = ClaudeWindowFocuser.claudeWindowIDs(pid: pid, onScreenOnly: false)
        let window = lastWindowID.flatMap { all.contains($0) ? $0 : nil } ?? all.first
        let space = window.flatMap { ClaudeWindowFocuser.spaceID(ofWindow: $0) }
        print("[focus] codex click window=\(window.map(String.init) ?? "nil") space=\(space.map(String.init) ?? "nil")")
        guard window != nil, space != nil else {
            // 창을 못 찾으면 예전처럼 앱을 연다(창이 없거나 Space를 알 수 없을 때).
            GPTIconTarget.current.perform()
            return
        }
        ClaudeWindowFocuser.bring(window: window, space: space, pid: pid)
    }
}
