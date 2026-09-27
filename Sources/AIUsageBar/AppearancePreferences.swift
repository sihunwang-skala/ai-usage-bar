import AppKit

/// 5시간/주간 숫자 색상을 사용자가 고를 수 있게 저장한다.
enum AppearancePreferences {
    private static let fiveHourColorKey = "fiveHourColor"
    private static let weeklyColorKey = "weeklyColor"

    static var fiveHourColor: NSColor {
        get { loadColor(key: fiveHourColorKey) ?? .systemOrange }
        set { saveColor(newValue, key: fiveHourColorKey) }
    }

    static var weeklyColor: NSColor {
        get { loadColor(key: weeklyColorKey) ?? .systemTeal }
        set { saveColor(newValue, key: weeklyColorKey) }
    }

    private static func loadColor(key: String) -> NSColor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private static func saveColor(_ color: NSColor, key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
