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

enum ClaudeUsageMonitorReader {
    static let fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/state/usage-monitor.json")
    static let watchDirectory = fileURL.deletingLastPathComponent()

    enum ReadError: LocalizedError {
        case fileNotFound
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound: "usage-monitor.json을 찾을 수 없습니다. Claude Code를 한 번 이상 사용해 주세요."
            case .decodeFailed: "usage-monitor.json 형식을 해석하지 못했습니다."
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
