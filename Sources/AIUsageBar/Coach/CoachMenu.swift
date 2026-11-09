import AppKit

/// "사용 코치" 메뉴. 열 때마다 현재 계획과 남은 일 목록으로 다시 그린다.
@MainActor
final class CoachMenu: NSObject, NSMenuDelegate {
    private let coach: UsageCoach
    private let services = ["Claude", "Codex"]
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(coach: UsageCoach) { self.coach = coach }

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: tr("Usage coach", "사용 코치"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        item.submenu = submenu
        rebuild(submenu)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ object: Any? = nil, on: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if action != nil { item.target = self } else { item.isEnabled = false }
        item.representedObject = object
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let plans = CoachPreferences.plans

        add(menu, tr("Split this 5-hour window", "이번 5시간 창 나눠 쓰기"), nil)
        for service in services {
            let parent = NSMenuItem(title: service, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if let plan = plans[service] {
                let next = (plan.notifiedIndex + 1 < plan.parts.count) ? plan.slotStart(plan.notifiedIndex + 1) : nil
                var text = tr("Plan: ", "계획: ") + plan.parts.map { "\($0)%" }.joined(separator: " · ")
                if let next { text += tr("  (next \(timeFormatter.string(from: next)))", "  (다음 \(timeFormatter.string(from: next)))") }
                add(sub, text, nil)
                add(sub, tr("Cancel plan", "계획 취소"), #selector(cancelPlan(_:)), service)
                sub.addItem(.separator())
            }
            for n in [2, 3, 4] {
                add(sub, tr("Split evenly into \(n)", "\(n)등분"), #selector(evenSplit(_:)), "\(service)|\(n)")
            }
            add(sub, tr("Custom…", "직접 입력…"), #selector(customSplit(_:)), service)
            parent.submenu = sub
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        add(menu, tr("Fast-pace alert", "사용 속도 알림"), #selector(togglePace(_:)), on: CoachPreferences.paceAlertEnabled)

        menu.addItem(.separator())
        add(menu, tr("To do when quota is left (reminders only)", "남으면 할 일 (알려 주기만 해요)"), nil)
        for (index, task) in CoachPreferences.tasks.enumerated() {
            add(menu, "  \(task)  ✕", #selector(removeTask(_:)), index)
        }
        add(menu, tr("Add a task…", "할 일 추가…"), #selector(addTask))
    }

    // MARK: 계획

    @objc private func cancelPlan(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? String else { return }
        coach.cancelPlan(service: service)
    }

    @objc private func evenSplit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let pieces = raw.split(separator: "|")
        guard pieces.count == 2, let n = Int(pieces[1]) else { return }
        let service = String(pieces[0])
        guard let remaining = coach.latestFive[service]?.remaining else { return showPlanError(.noData) }
        let each = remaining / n
        create(service: service, parts: Array(repeating: each, count: n))
    }

    @objc private func customSplit(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? String else { return }
        let remaining = coach.latestFive[service]?.remaining
        let alert = NSAlert()
        alert.messageText = tr("\(service): split the remaining quota", "\(service): 남은 양 나눠 쓰기")
        let remainingText = remaining.map { tr("Left now: \($0)%. ", "지금 \($0)% 남음. ") } ?? ""
        alert.informativeText = remainingText + tr("Enter how much to use in each part, separated by commas (e.g. 30, 30, 30). Parts are spread evenly until the reset.",
                                                    "구간마다 쓸 양(%)을 쉼표로 적어 주세요. 예: 30, 30, 30. 구간은 리셋까지 같은 간격으로 나눠요.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "30, 30, 30"
        alert.accessoryView = field
        alert.addButton(withTitle: tr("Set plan", "계획 세우기"))
        alert.addButton(withTitle: tr("Cancel", "취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = field.stringValue.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        create(service: service, parts: parts)
    }

    private func create(service: String, parts: [Int]) {
        switch coach.createPlan(service: service, parts: parts) {
        case .success(let plan):
            let text = plan.parts.map { "\($0)%" }.joined(separator: " · ")
            let alert = NSAlert()
            alert.messageText = tr("Plan set", "계획을 세웠어요")
            alert.informativeText = tr("\(service): \(text). I'll remind you at the start of each part. Nothing is used automatically.",
                                       "\(service): \(text). 구간이 시작될 때마다 알려 드릴게요. 대신 사용하지는 않아요.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .failure(let error):
            showPlanError(error)
        }
    }

    private func showPlanError(_ error: UsageCoach.PlanError) {
        let alert = NSAlert()
        alert.messageText = tr("Couldn't set the plan", "계획을 세울 수 없어요")
        switch error {
        case .noData: alert.informativeText = tr("No usage data with a reset time yet.", "리셋 시각이 있는 사용량 값이 아직 없어요.")
        case .tooLate: alert.informativeText = tr("The window resets in less than 10 minutes.", "리셋까지 10분도 안 남았어요.")
        case .overBudget(let left): alert.informativeText = tr("The parts add up to more than what's left (\(left)%).", "합계가 남은 양(\(left)%)보다 커요.")
        case .empty: alert.informativeText = tr("Enter numbers like 30, 30, 30.", "30, 30, 30처럼 숫자를 입력해 주세요.")
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func togglePace(_ sender: NSMenuItem) {
        CoachPreferences.paceAlertEnabled.toggle()
    }

    // MARK: 남은 일

    @objc private func addTask() {
        let alert = NSAlert()
        alert.messageText = tr("Add a task", "할 일 추가")
        alert.informativeText = tr("Something to hand to Claude/Codex when quota is left, e.g. “Update the README”. It's shown in reminders only; nothing is run for you.",
                                   "쿼터가 남으면 맡길 일을 적어 두세요. 예: README 수정. 알림에 보여 주기만 하고 대신 실행하지는 않아요.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: tr("Add", "추가"))
        alert.addButton(withTitle: tr("Cancel", "취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        CoachPreferences.tasks.append(text)
    }

    @objc private func removeTask(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        var tasks = CoachPreferences.tasks
        guard tasks.indices.contains(index) else { return }
        tasks.remove(at: index)
        CoachPreferences.tasks = tasks
    }
}
