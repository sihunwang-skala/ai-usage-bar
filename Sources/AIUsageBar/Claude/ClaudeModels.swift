import Foundation

struct ClaudeRateLimitWindow: Equatable {
    let usedPercent: Double
    let resetsAt: Date?
}

struct ClaudeUsageSnapshot: Equatable {
    let fiveHour: ClaudeRateLimitWindow?
    let weekly: ClaudeRateLimitWindow?
    let updatedAt: Date?
}

/// Claude Desktop's own account-wide usage history. Claude writes this file
/// after it fetches the plan usage shown by its usage ring/tray UI. The compact
/// keys are defined by Claude Desktop itself: `fh` = five_hour and
/// `sd` = seven_day. Reading this file does not touch cookies or credentials.
enum ClaudeDesktopUsageReader {
    static let fileURL = URL(
        fileURLWithPath: NSHomeDirectory()
            + "/Library/Application Support/Claude/plan-usage-history.json"
    )
    static let watchDirectory = fileURL.deletingLastPathComponent()

    enum ReadError: LocalizedError {
        case fileNotFound
        case noSamples
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                tr("Couldn't find the Claude Desktop usage record. Please open the usage screen in the Claude app once.", "Claude Desktop 사용량 기록을 찾을 수 없어요. Claude 앱의 사용량 화면을 한 번 열어 주세요.")
            case .noSamples:
                tr("The Claude Desktop usage record has no values to show.", "Claude Desktop 사용량 기록에 표시할 값이 없어요.")
            case .decodeFailed:
                tr("Couldn't read the Claude Desktop usage record.", "Claude Desktop 사용량 기록 형식을 해석하지 못했어요.")
            }
        }
    }

    static func read() throws -> ClaudeUsageSnapshot {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            throw ReadError.fileNotFound
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ClaudeUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = object["samples"] as? [[String: Any]] else {
            throw ReadError.decodeFailed
        }
        guard let latest = samples.max(by: { timestamp($0) < timestamp($1) }),
              let usage = latest["u"] as? [String: Any] else {
            throw ReadError.noSamples
        }
        let updatedAt = Date(timeIntervalSince1970: timestamp(latest) / 1_000)
        return ClaudeUsageSnapshot(
            fiveHour: percent(usage["fh"]).map {
                ClaudeRateLimitWindow(usedPercent: $0, resetsAt: nil)
            },
            weekly: percent(usage["sd"]).map {
                ClaudeRateLimitWindow(usedPercent: $0, resetsAt: nil)
            },
            updatedAt: updatedAt
        )
    }

    private static func timestamp(_ sample: [String: Any]) -> Double {
        (sample["t"] as? NSNumber)?.doubleValue ?? 0
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return max(0, min(100, number.doubleValue))
    }
}

enum ClaudeUsageMonitorReader {
    static let fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/state/usage-monitor.json")
    static let watchDirectory = fileURL.deletingLastPathComponent()

    enum ReadError: LocalizedError {
        case fileNotFound
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound: tr("Couldn't find usage-monitor.json. Please use Claude Code at least once.", "usage-monitor.json을 찾을 수 없어요. Claude Code를 한 번 이상 사용해 주세요.")
            case .decodeFailed: tr("Couldn't read usage-monitor.json.", "usage-monitor.json 형식을 해석하지 못했어요.")
            }
        }
    }

    static func read() throws -> ClaudeUsageSnapshot {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            throw ReadError.fileNotFound
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.decodeFailed
        }
        let updatedAt = (object["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return ClaudeUsageSnapshot(
            fiveHour: parseWindow(object["fiveHour"]),
            weekly: parseWindow(object["weekly"]),
            updatedAt: updatedAt
        )
    }

    private static func parseWindow(_ value: Any?) -> ClaudeRateLimitWindow? {
        guard let dict = value as? [String: Any],
              let used = dict["usedPercent"] as? NSNumber else { return nil }
        let resetsAt = (dict["resetsAt"] as? String).flatMap(parseISODate)
        return ClaudeRateLimitWindow(usedPercent: used.doubleValue, resetsAt: resetsAt)
    }

    private static func parseISODate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
