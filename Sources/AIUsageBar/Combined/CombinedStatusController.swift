import AppKit

/// Claude와 Codex 잔량을 하나의 NSStatusItem 안에, 서비스별로 "아이콘 + 5시간/주간 숫자 2줄"
/// 블록을 나란히 붙여서 보여주는 컨트롤러. 두 서비스를 별도 NSStatusItem으로 나누면 시스템이
/// 항목 사이에 고정 여백을 넣어 메뉴 막대 공간을 많이 차지하므로, 진짜 NSButton 두 개를 하나의
/// 컨테이너에 붙여 쓴다 — image+attributedTitle 조합은 예전 개별 앱 버전에서 이미 검증된
/// 렌더링 경로라 커스텀 텍스트필드보다 훨씬 안정적이다.
@MainActor
final class CombinedStatusController {
    private var statusItem: NSStatusItem!
    private var containerView: NSView!
    private var codexButton: NSButton!
    private var claudeButton: NSButton!
    /// Claude/Codex 둘 다 로그인 안 됐거나 둘 다 꺼져있어서 아이콘이 하나도 없을 때 보여주는
    /// 대체 버튼. 이게 없으면 메뉴 막대 항목이 폭 1pt짜리 실질적으로 안 보이는 상태가 되어,
    /// "설치했는데 아무것도 안 뜬다"는 문의로 이어진다.
    private var fallbackButton: NSButton!

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
    private var claudeConnectItem: NSMenuItem!
    private var codexHeaderItem: NSMenuItem!
    private var codexFiveHourItem: NSMenuItem!
    private var codexWeeklyItem: NSMenuItem!
    private var codexStatusItem: NSMenuItem!
    private var refreshItem: NSMenuItem!

    private let codexClient = CodexAppServerClient()
    private let notifier = ThresholdNotifier()
    private lazy var coach = UsageCoach(notifier: notifier)
    private lazy var coachMenu = CoachMenu(coach: coach)
    private var claudeHistoryItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.isHidden = true
        return item
    }()
    private var claudeGuideItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.isHidden = true
        return item
    }()
    private var codexHistoryItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.isHidden = true
        return item
    }()
    private var codexGuideItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.isHidden = true
        return item
    }()

    private var claudeAccountInfo = ClaudeAccountInfoReader.Info(loggedIn: false, plan: nil, model: nil)
    private var usageTimer: Timer?
    private var claudeAccountTimer: Timer?
    private var codexTimer: Timer?
    private var codexAccountTimer: Timer?
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private var isClaudeAccessibilityRefreshing = false
    private var lastClaudeAccessibilityRefresh: Date?
    private var claudeAccessibilityError: String?

    // Anthropic 사용량 API(계정 전체, 웹/Desktop/터미널 공통). 호출은 최소 60초 간격으로 제한한다.
    private let claudeOAuthReader = ClaudeOAuthUsageReader()
    private var claudeAPISnapshot: ClaudeUsageSnapshot?
    private var claudeAPIError: String?
    private var isClaudeAPIRefreshing = false
    private var nextClaudeAPIAttempt = Date.distantPast
    private static let claudeAPIMinInterval: TimeInterval = 120
    private static let claudeAPIRetryInterval: TimeInterval = 5 * 60
    private static let claudeAPIRateLimitedInterval: TimeInterval = 15 * 60

    // 새로고침 주기: UserDefaults에 저장해 재실행 후에도 유지한다.
    private static let refreshIntervalKey = "refreshIntervalSeconds"
    private static var refreshIntervalOptions: [(label: String, seconds: TimeInterval)] {
        [(tr("Every 30 seconds", "30초마다"), 30), (tr("Every minute", "1분마다"), 60), (tr("Every 5 minutes", "5분마다"), 300)]
    }
    private var refreshInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.refreshIntervalKey)
            return stored > 0 ? stored : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.refreshIntervalKey) }
    }

    private let claudeUsageURL = WebDashboardOpener.claudeUsageURL
    private let codexUsageURL = WebDashboardOpener.codexUsageURL

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

        fallbackButton = Self.makeServiceButton()
        fallbackButton.title = tr("⚠︎ Sign-in needed", "⚠︎ 로그인 필요")
        fallbackButton.imagePosition = .noImage
        fallbackButton.font = ServiceFont.number
        fallbackButton.isHidden = true
        fallbackButton.target = self
        fallbackButton.action = #selector(fallbackButtonClicked)
        containerView.addSubview(fallbackButton)
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

    @objc private func codexButtonClicked() { handleClick(on: codexButton) { GPTIconTarget.current.perform() } }
    @objc private func claudeButtonClicked() { handleClick(on: claudeButton) { ClaudeIconTarget.current.perform() } }

    /// 아이콘을 누르면 그 앱의 사용량 화면이 아니라, 마지막으로 작업하던 창(프로젝트)으로 간다.
    private func handleClick(on button: NSButton, iconAction: () -> Void) {
        guard let event = NSApp.currentEvent else {
            print("[click-debug] handleClick: NSApp.currentEvent is nil")
            return
        }
        print("[click-debug] handleClick: event.type=\(event.type.rawValue)")
        if event.type == .rightMouseUp {
            detailMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
            return
        }
        let local = button.convert(event.locationInWindow, from: nil)
        if local.x <= Self.iconClickThreshold {
            iconAction()
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
        fallbackButton.isHidden = !visible.isEmpty
        if visible.isEmpty {
            fallbackButton.sizeToFit()
            fallbackButton.frame.origin = NSPoint(x: 0, y: 0)
            x = fallbackButton.frame.width
        }
        containerView.frame.size = NSSize(width: max(x, 1), height: containerView.frame.height)
        statusItem.length = containerView.frame.width
    }

    @objc private func fallbackButtonClicked() {
        guard let event = NSApp.currentEvent else {
            print("[click-debug] fallbackButtonClicked: NSApp.currentEvent is nil")
            return
        }
        print("[click-debug] fallbackButtonClicked: event.type=\(event.type.rawValue)")
        if event.type == .rightMouseUp {
            detailMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: fallbackButton)
            return
        }
        let alert = NSAlert()
        alert.messageText = tr("Can't show usage yet", "사용량을 표시할 수 없어요")
        alert.informativeText = tr("""
        At least one of Claude Desktop or the Codex CLI needs to be ready before usage can be shown.

        For Claude, open the usage screen once in the Desktop app.
        For Codex, check your sign-in with `codex login status` in Terminal.

        After signing in, choose "Refresh now" or wait a moment and it will update automatically. (Right-click for the services and refresh menu.)
        """, """
        Claude Desktop 또는 Codex CLI 중 최소 하나가 준비돼 있어야 사용량을 보여줄 수 있어요.

        Claude는 Desktop 앱에서 사용량 화면을 한 번 열어 주세요.
        Codex는 터미널에서 codex login status로 로그인 상태를 확인해 주세요.

        로그인한 뒤에는 "지금 새로고침"을 누르거나 잠시 기다리면 자동으로 반영됩니다. (우클릭하면 서비스 선택·새로고침 메뉴로 바로 갈 수 있어요.)
        """)
        alert.addButton(withTitle: tr("OK", "확인"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        // Claude는 연결 전에도 블록을 보여줘야 사용자가 메뉴에서 계정을 연결할 수 있다.
        let newClaudeVisible = ServicePreferences.claudeEnabled
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
        claudeFiveHourItem = NSMenuItem(title: tr("5H: loading…", "5H: 불러오는 중…"), action: #selector(openClaudeUsagePage), keyEquivalent: "")
        claudeWeeklyItem = NSMenuItem(title: tr("1W: loading…", "1W: 불러오는 중…"), action: #selector(openClaudeUsagePage), keyEquivalent: "")
        claudeStatusItem = NSMenuItem(title: "", action: #selector(openClaudeUsagePage), keyEquivalent: "")
        [claudeFiveHourItem!, claudeWeeklyItem!, claudeStatusItem!].forEach { $0.target = self }
        claudeConnectItem = NSMenuItem(title: tr("Read latest Claude Desktop usage…", "Claude Desktop 최신 사용량 읽기…"), action: #selector(refreshClaudeFromDesktop), keyEquivalent: "")
        claudeConnectItem.target = self
        updateClaudeConnectMenuItem()

        codexHeaderItem = Self.headerItem(title: "Codex")
        codexFiveHourItem = NSMenuItem(title: tr("5H: loading…", "5H: 불러오는 중…"), action: #selector(openCodexUsagePage), keyEquivalent: "")
        codexWeeklyItem = NSMenuItem(title: tr("1W: loading…", "1W: 불러오는 중…"), action: #selector(openCodexUsagePage), keyEquivalent: "")
        codexStatusItem = NSMenuItem(title: "", action: #selector(openCodexUsagePage), keyEquivalent: "")
        [codexFiveHourItem!, codexWeeklyItem!, codexStatusItem!].forEach { $0.target = self }

        refreshItem = NSMenuItem(title: tr("Refresh now", "지금 새로고침"), action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        let intervalItem = NSMenuItem(title: tr("Refresh interval", "새로고침 주기"), action: nil, keyEquivalent: "")
        intervalItem.submenu = buildRefreshIntervalMenu()
        let servicesItem = NSMenuItem(title: tr("Services", "서비스 선택"), action: nil, keyEquivalent: "")
        servicesItem.submenu = buildServicesMenu()
        let colorsItem = NSMenuItem(title: tr("Colors", "색상 설정"), action: nil, keyEquivalent: "")
        colorsItem.submenu = buildColorMenu()
        let notificationsItem = NSMenuItem(title: tr("Alert thresholds", "알림 임계치"), action: nil, keyEquivalent: "")
        notificationsItem.submenu = buildNotificationMenu()
        let testNotificationItem = NSMenuItem(title: tr("Test notification", "알림 테스트"), action: #selector(testNotification), keyEquivalent: "")
        testNotificationItem.target = self
        let soundItem = NSMenuItem(title: tr("Alert sound", "알림 소리"), action: nil, keyEquivalent: "")
        soundItem.submenu = buildSoundMenu()
        let liveItem = NSMenuItem(title: tr("Claude live lookup · every 2 min", "Claude 실시간 조회 · 2분 간격"), action: nil, keyEquivalent: "")
        liveItem.submenu = buildClaudeLiveMenu()
        let taskSourceItem = NSMenuItem(title: tr("Task-done notifications", "작업 완료 알림"), action: nil, keyEquivalent: "")
        taskSourceItem.submenu = buildTaskSourceMenu()
        let quit = NSMenuItem(title: tr("Quit", "종료"), action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self

        menu.addItem(claudeHeaderItem)
        [claudeFiveHourItem!, claudeWeeklyItem!, claudeGuideItem, claudeHistoryItem, claudeStatusItem!].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        menu.addItem(codexHeaderItem)
        [codexFiveHourItem!, codexWeeklyItem!, codexGuideItem, codexHistoryItem, codexStatusItem!].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        // 1) 갱신·서비스
        menu.addItem(refreshItem)
        menu.addItem(intervalItem)
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        // 2) Claude 로그인 정보를 쓰는 기능
        menu.addItem(liveItem)
        menu.addItem(.separator())
        // 3) 알림 관련
        menu.addItem(notificationsItem)
        let preResetItem = NSMenuItem(title: tr("Reset-soon alert", "리셋 임박 알림"), action: nil, keyEquivalent: "")
        preResetItem.submenu = buildPreResetMenu()
        menu.addItem(preResetItem)
        menu.addItem(coachMenu.makeItem())
        menu.addItem(taskSourceItem)
        menu.addItem(soundItem)
        menu.addItem(testNotificationItem)
        menu.addItem(.separator())
        // 4) 표시·동작
        menu.addItem(colorsItem)
        let iconActionItem = NSMenuItem(title: tr("Icon click action", "아이콘 클릭 동작"), action: nil, keyEquivalent: "")
        iconActionItem.submenu = buildIconActionMenu()
        menu.addItem(iconActionItem)
        let languageItem = NSMenuItem(title: "언어 / Language", action: nil, keyEquivalent: "")
        languageItem.submenu = buildLanguageMenu()
        menu.addItem(languageItem)
        menu.addItem(.separator())
        menu.addItem(quit)
        detailMenu = menu
    }

    private static var notificationPresets: [(label: String, thresholds: [Int])] {
        [
            (tr("Every 10%", "10%마다"), [10, 20, 30, 40, 50, 60, 70, 80, 90, 95]),
            (tr("Every 20%", "20%마다"), [20, 40, 60, 80, 90, 95]),
            (tr("Every 25%", "25%마다"), [25, 50, 75, 90]),
            (tr("Alerts off", "알림 끄기"), [])
        ]
    }

    private func buildNotificationMenu() -> NSMenu {
        let submenu = NSMenu()
        let current = NotificationPreferences.thresholds
        for preset in Self.notificationPresets {
            let item = NSMenuItem(title: preset.label, action: #selector(notificationPresetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.thresholds
            item.state = current == preset.thresholds ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let customLabel = Self.notificationPresets.contains(where: { $0.thresholds == current })
            ? tr("Custom…", "직접 입력…")
            : tr("Custom… (now: \(current.map(String.init).joined(separator: ", "))%)", "직접 입력… (현재: \(current.map(String.init).joined(separator: ", "))%)")
        let customItem = NSMenuItem(title: customLabel, action: #selector(customThresholdsClicked), keyEquivalent: "")
        customItem.target = self
        submenu.addItem(customItem)
        return submenu
    }

    @objc private func notificationPresetSelected(_ sender: NSMenuItem) {
        guard let thresholds = sender.representedObject as? [Int] else { return }
        NotificationPreferences.thresholds = thresholds
    }

    @objc private func customThresholdsClicked() {
        let alert = NSAlert()
        alert.messageText = tr("Custom alert thresholds", "알림 임계치 직접 입력")
        alert.informativeText = tr("Enter usage thresholds (%) separated by commas, e.g. 20, 40, 60, 80, 90, 95", "사용률(%) 기준 임계치를 쉼표로 구분해서 입력하세요. 예: 20, 40, 60, 80, 90, 95")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = NotificationPreferences.thresholds.map(String.init).joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: tr("Save", "저장"))
        alert.addButton(withTitle: tr("Cancel", "취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parsed = field.stringValue
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { (0...100).contains($0) }
        guard !parsed.isEmpty else { return }
        NotificationPreferences.thresholds = Array(Set(parsed))
    }

    /// 0 = 사용 안 함(로컬 기록만), 1 = 실시간 조회, 2 = 실시간 조회 + 만료 시 자동 갱신. 셋 중 하나만 고른다.
    private static var claudeLiveMode: Int {
        guard PrivacyPreferences.claudeTokenConsent == true else { return 0 }
        return PrivacyPreferences.claudeTokenRenewal ? 2 : 1
    }

    private func buildClaudeLiveMenu() -> NSMenu {
        let submenu = NSMenu()
        let options: [(Int, String)] = [
            (0, tr("Off (local records only)", "사용 안 함 (로컬 기록만)")),
            (1, tr("Live lookup (uses your Claude Code sign-in)", "실시간 조회 (Claude Code 로그인 정보 사용)")),
            (2, tr("Live lookup + renew expired sign-in", "실시간 조회 + 만료된 로그인 자동 갱신"))
        ]
        for (mode, title) in options {
            let item = NSMenuItem(title: title, action: #selector(claudeLiveModeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = Self.claudeLiveMode == mode ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let note = NSMenuItem(title: tr("Lookups are at least 2 min apart (15 min after a rate limit).", "조회는 최소 2분 간격이에요 (제한되면 15분 쉼)."), action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        return submenu
    }

    @objc private func claudeLiveModeSelected(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Int else { return }
        switch mode {
        case 0:
            PrivacyPreferences.claudeTokenConsent = false
            PrivacyPreferences.claudeTokenRenewal = false
        default:
            if PrivacyPreferences.claudeTokenConsent != true, !PrivacyPreferences.askClaudeTokenConsent() {
                PrivacyPreferences.claudeTokenRenewal = false
                break
            }
            if mode == 2 {
                PrivacyPreferences.askClaudeTokenRenewal()
            } else {
                PrivacyPreferences.claudeTokenRenewal = false
            }
        }
        let current = Self.claudeLiveMode
        sender.menu?.items.forEach { if let m = $0.representedObject as? Int { $0.state = (m == current) ? .on : .off } }
        if current == 0 { claudeAPISnapshot = nil } else { nextClaudeAPIAttempt = .distantPast }
        refreshClaude()
    }

    private func buildIconActionMenu() -> NSMenu {
        let submenu = NSMenu()
        func header(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        header(tr("When you click the GPT icon", "GPT 아이콘을 누르면"))
        for target in GPTIconTarget.allCases {
            let item = NSMenuItem(title: target.title, action: #selector(iconTargetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "gpt:" + target.rawValue
            item.state = GPTIconTarget.current == target ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        header(tr("When you click the Claude icon", "Claude 아이콘을 누르면"))
        for target in ClaudeIconTarget.allCases {
            let item = NSMenuItem(title: target.title, action: #selector(iconTargetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "claude:" + target.rawValue
            item.state = ClaudeIconTarget.current == target ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func iconTargetSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let prefix = parts[0] + ":"
        if parts[0] == "gpt", let target = GPTIconTarget(rawValue: parts[1]) { GPTIconTarget.current = target }
        if parts[0] == "claude", let target = ClaudeIconTarget(rawValue: parts[1]) { ClaudeIconTarget.current = target }
        sender.menu?.items.forEach {
            if let other = $0.representedObject as? String, other.hasPrefix(prefix) { $0.state = ($0 === sender) ? .on : .off }
        }
    }

    private func buildLanguageMenu() -> NSMenu {
        let submenu = NSMenu()
        let current = Localization.preference
        let options: [(String, AppLanguage)] = [
            ("자동 / Auto (System language)", .system), ("English", .english), ("한국어", .korean)
        ]
        for (label, language) in options {
            let item = NSMenuItem(title: label, action: #selector(languageSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = current == language ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    /// 언어를 바꾸면 메뉴와 상태 문구를 새 언어로 다시 만든다.
    @objc private func languageSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        Localization.preference = language
        buildDetailMenu()
        refreshClaude()
        refreshCodex()
    }

    private func buildTaskSourceMenu() -> NSMenu {
        let submenu = NSMenu()
        let current = NotificationPreferences.taskSource
        func addOption(_ label: String, _ value: String) {
            let item = NSMenuItem(title: label, action: #selector(taskSourceSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = current == value ? .on : .off
            submenu.addItem(item)
        }
        addOption(tr("AI Usage Bar notifications (click to jump to that desktop)", "AI Usage Bar 알림 (눌러서 그 데스크톱으로 이동)"), NotificationPreferences.taskSourceUsageBar)
        addOption(tr("Claude's own notifications (AI Usage Bar sends usage alerts only)", "Claude 자체 알림 (AI Usage Bar는 사용량 임계치만)"), NotificationPreferences.taskSourceClaude)
        submenu.addItem(.separator())
        let note = NSMenuItem(title: tr("If you pick the first, turn off System Settings → Notifications → Claude", "첫 번째를 쓰면 시스템 설정 → 알림 → Claude는 끄세요"), action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(note)
        return submenu
    }

    private func buildPreResetMenu() -> NSMenu {
        let submenu = NSMenu()
        func add(_ title: String, _ action: Selector, _ value: Any?, on: Bool, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add(tr("Alert before 5-hour reset", "5시간 리셋 전에 알리기"), #selector(preResetToggled(_:)), nil, on: NotificationPreferences.preResetEnabled, to: submenu)
        submenu.addItem(.separator())
        let leadMenu = NSMenu()
        for m in [30, 60, 120] {
            add(tr("\(m) min before", "\(m)분 전"), #selector(preResetLeadSelected(_:)), m, on: NotificationPreferences.preResetLeadMinutes == m, to: leadMenu)
        }
        let leadItem = NSMenuItem(title: tr("When", "알리는 시점"), action: nil, keyEquivalent: "")
        leadItem.submenu = leadMenu
        submenu.addItem(leadItem)
        let minMenu = NSMenu()
        for p in [20, 30, 50] {
            add(tr("\(p)% or more left", "\(p)% 이상 남았을 때"), #selector(preResetMinSelected(_:)), p, on: NotificationPreferences.preResetMinRemaining == p, to: minMenu)
        }
        let minItem = NSMenuItem(title: tr("Only if remaining is", "남은 양 기준"), action: nil, keyEquivalent: "")
        minItem.submenu = minMenu
        submenu.addItem(minItem)
        let quietMenu = NSMenu()
        for (i, r) in NotificationPreferences.quietRanges.enumerated() {
            add(String(format: "%02d:00–%02d:00  ✕", r.start, r.end), #selector(quietRangeRemoved(_:)), i, on: true, to: quietMenu)
        }
        if NotificationPreferences.quietRanges.isEmpty {
            let none = NSMenuItem(title: tr("None", "없음"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            quietMenu.addItem(none)
        }
        quietMenu.addItem(.separator())
        add(tr("Add a time range…", "시간대 추가…"), #selector(quietRangeAdd), nil, on: false, to: quietMenu)
        let quietItem = NSMenuItem(title: tr("Quiet hours", "조용한 시간"), action: nil, keyEquivalent: "")
        quietItem.submenu = quietMenu
        submenu.addItem(quietItem)
        let note = NSMenuItem(title: tr("Only sends a heads-up. It never uses Claude/Codex for you.", "알려 주기만 해요. 대신 사용하지는 않아요."), action: nil, keyEquivalent: "")
        note.isEnabled = false
        submenu.addItem(.separator())
        submenu.addItem(note)
        return submenu
    }

    @objc private func preResetToggled(_ sender: NSMenuItem) {
        NotificationPreferences.preResetEnabled.toggle()
        sender.state = NotificationPreferences.preResetEnabled ? .on : .off
    }
    @objc private func preResetLeadSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Int else { return }
        NotificationPreferences.preResetLeadMinutes = v
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
    }
    @objc private func preResetMinSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Int else { return }
        NotificationPreferences.preResetMinRemaining = v
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
    }
    @objc private func quietRangeAdd() {
        let alert = NSAlert()
        alert.messageText = tr("Add quiet hours", "조용한 시간 추가")
        alert.informativeText = tr("Reset alerts are not sent during this time. Hours are 0–23.", "이 시간에는 리셋 임박 알림을 보내지 않아요. 시각은 0~23 중에서 고르세요.")
        let row = NSStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        row.orientation = .horizontal
        func popup(_ initial: Int) -> NSPopUpButton {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: (0..<24).map { String(format: "%02d:00", $0) })
            p.selectItem(at: initial)
            return p
        }
        let from = popup(23), to = popup(8)
        let dash = NSTextField(labelWithString: "→")
        [from, dash, to].forEach { row.addArrangedSubview($0) }
        alert.accessoryView = row
        alert.addButton(withTitle: tr("Add", "추가"))
        alert.addButton(withTitle: tr("Cancel", "취소"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let range = (start: from.indexOfSelectedItem, end: to.indexOfSelectedItem)
        guard range.start != range.end else { return }
        NotificationPreferences.quietRanges.append(range)
    }
    @objc private func quietRangeRemoved(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        var ranges = NotificationPreferences.quietRanges
        guard ranges.indices.contains(i) else { return }
        ranges.remove(at: i)
        NotificationPreferences.quietRanges = ranges
    }

    @objc private func taskSourceSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NotificationPreferences.taskSource = value
        sender.menu?.items.forEach { if $0.representedObject != nil { $0.state = ($0 === sender) ? .on : .off } }
    }

    private func buildSoundMenu() -> NSMenu {
        let submenu = NSMenu()
        let current = NotificationPreferences.soundName
        func addOption(_ label: String, _ value: String) {
            let item = NSMenuItem(title: label, action: #selector(soundOptionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = current == value ? .on : .off
            submenu.addItem(item)
        }
        addOption(tr("Default", "기본음"), NotificationPreferences.defaultSoundName)
        addOption(tr("Silent", "무음"), NotificationPreferences.noSoundName)
        submenu.addItem(.separator())
        for name in NotificationPreferences.systemSoundNames { addOption(name, name) }
        return submenu
    }

    @objc private func soundOptionSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NotificationPreferences.soundName = value
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
        if value != NotificationPreferences.noSoundName && value != NotificationPreferences.defaultSoundName {
            NSSound(named: value)?.play()
        }
    }

    private enum ColorTarget { case fiveHour, weekly }
    private var editingColorTarget: ColorTarget?

    private func buildColorMenu() -> NSMenu {
        let submenu = NSMenu()
        let fiveItem = NSMenuItem(title: tr("5H number color…", "5H 숫자 색상…"), action: #selector(pickFiveHourColor), keyEquivalent: "")
        fiveItem.target = self
        let weekItem = NSMenuItem(title: tr("1W number color…", "1W 숫자 색상…"), action: #selector(pickWeeklyColor), keyEquivalent: "")
        weekItem.target = self
        let resetItem = NSMenuItem(title: tr("Reset to default colors", "기본 색상으로 초기화"), action: #selector(resetColors), keyEquivalent: "")
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
        let claudeToggle = NSMenuItem(title: tr("Use Claude", "Claude 사용"), action: #selector(toggleClaudeService), keyEquivalent: "")
        claudeToggle.target = self
        claudeToggle.state = ServicePreferences.claudeEnabled ? .on : .off
        let codexToggle = NSMenuItem(title: tr("Use Codex", "Codex 사용"), action: #selector(toggleCodexService), keyEquivalent: "")
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
        // 선택한 주기는 Codex와 Claude 로컬 기록에 그대로 적용된다. Claude 실시간 조회만 서버 보호를 위해 최소 2분이다.
        submenu.addItem(.separator())
        let note = NSMenuItem(
            title: tr("Codex and local records follow this. Live Claude lookups are at least 2 min apart.",
                      "Codex와 로컬 기록은 이 주기를 따라요. Claude 실시간 조회는 최소 2분 간격이에요."),
            action: nil, keyEquivalent: ""
        )
        note.isEnabled = false
        submenu.addItem(note)
        return submenu
    }

    @objc private func refreshIntervalSelected(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        refreshInterval = seconds
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        scheduleUsageTimers()
        refreshClaude()
    }

    private static func headerItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))
        ])
        return item
    }

    @objc private func openClaudeUsagePage() { WebDashboardOpener.open(claudeUsageURL) }
    @objc private func openCodexUsagePage() { WebDashboardOpener.open(codexUsageURL) }
    @objc private func refreshClaudeFromDesktop() {
        guard ClaudeDesktopAccessibilityReader.isTrusted else {
            ClaudeDesktopAccessibilityReader.requestPermission()
            updateClaudeConnectMenuItem()
            return
        }
        lastClaudeAccessibilityRefresh = nil
        refreshClaudeAccessibility(force: true)
    }
    @objc private func refreshClicked() {
        nextClaudeAPIAttempt = .distantPast
        refreshClaude()
        refreshClaudeAccountInfo()
        refreshClaudeLoginState()
        refreshCodex()
        refreshCodexLoginState()
    }
    @objc private func quitClicked() { NSApp.terminate(nil) }

    // MARK: - Claude data

    private func watchClaudeUsageFile() {
        watchClaudeDirectory(ClaudeDesktopUsageReader.watchDirectory)
        watchClaudeDirectory(ClaudeUsageMonitorReader.watchDirectory)
    }

    private func watchClaudeDirectory(_ directory: URL) {
        let path = directory.path
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
        directoryWatchers.append(source)
    }

    private func refreshClaude() {
        let desktop = try? ClaudeDesktopUsageReader.read()
        let code = try? ClaudeUsageMonitorReader.read()
        let candidates: [(snapshot: ClaudeUsageSnapshot, source: String)] = [
            claudeAPISnapshot.map { ($0, tr("Claude account-wide · live", "Claude 계정 전체 · 실시간")) },
            desktop.map { ($0, tr("Claude Desktop account-wide", "Claude Desktop 계정 전체")) },
            code.map { ($0, tr("Claude Code local", "Claude Code 로컬")) }
        ].compactMap { $0 }

        let newest = candidates.max(by: {
            ($0.snapshot.updatedAt ?? .distantPast) < ($1.snapshot.updatedAt ?? .distantPast)
        })
        if let newest {
            renderClaude(newest.snapshot, source: newest.source)
        } else {
            renderClaudeError(ClaudeDesktopUsageReader.ReadError.fileNotFound)
        }

        refreshClaudeFromAPI()

        // 화면 읽기(접근성)는 UI를 직접 건드려 비싸므로, 최신값이 없을 때만 보조 수단으로 쓴다.
        let hasFresh = newest.map { !Self.isStale($0.snapshot) } ?? false
        if !hasFresh { refreshClaudeAccessibility(force: false) }
    }

    private static func isStale(_ snapshot: ClaudeUsageSnapshot) -> Bool {
        UsageFreshnessPolicy.evaluate(updatedAt: snapshot.updatedAt, windowResetsAt: nil) != .fresh
    }

    /// 사용량 API 조회. 웹·Desktop·터미널 어디서 썼든 계정 전체 최신값을 가져온다.
    private func refreshClaudeFromAPI() {
        // 사용자가 동의한 경우에만 로그인 토큰을 읽는다.
        guard PrivacyPreferences.claudeTokenConsent == true,
              ServicePreferences.claudeEnabled, !isClaudeAPIRefreshing,
              Date() >= nextClaudeAPIAttempt else { return }
        isClaudeAPIRefreshing = true
        // 비공식 조회 주소라 자주 부르면 429로 막힌다. 새로고침 주기가 짧아도 최소 간격(2분)은 지킨다.
        // 그 사이에는 Desktop/Code 로컬 기록과 화면 값이 계속 갱신된다.
        nextClaudeAPIAttempt = Date().addingTimeInterval(max(refreshInterval - 1, Self.claudeAPIMinInterval))
        let reader = claudeOAuthReader
        let allowRenewal = PrivacyPreferences.claudeTokenRenewal
        Task { [weak self] in
            do {
                let snapshot = try await reader.fetch(allowRenewal: allowRenewal)
                self?.claudeAPIDidSucceed(snapshot)
            } catch {
                self?.claudeAPIDidFail(error)
            }
        }
    }

    private func claudeAPIDidSucceed(_ snapshot: ClaudeUsageSnapshot) {
        isClaudeAPIRefreshing = false
        claudeAPISnapshot = snapshot
        claudeAPIError = nil
        print("[claude-api] ok 5h=\(snapshot.fiveHour?.usedPercent ?? -1) 7d=\(snapshot.weekly?.usedPercent ?? -1)")
        refreshClaude()
    }

    private func claudeAPIDidFail(_ error: Error) {
        isClaudeAPIRefreshing = false
        claudeAPIError = error.localizedDescription
        print("[claude-api] fail \(error.localizedDescription)")
        var wait = Self.claudeAPIRetryInterval
        if case .rateLimited = error as? ClaudeOAuthUsageReader.ReadError { wait = Self.claudeAPIRateLimitedInterval }
        nextClaudeAPIAttempt = Date().addingTimeInterval(wait)
        refreshClaude()
    }

    private func refreshClaudeAccessibility(force: Bool) {
        guard ClaudeDesktopAccessibilityReader.isTrusted, !isClaudeAccessibilityRefreshing else {
            updateClaudeConnectMenuItem()
            return
        }
        if !force,
           let lastClaudeAccessibilityRefresh,
           Date().timeIntervalSince(lastClaudeAccessibilityRefresh) < 5 * 60 {
            return
        }
        isClaudeAccessibilityRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try ClaudeDesktopAccessibilityReader.read() }
            Task { @MainActor in
                guard let self else { return }
                self.isClaudeAccessibilityRefreshing = false
                self.lastClaudeAccessibilityRefresh = Date()
                switch result {
                case .success(let snapshot):
                    self.claudeAccessibilityError = nil
                    self.renderClaude(snapshot, source: tr("Claude Desktop screen (latest)", "Claude Desktop 화면 최신값"))
                case .failure(let error):
                    self.claudeAccessibilityError = error.localizedDescription
                    self.refreshClaude() // 실패 사유를 상태줄에 반영 (화면 읽기는 5분 간격 제한으로 재호출되지 않음)
                }
                self.updateClaudeConnectMenuItem()
            }
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
            let loggedIn = FileManager.default.fileExists(atPath: ClaudeDesktopUsageReader.fileURL.path)
                || ClaudeAccountInfoReader.read().loggedIn
            Task { @MainActor in
                guard let self else { return }
                self.claudeLoggedIn = loggedIn
                self.updateVisibility()
            }
        }
    }

    private func renderClaude(_ snapshot: ClaudeUsageSnapshot, source: String) {
        let five = snapshot.fiveHour
        let week = snapshot.weekly
        let fiveState = UsageFreshnessPolicy.evaluate(updatedAt: snapshot.updatedAt, windowResetsAt: five?.resetsAt)
        let weekState = UsageFreshnessPolicy.evaluate(updatedAt: snapshot.updatedAt, windowResetsAt: week?.resetsAt)
        let stale = fiveState != .fresh || weekState != .fresh
        claudeFiveHourItem.attributedTitle = nil
        claudeFiveHourItem.title = windowLine(label: "5H", resetsAt: five?.resetsAt, remaining: five.map(claudeRemaining), state: fiveState)
        claudeWeeklyItem.attributedTitle = nil
        claudeWeeklyItem.title = windowLine(label: "1W", resetsAt: week?.resetsAt, remaining: week.map(claudeRemaining), state: weekState)
        let plan = claudeAccountInfo.plan.map { $0.uppercased() } ?? tr("plan unknown", "요금제 알 수 없음")
        let model = claudeAccountInfo.model ?? tr("model unknown", "모델 알 수 없음")
        let checkedAt = snapshot.updatedAt.map { Self.timeFormatter.string(from: $0) } ?? tr("unknown", "알 수 없음")
        let staleReason = claudeAPIError ?? claudeAccessibilityError ?? tr("refresh needed from the Claude usage screen", "Claude 사용량 화면에서 갱신 필요")
        let freshness = stale ? tr("stale · \(staleReason)", "오래된 기록 · \(staleReason)") : tr("up to date", "최신 기록")
        claudeStatusItem.title = tr("Last checked: \(checkedAt) | \(freshness) | \(source) | \(plan) | \(model)", "최근 확인: \(checkedAt) | \(freshness) | \(source) | \(plan) | \(model)")
        updateClaudeConnectMenuItem()

        // 믿을 수 없는 값은 숫자로 보여 주지 않는다(특히 100%로 오해되지 않게).
        claudeFiveText = (five != nil && fiveState == .fresh) ? "\(claudeRemaining(five!))" : "—"
        claudeWeekText = (week != nil && weekState == .fresh) ? "\(claudeRemaining(week!))" : "—"
        claudeButton.toolTip = stale
            ? tr("Claude last record: \(checkedAt) (stale)", "Claude 마지막 기록: \(checkedAt) (오래됨)")
            : tr("Claude account-wide usage", "Claude 계정 전체 사용량")
        relayoutAndRender()

        // 오래된 값으로 알림을 보내면 현재 사용량으로 오해할 수 있으므로 최신인 창만 알림·계획에 쓴다.
        if let five, fiveState == .fresh {
            notifier.check(serviceName: "Claude", windowLabel: tr("5-hour", "5시간"), usedPercent: 100 - claudeRemaining(five))
            notifier.checkPreReset(serviceName: "Claude", resetsAt: five.resetsAt, fiveHourRemaining: claudeRemaining(five), weeklyRemaining: weekState == .fresh ? week.map(claudeRemaining) : nil)
        }
        if let week, weekState == .fresh {
            notifier.check(serviceName: "Claude", windowLabel: tr("weekly", "주간"), usedPercent: 100 - claudeRemaining(week))
        }
        updateGuide(claudeGuideItem, claudeHistoryItem, coach.evaluate(
            service: "Claude",
            five: (fiveState == .fresh ? five : nil).map { .init(remaining: claudeRemaining($0), resetsAt: $0.resetsAt) },
            week: (weekState == .fresh ? week : nil).map { .init(remaining: claudeRemaining($0), resetsAt: $0.resetsAt) }
        ))
    }

    private func renderClaudeError(_ error: Error) {
        claudeFiveText = "—"
        claudeWeekText = "—"
        claudeButton.toolTip = tr("Couldn't load Claude usage", "Claude 사용량을 불러오지 못했어요")
        relayoutAndRender()
        claudeFiveHourItem.attributedTitle = nil
        claudeFiveHourItem.title = tr("Couldn't load usage", "사용량을 불러오지 못했어요")
        claudeWeeklyItem.attributedTitle = nil
        claudeWeeklyItem.title = error.localizedDescription
        claudeStatusItem.title = tr("Open the usage screen in Claude Desktop to load account-wide records", "Claude Desktop의 사용량 화면을 열면 계정 전체 기록을 가져와요")
        updateClaudeConnectMenuItem()
    }

    private func updateClaudeConnectMenuItem() {
        guard claudeConnectItem != nil else { return }
        claudeConnectItem.title = ClaudeDesktopAccessibilityReader.isTrusted
            ? tr("Re-read latest Claude Desktop usage", "Claude Desktop 최신 사용량 다시 읽기")
            : tr("Connect latest Claude Desktop usage…", "Claude Desktop 최신 사용량 연결…")
    }

    @objc private func testNotification() {
        notifier.sendTest { [weak self] success in
            guard !success else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = tr("AI Usage Bar notifications are off", "AI Usage Bar 알림이 꺼져 있어요")
                alert.informativeText = tr("Turn on Allow Notifications and banners in System Settings → Notifications → AI Usage Bar.", "시스템 설정 → 알림 → AI Usage Bar에서 알림 허용과 배너를 켜 주세요.")
                alert.addButton(withTitle: tr("Open Notification Settings", "알림 설정 열기"))
                alert.addButton(withTitle: tr("Close", "닫기"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
                _ = self
            }
        }
    }

    private func updateGuide(_ item: NSMenuItem, _ historyItem: NSMenuItem, _ guide: UsageCoach.WeeklyGuide?) {
        item.title = guide?.summary ?? ""
        item.isHidden = guide == nil
        historyItem.title = guide?.history ?? ""
        historyItem.isHidden = guide == nil
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
        let now = Date()
        // Codex 값은 방금 app-server에서 읽은 것이다. 다만 리셋 시각이 이미 지난 창이면 지난 창의 값이라 stale로 본다.
        let fiveState = UsageFreshnessPolicy.evaluate(updatedAt: now, windowResetsAt: five?.resetsAt, now: now)
        let weekState = UsageFreshnessPolicy.evaluate(updatedAt: now, windowResetsAt: week?.resetsAt, now: now)
        codexFiveHourItem.attributedTitle = nil
        codexFiveHourItem.title = windowLine(label: "5H", resetsAt: five?.resetsAt, remaining: five.map(codexRemaining), state: fiveState)
        codexWeeklyItem.attributedTitle = nil
        codexWeeklyItem.title = windowLine(label: "1W", resetsAt: week?.resetsAt, remaining: week.map(codexRemaining), state: weekState)
        let plan = snapshot.planType.map { $0.uppercased() } ?? tr("plan unknown", "계획 알 수 없음")
        let model = snapshot.model ?? tr("model unknown", "모델 알 수 없음")
        let effort = snapshot.reasoningEffort ?? tr("effort unknown", "강도 알 수 없음")
        codexStatusItem.title = tr("Last checked: \(Self.timeFormatter.string(from: now)) | \(plan) | \(model) | \(effort)", "최근 확인: \(Self.timeFormatter.string(from: now)) | \(plan) | \(model) | \(effort)")

        codexFiveText = (five != nil && fiveState == .fresh) ? "\(codexRemaining(five!))" : "—"
        codexWeekText = (week != nil && weekState == .fresh) ? "\(codexRemaining(week!))" : "—"
        relayoutAndRender()

        if let five, fiveState == .fresh {
            notifier.check(serviceName: "Codex", windowLabel: tr("5-hour", "5시간"), usedPercent: 100 - codexRemaining(five))
            notifier.checkPreReset(serviceName: "Codex", resetsAt: five.resetsAt, fiveHourRemaining: codexRemaining(five), weeklyRemaining: weekState == .fresh ? week.map(codexRemaining) : nil)
        }
        if let week, weekState == .fresh {
            notifier.check(serviceName: "Codex", windowLabel: tr("weekly", "주간"), usedPercent: 100 - codexRemaining(week))
        }
        updateGuide(codexGuideItem, codexHistoryItem, coach.evaluate(
            service: "Codex",
            five: (fiveState == .fresh ? five : nil).map { .init(remaining: codexRemaining($0), resetsAt: $0.resetsAt) },
            week: (weekState == .fresh ? week : nil).map { .init(remaining: codexRemaining($0), resetsAt: $0.resetsAt) }
        ))
    }

    private func renderCodexError(_ error: Error) {
        codexFiveText = "—"
        codexWeekText = "—"
        relayoutAndRender()
        codexFiveHourItem.attributedTitle = nil
        codexFiveHourItem.title = tr("Couldn't load usage", "사용량을 불러오지 못했어요")
        codexWeeklyItem.attributedTitle = nil
        codexWeeklyItem.title = error.localizedDescription
        codexStatusItem.title = tr("Please check your Codex CLI sign-in", "Codex CLI 로그인 상태를 확인해 주세요")
    }

    private func codexRemaining(_ window: CodexRateLimitWindow) -> Int {
        max(0, min(100, 100 - window.usedPercent))
    }

    // MARK: - Shared rendering helpers

    /// 값이 믿을 만할 때만 "N% 남음"으로 보여 주고, 아니면 stale / unknown으로 표시한다.
    private func windowLine(label: String, resetsAt: Date?, remaining: Int?, state: UsageFreshness) -> String {
        switch state {
        case .fresh:
            return line(label: label, resetsAt: resetsAt, remaining: remaining)
        case .stale:
            guard let remaining else { return tr("\(label): no data", "\(label): 데이터 없음") }
            return tr("\(label)  stale (last known: \(remaining)% left)", "\(label)  오래된 값 (마지막 확인: \(remaining)% 남음)")
        case .unknown:
            return tr("\(label)  unknown", "\(label)  알 수 없음")
        }
    }

    private func line(label: String, resetsAt: Date?, remaining: Int?) -> String {
        guard let remaining else { return tr("\(label): no data", "\(label): 데이터 없음") }
        guard let resetsAt else { return tr("\(label)  \(remaining)% left", "\(label)  \(remaining)% 남음") }
        let reset = Self.resetFormatter.string(from: resetsAt)
        return tr("\(label)  \(remaining)% left | resets \(reset)", "\(label)  \(remaining)% 남음 | 초기화 \(reset)")
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


    private static var resetFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateFormat = tr("MMM d (E) HH:mm", "M월 d일 (E) HH:mm")
        return formatter
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }
}

@MainActor
private enum ServiceFont {
    static let number = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
}
