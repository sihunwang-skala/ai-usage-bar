import Foundation

struct CodexRateLimitWindow: Equatable {
    let usedPercent: Int
    let resetsAt: Date?
    let durationMinutes: Int?
}

struct CodexUsageSnapshot: Equatable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?
    let model: String?
    let reasoningEffort: String?

    var fiveHour: CodexRateLimitWindow? {
        windows.first { $0.durationMinutes == 300 } ?? primary
    }

    var weekly: CodexRateLimitWindow? {
        windows.first { ($0.durationMinutes ?? 0) >= 7 * 24 * 60 } ?? secondary
    }

    private var windows: [CodexRateLimitWindow] {
        [primary, secondary].compactMap { $0 }
    }
}

enum CodexUsageParser {
    static func parse(response: [String: Any]) throws -> CodexUsageSnapshot {
        guard let result = response["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else {
            throw ParseError.missingRateLimits
        }

        return CodexUsageSnapshot(
            primary: parseWindow(limits["primary"]),
            secondary: parseWindow(limits["secondary"]),
            planType: limits["planType"] as? String,
            model: limits["normalModelSlug"] as? String,
            reasoningEffort: nil
        )
    }

    private static func parseWindow(_ value: Any?) -> CodexRateLimitWindow? {
        guard let object = value as? [String: Any],
              let used = object["usedPercent"] as? NSNumber else { return nil }
        let reset = (object["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let duration = (object["windowDurationMins"] as? NSNumber)?.intValue
        return CodexRateLimitWindow(usedPercent: used.intValue, resetsAt: reset, durationMinutes: duration)
    }

    enum ParseError: LocalizedError {
        case missingRateLimits
        var errorDescription: String? { "Codex response had no usage info." }
    }
}
