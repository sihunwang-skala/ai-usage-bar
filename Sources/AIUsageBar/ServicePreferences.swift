import Foundation

/// 사용자가 어떤 서비스(Claude/Codex)를 추적할지 저장한다. 둘 다 설치·로그인되어 있어도
/// 실제로 안 쓰는 서비스까지 "100/100"으로 표시되면 지저분하므로, 로그인 여부와는 별개로
/// 사용자가 직접 켜고 끌 수 있게 한다.
enum ServicePreferences {
    private static let hasConfiguredKey = "hasConfiguredServices"
    private static let claudeEnabledKey = "claudeServiceEnabled"
    private static let codexEnabledKey = "codexServiceEnabled"

    static var hasConfigured: Bool {
        UserDefaults.standard.bool(forKey: hasConfiguredKey)
    }

    static var claudeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: claudeEnabledKey) == nil ? true : UserDefaults.standard.bool(forKey: claudeEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: claudeEnabledKey) }
    }

    static var codexEnabled: Bool {
        get { UserDefaults.standard.object(forKey: codexEnabledKey) == nil ? true : UserDefaults.standard.bool(forKey: codexEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: codexEnabledKey) }
    }

    static func markConfigured() {
        UserDefaults.standard.set(true, forKey: hasConfiguredKey)
    }
}
