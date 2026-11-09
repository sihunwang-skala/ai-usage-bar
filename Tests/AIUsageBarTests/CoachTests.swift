import Foundation
import Testing
@testable import AIUsageBar

final class RecordingNotifier: UsageNotifying, @unchecked Sendable {
    struct Note { let title: String; let message: String }
    var notes: [Note] = []
    func notify(title: String, message: String, serviceName: String?) { notes.append(Note(title: title, message: message)) }
}

@Suite("Usage coach: plan, pace, weekly guide, quiet hours", .serialized)
struct CoachTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func cleanState() {
        for key in ["usagePlans", "paceAlertEnabled", "leftoverTasks", "quietRanges", "weeklyLedgers"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func window(_ remaining: Int, resetsIn seconds: TimeInterval) -> UsageCoach.Window {
        .init(remaining: remaining, resetsAt: now.addingTimeInterval(seconds))
    }

    /// 같은 창(리셋 시각 고정)의 값. 시간이 흘러도 리셋 시각은 now + 4h로 그대로다.
    private func sameWindow(_ remaining: Int) -> UsageCoach.Window { window(remaining, resetsIn: 4 * 3600) }

    // MARK: weekly guide

    /// 주간 창: 리셋이 `daysLeft`일 뒤인 값. 주 시작은 리셋 7일 전이다.
    private func week(_ remaining: Int, daysLeft: Double) -> UsageCoach.Window { window(remaining, resetsIn: daysLeft * 86_400) }

    @Test func weeklyGuideAveragesRemainingOverRemainingDays() throws {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        // 리셋까지 3.8일 → 4일째, 남은 80% ÷ 4일 = 하루 20%
        let guide = try #require(coach.recordWeekly(service: "Claude", week: week(80, daysLeft: 3.8), now: now))
        #expect(guide.dayNumber == 4)
        #expect(guide.daysLeft == 4)
        #expect(guide.perDay == 20)
    }

    @Test func weeklyGuideListsEachPastDayAndRecalculates() throws {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        let resetsAt = now.addingTimeInterval(7 * 86_400)
        func observe(day: Int, hour: Double, remaining: Int) -> UsageCoach.WeeklyGuide? {
            let t = now.addingTimeInterval(Double(day) * 86_400 + hour * 3600)
            return coach.recordWeekly(service: "Claude", week: .init(remaining: remaining, resetsAt: resetsAt), now: t)
        }
        _ = observe(day: 0, hour: 1, remaining: 98)
        _ = observe(day: 0, hour: 23, remaining: 90)   // 1일차 10%
        _ = observe(day: 1, hour: 22, remaining: 80)   // 2일차 10%
        _ = observe(day: 2, hour: 23, remaining: 65)   // 3일차 15%
        let guide = try #require(observe(day: 3, hour: 2, remaining: 62))
        #expect(guide.dayNumber == 4)
        #expect(guide.pastDays == [10, 10, 15])
        #expect(guide.usedToday == 3)
        #expect(guide.remaining == 62)
        #expect(guide.daysLeft == 4)
        #expect(guide.perDay == 16)   // 62 ÷ 4 = 15.5 → 16
        #expect(guide.history.contains("10%"))
        #expect(guide.history.contains("15%"))
    }

    @Test func daysBeforeFirstObservationAreUnknownNotZero() throws {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        let guide = try #require(coach.recordWeekly(service: "Codex", week: week(70, daysLeft: 3.8), now: now))
        #expect(guide.pastDays == [nil, nil, nil])
        #expect(guide.usedToday == 0)
    }

    @Test func newWeekStartsANewLedger() throws {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        _ = coach.recordWeekly(service: "Claude", week: .init(remaining: 50, resetsAt: now.addingTimeInterval(86_400)), now: now)
        let later = now.addingTimeInterval(2 * 86_400)
        let guide = try #require(coach.recordWeekly(service: "Claude", week: .init(remaining: 100, resetsAt: later.addingTimeInterval(7 * 86_400 - 60)), now: later))
        #expect(guide.dayNumber == 1)
        #expect(guide.pastDays.isEmpty)
        #expect(guide.usedToday == 0)
    }

    @Test func weeklyGuideIsNilWithoutResetOrAfterReset() {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        #expect(coach.recordWeekly(service: "Claude", week: .init(remaining: 50, resetsAt: nil), now: now) == nil)
        #expect(coach.recordWeekly(service: "Claude", week: week(50, daysLeft: -0.1), now: now) == nil)
    }

    // MARK: quiet hours

    @Test func quietHoursHandleMidnightWrapAndMultipleRanges() {
        cleanState(); defer { cleanState() }
        var calendar = Calendar.current
        calendar.timeZone = .current
        func date(hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 30, second: 0, of: now)! }
        NotificationPreferences.quietRanges = [(23, 8), (13, 14)]
        #expect(NotificationPreferences.isQuietNow(date(hour: 23)))
        #expect(NotificationPreferences.isQuietNow(date(hour: 2)))
        #expect(NotificationPreferences.isQuietNow(date(hour: 13)))
        #expect(!NotificationPreferences.isQuietNow(date(hour: 8)))
        #expect(!NotificationPreferences.isQuietNow(date(hour: 12)))
        NotificationPreferences.quietRanges = []
        #expect(!NotificationPreferences.isQuietNow(date(hour: 2)))
    }

    // MARK: plan

    @Test func planNeedsDataAndRespectsBudget() {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        if case .failure(.noData) = coach.createPlan(service: "Claude", parts: [10], now: now) {} else { Issue.record("expected noData") }
        coach.evaluate(service: "Claude", five: window(50, resetsIn: 4 * 3600), week: nil, now: now)
        if case .failure(.overBudget(50)) = coach.createPlan(service: "Claude", parts: [30, 30], now: now) {} else { Issue.record("expected overBudget") }
        if case .failure(.empty) = coach.createPlan(service: "Claude", parts: [0], now: now) {} else { Issue.record("expected empty") }
        if case .success = coach.createPlan(service: "Claude", parts: [20, 20], now: now) {} else { Issue.record("expected success") }
    }

    @Test func planRejectsAlmostResetWindow() {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        coach.evaluate(service: "Codex", five: window(80, resetsIn: 5 * 60), week: nil, now: now)
        if case .failure(.tooLate) = coach.createPlan(service: "Codex", parts: [10, 10], now: now) {} else { Issue.record("expected tooLate") }
    }

    @Test func planNotifiesAtEachPartAndOnlyOnce() {
        cleanState(); defer { cleanState() }
        let notifier = RecordingNotifier()
        let coach = UsageCoach(notifier: notifier)
        let five = window(90, resetsIn: 4 * 3600)
        coach.evaluate(service: "Claude", five: five, week: nil, now: now)
        _ = coach.createPlan(service: "Claude", parts: [30, 30, 30], now: now)

        // 아직 두 번째 구간 전: 알림 없음
        coach.evaluate(service: "Claude", five: sameWindow(85), week: nil, now: now.addingTimeInterval(600))
        #expect(notifier.notes.isEmpty)

        // 두 번째 구간(리셋까지 1/3 지점) 시작
        let second = now.addingTimeInterval(4 * 3600 / 3 + 60)
        coach.evaluate(service: "Claude", five: sameWindow(60), week: nil, now: second)
        #expect(notifier.notes.count == 1)
        #expect(notifier.notes[0].message.contains("30%"))

        // 같은 구간에서 다시 평가해도 중복 알림 없음
        coach.evaluate(service: "Claude", five: sameWindow(60), week: nil, now: second.addingTimeInterval(60))
        #expect(notifier.notes.count == 1)
    }

    @Test func planEndsWhenWindowResets() {
        cleanState(); defer { cleanState() }
        let coach = UsageCoach(notifier: RecordingNotifier())
        coach.evaluate(service: "Claude", five: window(90, resetsIn: 3600), week: nil, now: now)
        _ = coach.createPlan(service: "Claude", parts: [30, 30], now: now)
        #expect(CoachPreferences.plans["Claude"] != nil)
        // 새 창(리셋 시각이 5시간 뒤로 바뀜)
        let later = now.addingTimeInterval(3700)
        coach.evaluate(service: "Claude", five: .init(remaining: 100, resetsAt: later.addingTimeInterval(5 * 3600)), week: nil, now: later)
        #expect(CoachPreferences.plans["Claude"] == nil)
    }

    @Test func planAlertIsHeldDuringQuietHours() {
        cleanState(); defer { cleanState() }
        let notifier = RecordingNotifier()
        let coach = UsageCoach(notifier: notifier)
        coach.evaluate(service: "Claude", five: window(90, resetsIn: 4 * 3600), week: nil, now: now)
        _ = coach.createPlan(service: "Claude", parts: [30, 30, 30], now: now)
        let hour = Calendar.current.component(.hour, from: now.addingTimeInterval(4 * 3600 / 3 + 60))
        NotificationPreferences.quietRanges = [(hour, (hour + 1) % 24)]
        let second = now.addingTimeInterval(4 * 3600 / 3 + 60)
        coach.evaluate(service: "Claude", five: sameWindow(60), week: nil, now: second)
        #expect(notifier.notes.isEmpty)
    }

    // MARK: pace

    @Test func paceAlertWhenLimitWouldRunOutBeforeReset() {
        cleanState(); defer { cleanState() }
        let notifier = RecordingNotifier()
        let coach = UsageCoach(notifier: notifier)
        // 창 시작 후 1시간에 60% 사용 → 이 속도면 40%는 40분 뒤 소진, 리셋은 4시간 뒤
        coach.evaluate(service: "Claude", five: window(40, resetsIn: 4 * 3600), week: nil, now: now)
        #expect(notifier.notes.count == 1)
        coach.evaluate(service: "Claude", five: sameWindow(40), week: nil, now: now.addingTimeInterval(30))
        #expect(notifier.notes.count == 1, "같은 창에서는 한 번만")
    }

    @Test func noPaceAlertWhenSlowOrTooEarlyOrDisabled() {
        cleanState(); defer { cleanState() }
        let notifier = RecordingNotifier()
        let coach = UsageCoach(notifier: notifier)
        coach.evaluate(service: "Claude", five: window(90, resetsIn: 3 * 3600), week: nil, now: now) // 느림
        coach.evaluate(service: "Codex", five: window(40, resetsIn: 4.9 * 3600), week: nil, now: now) // 창 시작 직후(6분)
        #expect(notifier.notes.isEmpty)
        CoachPreferences.paceAlertEnabled = false
        coach.evaluate(service: "Codex", five: window(40, resetsIn: 4 * 3600), week: nil, now: now)
        #expect(notifier.notes.isEmpty)
    }

    // MARK: leftover tasks

    @Test func leftoverTasksAppearInReminderSuffix() {
        cleanState(); defer { cleanState() }
        #expect(CoachPreferences.tasksSuffix.isEmpty)
        CoachPreferences.tasks = ["README", "tests", "docs", "refactor"]
        let suffix = CoachPreferences.tasksSuffix
        #expect(suffix.contains("README"))
        #expect(suffix.contains("docs"))
        #expect(!suffix.contains("refactor"))
    }
}
