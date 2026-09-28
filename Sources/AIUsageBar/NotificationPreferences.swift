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

    /// 알림 소리 이름. "__default__"는 시스템 기본 알림음, "__none__"은 무음, 그 외에는
    /// /System/Library/Sounds에 있는 시스템 사운드 이름(Glass, Hero 등)이다.
    private static let soundKey = "notificationSoundName"
    static let defaultSoundName = "__default__"
    static let noSoundName = "__none__"
    static let systemSoundNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    static var soundName: String {
        get { UserDefaults.standard.string(forKey: soundKey) ?? defaultSoundName }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }
}
