import UserNotifications

/// 사용률이 특정 임계치 위로 처음 올라갈 때 한 번씩 macOS 알림을 보냅니다.
/// 창(5시간/주간)이 갱신되어 사용률이 모든 임계치 아래로 다시 떨어지면 다음 상승에 대비해 재무장합니다.
///
/// UNUserNotificationCenter를 쓰므로 앱이 정식 .app 번들(Info.plist의 CFBundleIdentifier 포함)로
/// 실행되어야 한다 — raw 커맨드라인 실행파일로 직접 돌리면 알림이 등록되지 않는다.
final class ThresholdNotifier {
    private let thresholds = [25, 75, 80, 90]
    private var lastNotifiedThreshold: [String: Int] = [:]

    func check(serviceName: String, windowLabel: String, usedPercent: Int) {
        let key = "\(serviceName)-\(windowLabel)"
        guard let crossed = thresholds.last(where: { usedPercent >= $0 }) else {
            lastNotifiedThreshold.removeValue(forKey: key)
            return
        }
        if let previous = lastNotifiedThreshold[key], previous >= crossed { return }
        lastNotifiedThreshold[key] = crossed
        notify(
            title: "\(serviceName) \(windowLabel) Usage Alert",
            message: "Usage is \(usedPercent)% (\(crossed)%+ threshold)"
        )
    }

    private func notify(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
