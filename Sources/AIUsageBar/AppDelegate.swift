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
        alert.messageText = "Which service(s) do you want to track?"
        alert.informativeText = "Choose what to show in the menu bar. You can change this anytime from the menu."
        alert.addButton(withTitle: "Both")
        alert.addButton(withTitle: "Claude Only")
        alert.addButton(withTitle: "Codex Only")
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
