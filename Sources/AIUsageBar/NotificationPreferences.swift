import Foundation

/// 알림을 보낼 사용률 임계치 목록을 저장한다. 프리셋으로 고르거나 직접 입력할 수 있다.
enum NotificationPreferences {
    private static let thresholdsKey = "notificationThresholds"
    static let defaultThresholds = [20, 40, 60, 80, 90, 95]

    static var thresholds: [Int] {
        get {
            guard let stored = UserDefaults.standard.array(forKey: thresholdsKey) as? [Int] else {
                return defaultThresholds
            }
            return stored
        }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: thresholdsKey) }
    }
}
