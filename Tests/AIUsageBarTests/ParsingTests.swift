import Foundation
import Testing
@testable import AIUsageBar

@Suite("Claude / Codex usage parsing")
struct ParsingTests {
    // MARK: Claude live endpoint (unofficial /api/oauth/usage)

    @Test func claudeOAuthParsesBothWindows() throws {
        let data = Data(#"""
        {"five_hour":{"utilization":27.4,"resets_at":"2026-11-05T04:10:00.000000+00:00"},
         "seven_day":{"utilization":19,"resets_at":"2026-11-11T17:00:00+00:00"}}
        """#.utf8)
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = try ClaudeOAuthUsageReader.parse(data, now: now)
        #expect(snapshot.fiveHour?.usedPercent == 27.4)
        #expect(snapshot.weekly?.usedPercent == 19)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-05T04:10:00+00:00"))
        #expect(snapshot.weekly?.resetsAt != nil)
    }

    @Test func claudeOAuthClampsOutOfRangeValues() throws {
        let data = Data(#"{"five_hour":{"utilization":-3},"seven_day":{"utilization":250}}"#.utf8)
        let snapshot = try ClaudeOAuthUsageReader.parse(data)
        #expect(snapshot.fiveHour?.usedPercent == 0)
        #expect(snapshot.weekly?.usedPercent == 100)
    }

    @Test func claudeOAuthAcceptsOneWindowOnly() throws {
        let snapshot = try ClaudeOAuthUsageReader.parse(Data(#"{"five_hour":{"utilization":10}}"#.utf8))
        #expect(snapshot.fiveHour != nil)
        #expect(snapshot.weekly == nil)
    }

    @Test(arguments: [#"{}"#, #"[]"#, #"not json"#, #"{"five_hour":null,"seven_day":null}"#, #"{"five_hour":{"resets_at":"x"}}"#])
    func claudeOAuthRejectsUnusablePayloads(_ payload: String) {
        #expect(throws: ClaudeOAuthUsageReader.ReadError.self) {
            _ = try ClaudeOAuthUsageReader.parse(Data(payload.utf8))
        }
    }

    // MARK: Claude Desktop local history

    @Test func desktopHistoryUsesNewestSample() throws {
        let data = Data(#"""
        {"version":2,"samples":[
          {"t":1700000000000,"u":{"fh":88,"sd":25}},
          {"t":1700000300000,"u":{"fh":12,"sd":34}}]}
        """#.utf8)
        let snapshot = try ClaudeDesktopUsageReader.parse(data)
        #expect(snapshot.fiveHour?.usedPercent == 12)
        #expect(snapshot.weekly?.usedPercent == 34)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1_700_000_300))
        #expect(snapshot.fiveHour?.resetsAt == nil)
    }

    @Test func desktopHistoryClampsAndRejectsEmpty() throws {
        let clamped = try ClaudeDesktopUsageReader.parse(Data(#"{"samples":[{"t":1,"u":{"fh":-5,"sd":140}}]}"#.utf8))
        #expect(clamped.fiveHour?.usedPercent == 0)
        #expect(clamped.weekly?.usedPercent == 100)
        #expect(throws: ClaudeDesktopUsageReader.ReadError.self) {
            _ = try ClaudeDesktopUsageReader.parse(Data(#"{"samples":[]}"#.utf8))
        }
        #expect(throws: ClaudeDesktopUsageReader.ReadError.self) {
            _ = try ClaudeDesktopUsageReader.parse(Data("garbage".utf8))
        }
    }

    // MARK: Claude Code local monitor file

    @Test func monitorFileParses() throws {
        let data = Data(#"""
        {"updatedAt":1700000000,
         "fiveHour":{"usedPercent":40,"resetsAt":"2023-11-14T22:13:20Z"},
         "weekly":{"usedPercent":10}}
        """#.utf8)
        let snapshot = try ClaudeUsageMonitorReader.parse(data)
        #expect(snapshot.fiveHour?.usedPercent == 40)
        #expect(snapshot.fiveHour?.resetsAt != nil)
        #expect(snapshot.weekly?.resetsAt == nil)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func monitorFileWithoutTimestampHasUnknownAge() throws {
        let snapshot = try ClaudeUsageMonitorReader.parse(Data(#"{"fiveHour":{"usedPercent":5}}"#.utf8))
        #expect(snapshot.updatedAt == nil)
        #expect(UsageFreshnessPolicy.evaluate(updatedAt: snapshot.updatedAt, windowResetsAt: nil) == .unknown)
    }

    // MARK: Codex app-server

    @Test func codexPicksWindowsByDuration() throws {
        // 순서가 바뀌어 와도 5시간(300분)/주간(>=7일)을 길이로 골라야 한다.
        let response: [String: Any] = ["result": ["rateLimits": [
            "primary": ["usedPercent": 30, "windowDurationMins": 10080, "resetsAt": 1_800_000_000],
            "secondary": ["usedPercent": 70, "windowDurationMins": 300, "resetsAt": 1_700_000_000],
            "planType": "plus"
        ]]]
        let snapshot = try CodexUsageParser.parse(response: response)
        #expect(snapshot.fiveHour?.usedPercent == 70)
        #expect(snapshot.weekly?.usedPercent == 30)
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.planType == "plus")
    }

    @Test func codexFallsBackToPrimarySecondaryWithoutDurations() throws {
        let response: [String: Any] = ["result": ["rateLimits": [
            "primary": ["usedPercent": 1], "secondary": ["usedPercent": 2]
        ]]]
        let snapshot = try CodexUsageParser.parse(response: response)
        #expect(snapshot.fiveHour?.usedPercent == 1)
        #expect(snapshot.weekly?.usedPercent == 2)
    }

    @Test func codexMissingUsedPercentIsNoData() throws {
        let response: [String: Any] = ["result": ["rateLimits": ["primary": ["windowDurationMins": 300]]]]
        let snapshot = try CodexUsageParser.parse(response: response)
        #expect(snapshot.fiveHour == nil)
    }

    @Test func codexRejectsResponsesWithoutRateLimits() {
        #expect(throws: CodexUsageParser.ParseError.self) {
            _ = try CodexUsageParser.parse(response: ["result": [:]])
        }
        #expect(throws: CodexUsageParser.ParseError.self) {
            _ = try CodexUsageParser.parse(response: ["error": ["message": "x"]])
        }
    }
}
