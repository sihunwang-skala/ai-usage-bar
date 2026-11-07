import Foundation

/// 앱 표시 언어. 기본은 시스템 언어를 따르고, 한국어일 때만 한국어, 그 외 모든 언어는 영어로 보여준다.
enum AppLanguage: String {
    case system, english, korean
}

enum Localization {
    private static let key = "appLanguage"

    static var preference: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static var isKorean: Bool {
        switch preference {
        case .korean: return true
        case .english: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("ko") == true
        }
    }

    static var locale: Locale { Locale(identifier: isKorean ? "ko_KR" : "en_US") }
}

/// 영어를 기본으로 하고, 한국어 설정일 때만 한국어를 쓴다.
func tr(_ english: String, _ korean: String) -> String {
    Localization.isKorean ? korean : english
}
