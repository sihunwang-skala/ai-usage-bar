import UserNotifications

/// 사용률이 특정 임계치 위로 처음 올라갈 때 한 번씩 macOS 알림을 보냅니다.
/// 창(5시간/주간)이 갱신되어 사용률이 모든 임계치 아래로 다시 떨어지면 다음 상승에 대비해 재무장합니다.
///
/// UNUserNotificationCenter를 쓰므로 앱이 정식 .app 번들(Info.plist의 CFBundleIdentifier 포함)로
/// 실행되어야 한다 — raw 커맨드라인 실행파일로 직접 돌리면 알림이 등록되지 않는다.
final class ThresholdNotifier {
    private var lastNotifiedThreshold: [String: Int] = [:]

    func check(serviceName: String, windowLabel: String, usedPercent: Int) {
        let thresholds = NotificationPreferences.thresholds
        let key = "\(serviceName)-\(windowLabel)"
        guard let crossed = thresholds.last(where: { usedPercent >= $0 }) else {
            lastNotifiedThreshold.removeValue(forKey: key)
            return
        }
        if let previous = lastNotifiedThreshold[key], previous >= crossed { return }
        lastNotifiedThreshold[key] = crossed
        notify(
            title: "\(serviceName) 사용량 알림",
            message: "\(windowLabel) 사용량이 \(usedPercent)%에 도달했어요"
        )
    }

    private func notify(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = Self.resolveSound(named: NotificationPreferences.soundName)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    static func resolveSound(named name: String) -> UNNotificationSound? {
        switch name {
        case NotificationPreferences.defaultSoundName: return .default
        case NotificationPreferences.noSoundName: return nil
        default: return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
        }
    }
}
