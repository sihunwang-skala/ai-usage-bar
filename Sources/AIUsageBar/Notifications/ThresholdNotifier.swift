@preconcurrency import UserNotifications

/// 사용률이 특정 임계치 위로 처음 올라갈 때 한 번씩 macOS 알림을 보냅니다.
/// 창(5시간/주간)이 갱신되어 사용률이 모든 임계치 아래로 다시 떨어지면 다음 상승에 대비해 재무장합니다.
///
/// UNUserNotificationCenter를 쓰므로 앱이 정식 .app 번들(Info.plist의 CFBundleIdentifier 포함)로
/// 실행되어야 한다 — raw 커맨드라인 실행파일로 직접 돌리면 알림이 등록되지 않는다.
final class ThresholdNotifier: @unchecked Sendable, UsageNotifying {
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
            title: tr("\(serviceName) usage alert", "\(serviceName) 사용량 알림"),
            message: tr("Your \(windowLabel) usage reached \(usedPercent)%", "\(windowLabel) 사용량이 \(usedPercent)%에 도달했어요"),
            serviceName: serviceName
        )
    }

    private var lastPreResetKey: [String: Date] = [:]

    /// 5시간 창 리셋이 가까운데 잔량이 충분하면 리셋당 한 번 알린다.
    /// 주간 잔량이 기준 아래면(5시간 창이 남아도 못 쓰므로) 알리지 않고, 방해 금지 시간에도 보내지 않는다.
    func checkPreReset(serviceName: String, resetsAt: Date?, fiveHourRemaining: Int, weeklyRemaining: Int?) {
        guard NotificationPreferences.preResetEnabled, let resetsAt else { return }
        let now = Date()
        let lead = TimeInterval(NotificationPreferences.preResetLeadMinutes * 60)
        guard resetsAt > now, resetsAt.timeIntervalSince(now) <= lead else { return }
        let minimum = NotificationPreferences.preResetMinRemaining
        guard fiveHourRemaining >= minimum, (weeklyRemaining ?? 100) >= minimum else { return }
        guard !NotificationPreferences.isQuietNow(now) else { return }
        // 같은 리셋(시각이 몇 초 흔들려도 같은 것)이면 한 번만.
        if let previous = lastPreResetKey[serviceName], abs(previous.timeIntervalSince(resetsAt)) < 600 { return }
        lastPreResetKey[serviceName] = resetsAt
        let minutes = max(1, Int(resetsAt.timeIntervalSince(now) / 60))
        notify(
            title: tr("\(serviceName) usage resets soon", "\(serviceName) 사용량이 곧 리셋돼요"),
            message: tr("5-hour window resets in about \(minutes) min with \(fiveHourRemaining)% left. Using it now makes the most of it.",
                        "5시간 창이 약 \(minutes)분 뒤 리셋되고 \(fiveHourRemaining)%가 남아 있어요. 지금 쓰면 알뜰해요.") + CoachPreferences.tasksSuffix,
            serviceName: serviceName
        )
    }

    func notify(title: String, message: String, serviceName: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = Self.resolveSound(named: NotificationPreferences.soundName)
        if let serviceName { content.userInfo["service"] = serviceName }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func sendTest(completion: @escaping @Sendable (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.notify(title: tr("AI Usage Bar test notification", "AI Usage Bar 알림 테스트"), message: tr("Usage alerts are working.", "사용량 알림이 정상적으로 표시돼요."))
                completion(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        self.notify(title: tr("AI Usage Bar test notification", "AI Usage Bar 알림 테스트"), message: tr("Usage alerts are working.", "사용량 알림이 정상적으로 표시돼요."))
                    }
                    completion(granted)
                }
            case .denied:
                completion(false)
            @unknown default:
                completion(false)
            }
        }
    }

    static func resolveSound(named name: String) -> UNNotificationSound? {
        switch name {
        case NotificationPreferences.defaultSoundName: return .default
        case NotificationPreferences.noSoundName: return nil
        default: return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
        }
    }
}
