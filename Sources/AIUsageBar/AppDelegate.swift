import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var combinedController: CombinedStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchAgent와 Finder/권한 창의 "다시 열기"가 겹치면 두 개가 뜬다. 먼저 떠 있던 쪽만 남긴다.
        let current = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != current && !$0.isTerminated }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if !ServicePreferences.hasConfigured {
            runFirstLaunchPicker()
        }
        if NotificationPreferences.taskSourceIfChosen == nil {
            runTaskNotificationPicker()
        }
        if PrivacyPreferences.claudeTokenConsent == nil {
            PrivacyPreferences.askClaudeTokenConsent()
        }
        ClaudeWindowFocuser.shared.startTracking()
        combinedController = CombinedStatusController()
        combinedController?.start()
    }

    /// Claude Code 훅 알림 클릭 → `aiusagebar://claude-session?id=local_…` → 그 세션이 열린 창으로 이동.
    func application(_ application: NSApplication, open urls: [URL]) {
        print("[focus] open urls=\(urls.map(\.absoluteString))")
        for url in urls where url.host == "claude-session" {
            guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { continue }
            ClaudeWindowFocuser.shared.focus(sessionID: id)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let service = response.notification.request.content.userInfo["service"] as? String
        Task { @MainActor in
            switch service {
            case "Claude": ClaudeWindowFocuser.shared.focus()
            case "Codex": GPTIconTarget.current.perform()
            default: break
            }
        }
        completionHandler()
    }

    /// Claude Desktop 알림을 켜 두었는지 한 번만 묻는다. macOS가 알림 설정을 읽게 해 주지 않아서 직접 묻는다.
    /// 켜 둠 → 작업 완료는 Claude가, AI Usage Bar는 사용량 임계치만. 꺼 둠 → AI Usage Bar가 작업 완료 알림도 보낸다.
    private func runTaskNotificationPicker() {
        let alert = NSAlert()
        alert.messageText = tr("Are Claude's own notifications turned on?", "Claude 알림을 켜 두셨나요?")
        alert.informativeText = tr("""
        If they're on: Claude sends the task-done notifications, and AI Usage Bar only sends usage alerts.
        If they're off: AI Usage Bar also sends the task-done notifications, and clicking one takes you to the desktop where that session is open.

        You can check this in System Settings → Notifications → Claude, and change your answer anytime from the "Task-done notifications" menu.
        """, """
        켜 두셨다면: 작업 완료 알림은 Claude가 보내고, AI Usage Bar는 사용량 알림만 보내요.
        꺼 두셨다면: AI Usage Bar가 작업 완료 알림도 보내고, 누르면 그 세션이 있는 데스크톱으로 이동해요.

        시스템 설정 → 알림 → Claude에서 확인할 수 있고, 메뉴의 "작업 완료 알림"에서 언제든 바꿀 수 있어요.
        """)
        alert.addButton(withTitle: tr("On", "켜 둠"))
        alert.addButton(withTitle: tr("Off", "꺼 둠"))
        NSApp.activate(ignoringOtherApps: true)
        NotificationPreferences.taskSource = alert.runModal() == .alertFirstButtonReturn
            ? NotificationPreferences.taskSourceClaude
            : NotificationPreferences.taskSourceUsageBar
    }

    /// 처음 실행할 때 어떤 서비스를 쓸지 물어본다. Claude/Codex를 둘 다 쓰는 사람도 있고
    /// 하나만 쓰는 사람도 있어서, 안 쓰는 쪽까지 "100/100"으로 표시되는 걸 막기 위함이다.
    private func runFirstLaunchPicker() {
        let alert = NSAlert()
        alert.messageText = tr("Which services should be tracked?", "어떤 서비스를 추적할까요?")
        alert.informativeText = tr("Choose what to show in the menu bar. You can change this anytime from the menu.", "메뉴 막대에 표시할 서비스를 고르세요. 나중에 메뉴에서 언제든 바꿀 수 있어요.")
        alert.addButton(withTitle: tr("Both", "둘 다"))
        alert.addButton(withTitle: tr("Claude only", "Claude만"))
        alert.addButton(withTitle: tr("Codex only", "Codex만"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ServicePreferences.claudeEnabled = true
            ServicePreferences.codexEnabled = true
        case .alertSecondButtonReturn:
            ServicePreferences.claudeEnabled = true
            ServicePreferences.codexEnabled = false
        default:
            ServicePreferences.claudeEnabled = false
            ServicePreferences.codexEnabled = true
        }
        ServicePreferences.markConfigured()
    }
}
