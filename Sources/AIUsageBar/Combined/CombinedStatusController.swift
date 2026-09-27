import AppKit

/// Claude와 Codex 잔량을 하나의 NSStatusItem 안에, 서비스별로 "아이콘 + 5시간/주간 숫자 2줄"
/// 블록을 나란히 붙여서 보여주는 컨트롤러. 두 서비스를 별도 NSStatusItem으로 나누면 시스템이
/// 항목 사이에 고정 여백을 넣어 메뉴 막대 공간을 많이 차지하므로, 진짜 NSButton 두 개를 하나의
/// 컨테이너에 붙여 쓴다 — image+attributedTitle 조합은 예전 개별 앱 버전에서 이미 검증된
/// 렌더링 경로라 커스텀 텍스트필드보다 훨씬 안정적이다. 로그인되지 않은 서비스는 완전히 빠진다.
@MainActor
final class CombinedStatusController {
    private var statusItem: NSStatusItem!
    private var containerView: NSView!
    private var codexButton: NSButton!
    private var claudeButton: NSButton!

    // 로그인 여부(실제 상태)와 최종 표시 여부(로그인 && 사용자가 켰는지)를 분리해서 관리한다.
    private var claudeLoggedIn = true
    private var codexLoggedIn = true
    private var claudeVisible = ServicePreferences.claudeEnabled
    private var codexVisible = ServicePreferences.codexEnabled
    private var claudeFiveText = "—"
    private var claudeWeekText = "—"
    private var codexFiveText = "—"
    private var codexWeekText = "—"

    private var detailMenu: NSMenu!
    private var claudeHeaderItem: NSMenuItem!
    private var claudeFiveHourItem: NSMenuItem!
    private var claudeWeeklyItem: NSMenuItem!
    private var claudeStatusItem: NSMenuItem!
    private var codexHeaderItem: NSMenuItem!
    private var codexFiveHourItem: NSMenuItem!
    private var codexWeeklyItem: NSMenuItem!
    private var codexStatusItem: NSMenuItem!
    private var refreshItem: NSMenuItem!

    private let codexClient = CodexAppServerClient()
    private let notifier = ThresholdNotifier()

    private var claudeAccountInfo = ClaudeAccountInfoReader.Info(loggedIn: false, plan: nil, model: nil)
    private var usageTimer: Timer?
    private var claudeAccountTimer: Timer?
    private var codexTimer: Timer?
    private var codexAccountTimer: Timer?
    private var directoryWatcher: DispatchSourceFileSystemObject?

    // 새로고침 주기: UserDefaults에 저장해 재실행 후에도 유지한다.
    private static let refreshIntervalKey = "refreshIntervalSeconds"
    private static let refreshIntervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("30초마다", 30), ("1분마다", 60), ("5분마다", 300)
    ]
    private var refreshInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
            return stored > 0 ? stored : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.refreshIntervalKey) }
    }

    private let claudeWebURL = URL(string: "https://claude.ai/projects")!
    private let claudeUsageURL = URL(string: "https://claude.ai/settings/usage")!
    private let chatGPTURL = URL(string: "https://chatgpt.com/projects")!
    private let codexUsageURL = URL(string: "https://chatgpt.com/settings/usage?tab=overview")!

    func start() {
        configureStatusItem()
        buildDetailMenu()
        updateTitle()

        watchClaudeUsageFile()
        refreshClaudeAccountInfo()
        refreshClaudeLoginState()
        refreshClaude()
        refreshCodexLoginState()
        refreshCodex()

        claudeAccountTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshClaudeAccountInfo()
                self?.refreshClaudeLoginState()
            }
        }
        codexAccountTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodexLoginState() }
        }
        scheduleUsageTimers()
    }

    /// 새로고침 주기가 바뀌면 두 데이터 타이머를 이 값으로 다시 만든다.
    private func scheduleUsageTimers() {
        usageTimer?.invalidate()
        codexTimer?.invalidate()
        let interval = refreshInterval
        usageTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClaude() }
        }
        codexTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodex() }
        }
    }

    // MARK: - Status item

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil

        let height = NSStatusBar.system.thickness
        containerView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: height))
        button.addSubview(containerView)

        codexButton = Self.makeServiceButton()
        claudeButton = Self.makeServiceButton()
        codexButton.target = self
        codexButton.action = #selector(codexButtonClicked)
        claudeButton.target = self
        claudeButton.action = #selector(claudeButtonClicked)
        containerView.addSubview(codexButton)
        containerView.addSubview(claudeButton)
    }

    private static func makeServiceButton() -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.setButtonType(.momentaryChange)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return button
    }

    /// 버튼 로컬 좌표 기준 아이콘 클릭 판정 폭. 원래 개별 앱 버전이 쓰던 24pt 임계치와 같은 계열.
    private static let iconClickThreshold: CGFloat = 20

    @objc private func codexButtonClicked() { handleClick(on: codexButton, webURL: chatGPTURL) }
    @objc private func claudeButtonClicked() { handleClick(on: claudeButton, webURL: claudeWebURL) }

    private func handleClick(on button: NSButton, webURL: URL) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            detailMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
            return
        }
        let local = button.convert(event.locationInWindow, from: nil)
        if local.x <= Self.iconClickThreshold {
            NSWorkspace.shared.open(webURL)
        } else {
            detailMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        }
    }

    // MARK: - Title rendering

    /// GPT(Codex) 블록을 왼쪽, Claude 블록을 오른쪽에 두고 각 블록은 "아이콘 + 5시간/주간 숫자 2줄".
    /// 실제 NSButton의 image+attributedTitle 조합을 쓰므로(예전 검증된 렌더링 경로) 아이콘이
    /// 줄 높이에 제약받지 않고 14pt 그대로, 두 줄 전체 높이만큼 세로로 중앙 정렬된다.
    private func updateTitle() {
        Self.configure(button: codexButton, visible: codexVisible, icon: Self.codexIcon(), five: codexFiveText, week: codexWeekText)
        Self.configure(button: claudeButton, visible: claudeVisible, icon: Self.claudeIcon(), five: claudeFiveText, week: claudeWeekText)
        relayoutButtons()
    }

    private static func configure(button: NSButton, visible: Bool, icon: NSImage, five: String, week: String) {
        button.isHidden = !visible
        guard visible else { return }
        let iconCopy = icon.copy() as! NSImage
        iconCopy.size = NSSize(width: 14, height: 14)
        button.image = iconCopy
        button.attributedTitle = Self.stackedTitle(top: five, bottom: week)
        button.sizeToFit()
    }

    private func relayoutButtons() {
        var x: CGFloat = 0
        let visible = [codexVisible ? codexButton : nil, claudeVisible ? claudeButton : nil].compactMap { $0 }
        for (index, button) in visible.enumerated() {
            button.frame.origin = NSPoint(x: x, y: 0)
            x += button.frame.width
            if index < visible.count - 1 { x += 6 }
        }
        containerView.frame.size = NSSize(width: max(x, 1), height: containerView.frame.height)
        statusItem.length = containerView.frame.width
    }

    private static func stackedTitle(top: String, bottom: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 0
        paragraph.maximumLineHeight = 11
        paragraph.minimumLineHeight = 11
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: top, attributes: [
            .font: ServiceFont.number, .foregroundColor: AppearancePreferences.fiveHourColor, .paragraphStyle: paragraph
        ]))
        result.append(NSAttributedString(string: "\n", attributes: [.font: ServiceFont.number, .paragraphStyle: paragraph]))
        result.append(NSAttributedString(string: bottom, attributes: [
            .font: ServiceFont.number, .foregroundColor: AppearancePreferences.weeklyColor, .paragraphStyle: paragraph
        ]))
        return result
    }

    private func relayoutAndRender() {
        updateTitle()
    }

    /// 로그인 여부와 사용자 설정(ServicePreferences)을 합쳐 최종 표시 여부를 다시 계산한다.
    private func updateVisibility() {
        let newClaudeVisible = ServicePreferences.claudeEnabled && claudeLoggedIn
        let newCodexVisible = ServicePreferences.codexEnabled && codexLoggedIn
        guard newClaudeVisible != claudeVisible || newCodexVisible != codexVisible else { return }
        claudeVisible = newClaudeVisible
        codexVisible = newCodexVisible
        relayoutAndRender()
    }

    // MARK: - Menu

    private func buildDetailMenu() {
        let menu = NSMenu()

        claudeHeaderItem = Self.headerItem(title: "Claude")
        claudeFiveHourItem = NSMenuItem(title: "5H: 불러오는 중…", action: #selector(openClaudeUsagePage), keyEquivalent: "")
        claudeWeeklyItem = NSMenuItem(title: "1W: 불러오는 중…", action: #selector(openClaudeUsagePage), keyEquivalent: "")
        claudeStatusItem = NSMenuItem(title: "", action: #selector(openClaudeUsagePage), keyEquivalent: "")
        [claudeFiveHourItem!, claudeWeeklyItem!, claudeStatusItem!].forEach { $0.target = self }

        codexHeaderItem = Self.headerItem(title: "Codex")
        codexFiveHourItem = NSMenuItem(title: "5H: 불러오는 중…", action: #selector(openCodexUsagePage), keyEquivalent: "")
        codexWeeklyItem = NSMenuItem(title: "1W: 불러오는 중…", action: #selector(openCodexUsagePage), keyEquivalent: "")
        codexStatusItem = NSMenuItem(title: "", action: #selector(openCodexUsagePage), keyEquivalent: "")
        [codexFiveHourItem!, codexWeeklyItem!, codexStatusItem!].forEach { $0.target = self }

        refreshItem = NSMenuItem(title: "지금 새로고침", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        let intervalItem = NSMenuItem(title: "새로고침 주기", action: nil, keyEquivalent: "")
        intervalItem.submenu = buildRefreshIntervalMenu()
        let servicesItem = NSMenuItem(title: "서비스 선택", action: nil, keyEquivalent: "")
        servicesItem.submenu = buildServicesMenu()
        let colorsItem = NSMenuItem(title: "색상 설정", action: nil, keyEquivalent: "")
        colorsItem.submenu = buildColorMenu()
        let quit = NSMenuItem(title: "종료", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self

        menu.addItem(claudeHeaderItem)
        [claudeFiveHourItem!, claudeWeeklyItem!, claudeStatusItem!].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        menu.addItem(codexHeaderItem)
        [codexFiveHourItem!, codexWeeklyItem!, codexStatusItem!].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        menu.addItem(refreshItem)
        menu.addItem(intervalItem)
        menu.addItem(servicesItem)
        menu.addItem(colorsItem)
        menu.addItem(quit)
        detailMenu = menu
    }

    private enum ColorTarget { case fiveHour, weekly }
    private var editingColorTarget: ColorTarget?

    private func buildColorMenu() -> NSMenu {
        let submenu = NSMenu()
        let fiveItem = NSMenuItem(title: "5H 숫자 색상…", action: #selector(pickFiveHourColor), keyEquivalent: "")
        fiveItem.target = self
        let weekItem = NSMenuItem(title: "1W 숫자 색상…", action: #selector(pickWeeklyColor), keyEquivalent: "")
        weekItem.target = self
        let resetItem = NSMenuItem(title: "기본 색상으로 초기화", action: #selector(resetColors), keyEquivalent: "")
        resetItem.target = self
        submenu.addItem(fiveItem)
        submenu.addItem(weekItem)
        submenu.addItem(.separator())
        submenu.addItem(resetItem)
        return submenu
    }

    @objc private func pickFiveHourColor() { showColorPanel(for: .fiveHour, initial: AppearancePreferences.fiveHourColor) }
    @objc private func pickWeeklyColor() { showColorPanel(for: .weekly, initial: AppearancePreferences.weeklyColor) }

    private func showColorPanel(for target: ColorTarget, initial: NSColor) {
        editingColorTarget = target
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.showsAlpha = false
        panel.color = initial
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        switch editingColorTarget {
        case .fiveHour: AppearancePreferences.fiveHourColor = sender.color
        case .weekly: AppearancePreferences.weeklyColor = sender.color
        case nil: return
        }
        relayoutAndRender()
    }

    @objc private func resetColors() {
        AppearancePreferences.fiveHourColor = .systemOrange
        AppearancePreferences.weeklyColor = .systemTeal
        relayoutAndRender()
    }

    private func buildServicesMenu() -> NSMenu {
        let submenu = NSMenu()
        let claudeToggle = NSMenuItem(title: "Claude 사용", action: #selector(toggleClaudeService), keyEquivalent: "")
        claudeToggle.target = self
        claudeToggle.state = ServicePreferences.claudeEnabled ? .on : .off
        let codexToggle = NSMenuItem(title: "Codex 사용", action: #selector(toggleCodexService), keyEquivalent: "")
        codexToggle.target = self
        codexToggle.state = ServicePreferences.codexEnabled ? .on : .off
        submenu.addItem(claudeToggle)
        submenu.addItem(codexToggle)
        return submenu
    }

    @objc private func toggleClaudeService(_ sender: NSMenuItem) {
        let enabled = !ServicePreferences.claudeEnabled
        ServicePreferences.claudeEnabled = enabled
        sender.state = enabled ? .on : .off
        updateVisibility()
    }

    @objc private func toggleCodexService(_ sender: NSMenuItem) {
        let enabled = !ServicePreferences.codexEnabled
        ServicePreferences.codexEnabled = enabled
        sender.state = enabled ? .on : .off
        updateVisibility()
    }

    private func buildRefreshIntervalMenu() -> NSMenu {
        let submenu = NSMenu()
        for option in Self.refreshIntervalOptions {
            let item = NSMenuItem(title: option.label, action: #selector(refreshIntervalSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.seconds
            item.state = refreshInterval == option.seconds ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func refreshIntervalSelected(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        refreshInterval = seconds
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        scheduleUsageTimers()
    }

    private static func headerItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))
        ])
        return item
    }

    @objc private func openClaudeUsagePage() { NSWorkspace.shared.open(claudeUsageURL) }
    @objc private func openCodexUsagePage() { NSWorkspace.shared.open(codexUsageURL) }
    @objc private func refreshClicked() {
        refreshClaude()
        refreshClaudeAccountInfo()
        refreshClaudeLoginState()
        refreshCodex()
        refreshCodexLoginState()
    }
    @objc private func quitClicked() { NSApp.terminate(nil) }

    // MARK: - Claude data

    private func watchClaudeUsageFile() {
        let path = ClaudeUsageMonitorReader.watchDirectory.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refreshClaude() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directoryWatcher = source
    }

    private func refreshClaude() {
        do {
            let snapshot = try ClaudeUsageMonitorReader.read()
            renderClaude(snapshot)
        } catch {
            renderClaudeError(error)
        }
    }

    private func refreshClaudeAccountInfo() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = ClaudeAccountInfoReader.read()
            Task { @MainActor in
                self?.claudeAccountInfo = info
                self?.refreshClaude()
            }
        }
    }

    private func refreshClaudeLoginState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loggedIn = ClaudeAccountInfoReader.read().loggedIn
            Task { @MainActor in
                guard let self else { return }
                self.claudeLoggedIn = loggedIn
                self.updateVisibility()
            }
        }
    }

    private func renderClaude(_ snapshot: ClaudeUsageSnapshot) {
        let five = snapshot.fiveHour
        let week = snapshot.weekly
        claudeFiveHourItem.attributedTitle = nil
        claudeFiveHourItem.title = line(label: "5H", resetsAt: five?.resetsAt, remaining: five.map(claudeRemaining))
        claudeWeeklyItem.attributedTitle = nil
        claudeWeeklyItem.title = line(label: "1W", resetsAt: week?.resetsAt, remaining: week.map(claudeRemaining))
        let plan = claudeAccountInfo.plan.map { $0.uppercased() } ?? "요금제 알 수 없음"
        let model = claudeAccountInfo.model ?? "모델 알 수 없음"
        claudeStatusItem.title = "최근 확인: \(Self.timeFormatter.string(from: Date())) | \(plan) | \(model)"

        claudeFiveText = five.map { "\(claudeRemaining($0))" } ?? "—"
        claudeWeekText = week.map { "\(claudeRemaining($0))" } ?? "—"
        relayoutAndRender()

        if let five { notifier.check(serviceName: "Claude", windowLabel: "5H", usedPercent: 100 - claudeRemaining(five)) }
        if let week { notifier.check(serviceName: "Claude", windowLabel: "1W", usedPercent: 100 - claudeRemaining(week)) }
    }

    private func renderClaudeError(_ error: Error) {
        claudeFiveText = "—"
        claudeWeekText = "—"
        relayoutAndRender()
        claudeFiveHourItem.attributedTitle = nil
        claudeFiveHourItem.title = "사용량을 불러오지 못했습니다"
        claudeWeeklyItem.attributedTitle = nil
        claudeWeeklyItem.title = error.localizedDescription
        claudeStatusItem.title = "Claude Code를 한 번 이상 사용한 뒤 다시 시도해 주세요"
    }

    private func claudeRemaining(_ window: ClaudeRateLimitWindow) -> Int {
        max(0, min(100, 100 - Int(window.usedPercent.rounded())))
    }

    // MARK: - Codex data

    private var isCodexRefreshing = false

    private func refreshCodex() {
        guard !isCodexRefreshing else { return }
        isCodexRefreshing = true
        codexClient.fetchUsage { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isCodexRefreshing = false
                switch result {
                case .success(let snapshot): self.renderCodex(snapshot)
                case .failure(let error): self.renderCodexError(error)
                }
            }
        }
    }

    private func refreshCodexLoginState() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loggedIn = CodexAccountInfoReader.isLoggedIn()
            Task { @MainActor in
                guard let self else { return }
                self.codexLoggedIn = loggedIn
                self.updateVisibility()
            }
        }
    }

    private func renderCodex(_ snapshot: CodexUsageSnapshot) {
        let five = snapshot.fiveHour
        let week = snapshot.weekly
        codexFiveHourItem.attributedTitle = nil
        codexFiveHourItem.title = line(label: "5H", resetsAt: five?.resetsAt, remaining: five.map(codexRemaining))
        codexWeeklyItem.attributedTitle = nil
        codexWeeklyItem.title = line(label: "1W", resetsAt: week?.resetsAt, remaining: week.map(codexRemaining))
        let plan = snapshot.planType.map { $0.uppercased() } ?? "계획 알 수 없음"
        let model = snapshot.model ?? "모델 알 수 없음"
        let effort = snapshot.reasoningEffort ?? "강도 알 수 없음"
        codexStatusItem.title = "최근 확인: \(Self.timeFormatter.string(from: Date())) | \(plan) | \(model) | \(effort)"

        codexFiveText = five.map { "\(codexRemaining($0))" } ?? "—"
        codexWeekText = week.map { "\(codexRemaining($0))" } ?? "—"
        relayoutAndRender()

        if let five { notifier.check(serviceName: "Codex", windowLabel: "5H", usedPercent: 100 - codexRemaining(five)) }
        if let week { notifier.check(serviceName: "Codex", windowLabel: "1W", usedPercent: 100 - codexRemaining(week)) }
    }

    private func renderCodexError(_ error: Error) {
        codexFiveText = "—"
        codexWeekText = "—"
        relayoutAndRender()
        codexFiveHourItem.attributedTitle = nil
        codexFiveHourItem.title = "사용량을 불러오지 못했습니다"
        codexWeeklyItem.attributedTitle = nil
        codexWeeklyItem.title = error.localizedDescription
        codexStatusItem.title = "Codex CLI 로그인 상태를 확인해 주세요"
    }

    private func codexRemaining(_ window: CodexRateLimitWindow) -> Int {
        max(0, min(100, 100 - window.usedPercent))
    }

    // MARK: - Shared rendering helpers

    private func line(label: String, resetsAt: Date?, remaining: Int?) -> String {
        guard let remaining else { return "\(label): 데이터 없음" }
        let reset = resetsAt.map { Self.resetFormatter.string(from: $0) } ?? "알 수 없음"
        return "\(label)  \(remaining)% 남음 | 갱신 \(reset)"
    }

    private static func claudeIcon() -> NSImage {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.isTemplate = false
            return icon
        }
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude") ?? NSImage()
    }

    private static func codexIcon() -> NSImage {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.isTemplate = false
            return icon
        }
        return NSImage(systemSymbolName: "message.circle.fill", accessibilityDescription: "ChatGPT") ?? NSImage()
    }


    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E) HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@MainActor
private enum ServiceFont {
    static let number = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
}
