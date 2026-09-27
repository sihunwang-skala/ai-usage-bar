import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var combinedController: CombinedStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if !ServicePreferences.hasConfigured {
            runFirstLaunchPicker()
        }
        combinedController = CombinedStatusController()
        combinedController?.start()
    }

    /// 처음 실행할 때 어떤 서비스를 쓸지 물어본다. Claude/Codex를 둘 다 쓰는 사람도 있고
    /// 하나만 쓰는 사람도 있어서, 안 쓰는 쪽까지 "100/100"으로 표시되는 걸 막기 위함이다.
    private func runFirstLaunchPicker() {
        let alert = NSAlert()
        alert.messageText = "어떤 서비스를 추적할까요?"
        alert.informativeText = "메뉴 막대에 표시할 서비스를 고르세요. 나중에 메뉴에서 언제든 바꿀 수 있습니다."
        alert.addButton(withTitle: "둘 다")
        alert.addButton(withTitle: "Claude만")
        alert.addButton(withTitle: "Codex만")
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
