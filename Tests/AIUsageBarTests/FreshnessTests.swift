import Foundation
import Testing
@testable import AIUsageBar

@Suite("Freshness: stale / unknown instead of a misleading number")
struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func recentValueIsFresh() {
        #expect(UsageFreshnessPolicy.evaluate(updatedAt: now.addingTimeInterval(-60), windowResetsAt: now.addingTimeInterval(3600), now: now) == .fresh)
    }

    @Test func oldRecordIsStale() {
        #expect(UsageFreshnessPolicy.evaluate(updatedAt: now.addingTimeInterval(-31 * 60), windowResetsAt: nil, now: now) == .stale)
        #expect(UsageFreshnessPolicy.evaluate(updatedAt: now.addingTimeInterval(-29 * 60), windowResetsAt: nil, now: now) == .fresh)
    }

    @Test func valueFromAnAlreadyResetWindowIsStale() {
        #expect(UsageFreshnessPolicy.evaluate(updatedAt: now.addingTimeInterval(-60), windowResetsAt: now.addingTimeInterval(-1), now: now) == .stale)
    }

    @Test func missingOrFutureTimestampIsUnknown() {
        #expect(UsageFreshnessPolicy.evaluate(updatedAt: nil, windowResetsAt: nil, now: now) == .unknown)
        #expect(UsageFreshnessPolicy.evaluate(updatedAt: now.addingTimeInterval(3600), windowResetsAt: nil, now: now) == .unknown)
    }
}
