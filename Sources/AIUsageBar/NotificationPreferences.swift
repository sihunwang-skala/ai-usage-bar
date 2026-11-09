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

    /// 작업 완료·확인 필요 알림을 누가 보낼지. Claude Code 훅(~/.claude/scripts)이 이 값을 읽는다.
    /// - "usagebar"(기본): 훅 알림을 보낸다. 눌러서 그 세션이 있는 데스크톱으로 이동한다. Claude 자체 알림은 끄는 걸 권한다.
    /// - "claude": Claude Desktop 자체 알림만 쓴다. 훅 알림은 보내지 않고 AI Usage Bar는 사용량 임계치 알림만 보낸다.
    private static let taskSourceKey = "taskNotificationSource"
    static let taskSourceUsageBar = "usagebar"
    static let taskSourceClaude = "claude"

    /// 한 번도 고른 적이 없으면 nil. 이때만 시작할 때 한 번 물어본다.
    static var taskSourceIfChosen: String? { UserDefaults.standard.string(forKey: taskSourceKey) }

    static var taskSource: String {
        get { UserDefaults.standard.string(forKey: taskSourceKey) ?? taskSourceUsageBar }
        set { UserDefaults.standard.set(newValue, forKey: taskSourceKey) }
    }

    // MARK: 리셋 전 알림
    // 5시간 창이 곧 리셋되는데 잔량이 많이 남았으면 "지금 쓰면 이득"이라고 한 번 알려 준다.
    private static let preResetEnabledKey = "preResetEnabled"
    private static let preResetLeadKey = "preResetLeadMinutes"
    private static let preResetMinKey = "preResetMinRemaining"

    static var preResetEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: preResetEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: preResetEnabledKey) }
    }
    /// 리셋 몇 분 전에 알릴지(기본 60).
    static var preResetLeadMinutes: Int {
        get { UserDefaults.standard.object(forKey: preResetLeadKey) as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: preResetLeadKey) }
    }
    /// 이 값(%) 이상 남았을 때만 알린다(기본 30).
    static var preResetMinRemaining: Int {
        get { UserDefaults.standard.object(forKey: preResetMinKey) as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: preResetMinKey) }
    }
    /// 방해 금지 시간대 목록(시 단위, 여러 개 가능). 비어 있으면 꺼짐.
    static var quietRanges: [(start: Int, end: Int)] {
        get {
            let raw = UserDefaults.standard.array(forKey: quietRangesKey) as? [[Int]] ?? []
            return raw.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        }
        set { UserDefaults.standard.set(newValue.map { [$0.start, $0.end] }, forKey: quietRangesKey) }
    }
    private static let quietRangesKey = "quietRanges"

    static func isQuietNow(_ date: Date = Date()) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return quietRanges.contains { r in
            r.start == r.end ? false : (r.start < r.end ? (hour >= r.start && hour < r.end) : (hour >= r.start || hour < r.end))
        }
    }
}
