import Foundation

/// 표시할 값이 지금 믿을 만한지. 믿을 수 없는 값은 숫자(특히 100%)로 보여 주지 않는다.
enum UsageFreshness: Equatable {
    /// 최근에 읽었고 같은 창(window)의 값이다.
    case fresh
    /// 오래됐거나, 이미 리셋된 창의 값이다. 마지막으로 알던 값일 뿐 지금 값이 아니다.
    case stale
    /// 언제 읽은 값인지 알 수 없거나 시각이 말이 안 된다.
    case unknown
}

enum UsageFreshnessPolicy {
    /// 이보다 오래된 기록은 stale.
    static let maxAge: TimeInterval = 30 * 60
    /// 기록 시각이 이보다 더 미래이면 시계가 어긋났거나 잘못된 값이라 unknown.
    static let maxFutureSkew: TimeInterval = 5 * 60

    static func evaluate(updatedAt: Date?, windowResetsAt: Date?, now: Date = Date()) -> UsageFreshness {
        guard let updatedAt else { return .unknown }
        if updatedAt.timeIntervalSince(now) > maxFutureSkew { return .unknown }
        if now.timeIntervalSince(updatedAt) > maxAge { return .stale }
        // 리셋 시각이 이미 지났다면 이 값은 지난 창의 것이라 지금의 잔량이 아니다.
        if let windowResetsAt, windowResetsAt <= now { return .stale }
        return .fresh
    }
}
