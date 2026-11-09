import Foundation

/// 한 5시간 창의 남은 양을 몇 번에 나눠 쓸지 정한 계획.
/// 앱은 때가 되면 알려 주기만 한다. Claude/Codex를 대신 쓰지 않는다.
struct UsagePlan: Codable {
    var service: String
    var createdAt: Date
    var resetsAt: Date
    /// 계획을 세운 시점의 남은 양(%)
    var startRemaining: Int
    /// 구간별로 쓸 양(전체 한도 대비 %p). 구간은 리셋까지 시간을 같은 길이로 나눈 것이다.
    var parts: [Int]
    var notifiedIndex: Int

    func slotStart(_ index: Int) -> Date {
        createdAt.addingTimeInterval(resetsAt.timeIntervalSince(createdAt) * Double(index) / Double(parts.count))
    }

    func plannedRemaining(afterParts count: Int) -> Int {
        startRemaining - parts.prefix(count).reduce(0, +)
    }
}

enum CoachPreferences {
    private static let paceKey = "paceAlertEnabled"
    private static let tasksKey = "leftoverTasks"
    private static let plansKey = "usagePlans"

    /// 이대로 쓰면 리셋 전에 한도가 찰 때 알려 준다. 기본 켜짐.
    static var paceAlertEnabled: Bool {
        get { UserDefaults.standard.object(forKey: paceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: paceKey) }
    }

    /// 사용자가 "남으면 이거 맡기자" 하고 적어 둔 일. 앱은 알림에 보여 주기만 한다.
    static var tasks: [String] {
        get { UserDefaults.standard.stringArray(forKey: tasksKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: tasksKey) }
    }

    static var plans: [String: UsagePlan] {
        get {
            guard let data = UserDefaults.standard.data(forKey: plansKey),
                  let decoded = try? JSONDecoder().decode([String: UsagePlan].self, from: data) else { return [:] }
            return decoded
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: plansKey) }
    }

    /// 알림 본문 끝에 붙일 "남은 일" 문구. 없으면 빈 문자열.
    static var tasksSuffix: String {
        let items = tasks.prefix(3)
        guard !items.isEmpty else { return "" }
        let more = tasks.count > 3 ? " …" : ""
        return "\n" + tr("To do: ", "남은 일: ") + items.joined(separator: ", ") + more
    }
}

/// 알림을 내보내는 쪽. 실제 앱에서는 ThresholdNotifier, 테스트에서는 기록용 가짜를 쓴다.
protocol UsageNotifying: AnyObject {
    func notify(title: String, message: String, serviceName: String?)
}

/// 사용 계획·페이스 알림·주간 가이드. 사용량 값을 받아 판단만 하고, 모델은 호출하지 않는다.
final class UsageCoach {
    struct Window {
        let remaining: Int
        let resetsAt: Date?
    }

    static let windowLength: TimeInterval = 5 * 3600

    private let notifier: UsageNotifying
    private(set) var latestFive: [String: Window] = [:]
    private var lastPaceReset: [String: Date] = [:]

    init(notifier: UsageNotifying) { self.notifier = notifier }

    /// 사용량이 갱신될 때마다 부른다. 주간 가이드 문구를 돌려준다(값이 없으면 nil).
    @discardableResult
    func evaluate(service: String, five: Window?, week: Window?, now: Date = Date()) -> WeeklyGuide? {
        if let five {
            latestFive[service] = five
            checkPlan(service: service, five: five, now: now)
            checkPace(service: service, five: five, now: now)
        }
        return week.flatMap { recordWeekly(service: service, week: $0, now: now) }
    }

    // MARK: 계획

    enum PlanError: Error { case noData, tooLate, overBudget(Int), empty }

    func createPlan(service: String, parts: [Int], now: Date = Date()) -> Result<UsagePlan, PlanError> {
        guard let five = latestFive[service], let reset = five.resetsAt else { return .failure(.noData) }
        guard reset.timeIntervalSince(now) > 10 * 60 else { return .failure(.tooLate) }
        let cleaned = parts.filter { $0 > 0 }
        guard !cleaned.isEmpty else { return .failure(.empty) }
        guard cleaned.reduce(0, +) <= five.remaining else { return .failure(.overBudget(five.remaining)) }
        let plan = UsagePlan(service: service, createdAt: now, resetsAt: reset, startRemaining: five.remaining, parts: cleaned, notifiedIndex: 0)
        var all = CoachPreferences.plans
        all[service] = plan
        CoachPreferences.plans = all
        return .success(plan)
    }

    func cancelPlan(service: String) {
        var all = CoachPreferences.plans
        all.removeValue(forKey: service)
        CoachPreferences.plans = all
    }

    private func checkPlan(service: String, five: Window, now: Date) {
        var all = CoachPreferences.plans
        guard var plan = all[service] else { return }
        // 창이 리셋돼 새 창이 되었으면 계획은 끝난 것.
        guard let reset = five.resetsAt, reset > now, abs(reset.timeIntervalSince(plan.resetsAt)) < 600 else {
            all.removeValue(forKey: service)
            CoachPreferences.plans = all
            return
        }
        guard plan.parts.count > 1 else { return }
        let due = (1..<plan.parts.count).last(where: { plan.slotStart($0) <= now }) ?? 0
        guard due > plan.notifiedIndex else { return }
        // 방해 금지 시간이면 보내지 않는다. 시간이 끝난 뒤 다음 확인 때 보낸다.
        guard !NotificationPreferences.isQuietNow(now) else { return }
        plan.notifiedIndex = due
        all[service] = plan
        CoachPreferences.plans = all

        let planned = plan.plannedRemaining(afterParts: due)
        let amount = plan.parts[due]
        var message = tr("Part \(due + 1) of \(plan.parts.count): use about \(amount)% now. Planned left: \(planned)%, actual: \(five.remaining)%.",
                         "\(due + 1)/\(plan.parts.count)번째 구간이에요. 지금 약 \(amount)%를 써 보세요. 계획 \(planned)% 남음, 현재 \(five.remaining)% 남음.")
        if five.remaining < planned - 5 {
            message += " " + tr("You're a bit ahead of the plan.", "계획보다 조금 빨리 쓰는 중이에요.")
        }
        message += CoachPreferences.tasksSuffix
        notifier.notify(title: tr("\(service) usage plan", "\(service) 사용 계획"), message: message, serviceName: service)
    }

    // MARK: 페이스

    private func checkPace(service: String, five: Window, now: Date) {
        guard CoachPreferences.paceAlertEnabled, let reset = five.resetsAt, reset > now else { return }
        if let previous = lastPaceReset[service], abs(previous.timeIntervalSince(reset)) < 600 { return }
        let used = 100 - five.remaining
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-Self.windowLength))
        guard used >= 25, elapsed >= 20 * 60, elapsed <= Self.windowLength else { return }
        guard !NotificationPreferences.isQuietNow(now) else { return }
        let secondsToFull = Double(five.remaining) / (Double(used) / elapsed)
        let secondsToReset = reset.timeIntervalSince(now)
        guard secondsToFull < secondsToReset - 10 * 60 else { return }
        lastPaceReset[service] = reset
        let fullMinutes = max(1, Int(secondsToFull / 60))
        let resetMinutes = max(1, Int(secondsToReset / 60))
        notifier.notify(
            title: tr("\(service) is going fast", "\(service) 사용 속도가 빨라요"),
            message: tr("At this pace the 5-hour limit runs out in about \(fullMinutes) min, but it resets in \(resetMinutes) min.",
                        "이 속도면 약 \(fullMinutes)분 뒤 5시간 한도가 다 차요. 리셋은 \(resetMinutes)분 뒤예요."),
            serviceName: service
        )
    }

    // MARK: 주간 가이드

    /// 이번 주(7일)를 하루씩 나눠 본 기록. 주 시작은 주간 리셋 시각에서 7일을 뺀 시점이고, 하루는 거기서부터 24시간이다.
    struct WeeklyGuide: Equatable {
        /// 오늘이 몇째 날인지(1~7)
        let dayNumber: Int
        /// 오늘을 포함해 남은 날 수
        let daysLeft: Int
        let remaining: Int
        /// 남은 양 ÷ 남은 날 수
        let perDay: Int
        /// 지난 날들의 사용량(%p). 앱이 보지 못한 날은 nil.
        let pastDays: [Int?]
        /// 오늘 지금까지 쓴 양(%p)
        let usedToday: Int

        var summary: String {
            tr("Daily budget: \(perDay)% (day \(dayNumber), \(daysLeft) days left)",
               "하루 권장량 \(perDay)% (\(dayNumber)일째 · \(daysLeft)일 남음)")
        }

        var history: String {
            var parts = pastDays.enumerated().map { index, used in
                tr("Day \(index + 1) ", "\(index + 1)일차 ") + (used.map { "\($0)%" } ?? "—")
            }
            parts.append(tr("Today \(usedToday)%", "오늘 \(usedToday)%"))
            return tr("Used: ", "사용: ") + parts.joined(separator: " · ")
        }
    }

    private struct WeeklyLedger: Codable {
        var resetsAt: Date
        /// 하루(0~6)의 마지막으로 본 주간 사용률(%)
        var usedAtDayEnd: [Int: Int]
        /// 처음 본 날과 그때의 사용률. 그 전 날들은 알 수 없다.
        var firstDay: Int
        var firstUsed: Int
    }

    private static let ledgersKey = "weeklyLedgers"

    private func loadLedgers() -> [String: WeeklyLedger] {
        guard let data = UserDefaults.standard.data(forKey: Self.ledgersKey),
              let decoded = try? JSONDecoder().decode([String: WeeklyLedger].self, from: data) else { return [:] }
        return decoded
    }

    private func saveLedgers(_ ledgers: [String: WeeklyLedger]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(ledgers), forKey: Self.ledgersKey)
    }

    func recordWeekly(service: String, week: Window, now: Date) -> WeeklyGuide? {
        guard let reset = week.resetsAt, reset > now else { return nil }
        let start = reset.addingTimeInterval(-7 * 86_400)
        let day = min(6, max(0, Int(floor(now.timeIntervalSince(start) / 86_400))))
        let used = 100 - week.remaining

        var ledgers = loadLedgers()
        var ledger = ledgers[service]
        if ledger == nil || abs(ledger!.resetsAt.timeIntervalSince(reset)) > 600 {
            ledger = WeeklyLedger(resetsAt: reset, usedAtDayEnd: [:], firstDay: day, firstUsed: day == 0 ? 0 : used)
        }
        var current = ledger!
        current.usedAtDayEnd[day] = max(used, current.usedAtDayEnd[day] ?? 0)
        ledgers[service] = current
        saveLedgers(ledgers)

        var past: [Int?] = []
        var previous = current.firstUsed
        for d in 0..<day {
            if d < current.firstDay {
                past.append(nil)
            } else {
                let end = max(previous, current.usedAtDayEnd[d] ?? previous)
                past.append(end - previous)
                previous = end
            }
        }
        let daysLeft = 7 - day
        return WeeklyGuide(
            dayNumber: day + 1, daysLeft: daysLeft, remaining: week.remaining,
            perDay: Int((Double(week.remaining) / Double(daysLeft)).rounded()),
            pastDays: past, usedToday: max(0, used - previous)
        )
    }
}
