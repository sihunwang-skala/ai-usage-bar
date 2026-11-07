import AppKit
import ApplicationServices
import CoreGraphics

/// 알림을 눌렀을 때, 그 알림을 보낸 Claude 세션이 열려 있던 Space(가상 데스크탑)로 전환한다.
/// Claude 창이 여러 Space에 흩어져 있어도 "그 Space"로 간다. 현재 화면의 창을 끌어오지 않는다.
///
/// - 추적은 이벤트 기반이다(Claude 앱이 앞으로 오거나 빠질 때, Space가 바뀔 때만 기록). 폴링하지 않는다.
/// - Space 조회·전환은 공개 API가 없어 시스템의 비공개 CGS 함수를 dlsym으로 찾아 쓴다. 심볼이 없거나
///   동작하지 않으면 조용히 건너뛰고 일반 앱 활성화로 대체한다(이 경우 macOS가 정하는 Space로 이동).
@MainActor
final class ClaudeWindowFocuser {
    static let shared = ClaudeWindowFocuser()

    private static let bundleIdentifier = "com.anthropic.claudefordesktop"
    private static let launchURL = WebDashboardOpener.claudeUsageURL

    private static let sessionsDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    private var lastWindowID: CGWindowID?
    private var observers: [NSObjectProtocol] = []
    /// 창 ID → 그 창에 마지막으로 열렸던 Desktop 세션 ID(local_…).
    private var windowSessions: [CGWindowID: String] = [:]
    /// 세션 ID → 그 세션을 마지막으로 띄운 Space(데스크탑) ID. Space ID는 Claude 재시작·재부팅 후에도 유지돼
    /// 파일에 저장해 둔다. 창 ID는 재시작하면 바뀌어서 쓸 수 없다.
    private var sessionSpaces: [String: UInt64] = {
        let stored = UserDefaults.standard.dictionary(forKey: "claudeSessionSpaces") as? [String: NSNumber] ?? [:]
        return stored.mapValues { $0.uint64Value }
    }()
    private var lastFocusedAt: Double = 0
    private var sessionStream: FSEventStreamRef?

    private var claudeApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first
    }

    // MARK: - Tracking

    func startTracking() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let bundleID = Self.bundleIdentifier

        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == bundleID else { return }
                Task { @MainActor in self?.recordFrontWindow() }
            })
        }
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.claudeApp?.isActive == true else { return }
                self?.recordFrontWindow()
            }
        })
        recordFrontWindow()
        lastFocusedAt = Self.mostRecentlyFocusedSession()?.focusedAt ?? 0
        watchSessions()
        // 창 제목을 읽으려면 화면 기록 권한, 분할화면에서 정확한 창을 올리려면 손쉬운 사용 권한이 필요하다.
        // 없을 때만 시스템 요청 창을 띄운다(이미 거절했으면 macOS가 다시 띄우지 않는다).
        print("[focus] permissions screenRecording=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted()) knownSessionSpaces=\(sessionSpaces.count)")
    }

    /// 창 제목을 읽으려면 화면 기록 권한, 분할화면에서 정확한 창을 올리려면 손쉬운 사용 권한이 필요하다.
    /// 앱 시작 때가 아니라 알림을 처음 눌렀을 때, 그리고 없을 때만 요청한다.
    private func requestPermissionsIfNeeded() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    // MARK: - Session ↔ window

    /// Desktop은 세션을 화면에 띄울 때마다 세션 파일의 lastFocusedAt을 갱신한다. 그 값이 새로 바뀐 순간
    /// 가장 앞에 있는 Claude 창이 곧 그 세션을 띄운 창이므로, 이 때만 창↔세션을 기록한다(폴링 없음).
    private func watchSessions() {
        guard sessionStream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let focuser = Unmanaged<ClaudeWindowFocuser>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { focuser.sessionsDidChange() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [Self.sessionsDirectory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        sessionStream = stream
    }

    private func sessionsDidChange() {
        guard let newest = Self.mostRecentlyFocusedSession(), newest.focusedAt > lastFocusedAt else { return }
        lastFocusedAt = newest.focusedAt
        guard let pid = claudeApp?.processIdentifier,
              let front = Self.claudeWindowIDs(pid: pid, onScreenOnly: true).first else { return }
        // 한 세션은 한 창에만 열려 있다고 본다.
        windowSessions = windowSessions.filter { $0.value != newest.id }
        windowSessions[front] = newest.id
        lastWindowID = front
        if let space = Self.spaceID(ofWindow: front) {
            sessionSpaces[newest.id] = space
            UserDefaults.standard.set(sessionSpaces.mapValues { NSNumber(value: $0) }, forKey: "claudeSessionSpaces")
        }
        print("[focus] learned session=\(newest.id) window=\(front) space=\(Self.spaceID(ofWindow: front).map(String.init) ?? "nil")")
    }

    private static func sessionTitle(_ sessionID: String) -> String? {
        guard let files = FileManager.default.enumerator(at: sessionsDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in files where url.lastPathComponent == "\(sessionID).json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return nil
    }

    private static func allSessionTitles() -> Set<String> {
        guard let files = FileManager.default.enumerator(at: sessionsDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        var titles = Set<String>()
        for case let url as URL in files where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["title"] as? String, !title.isEmpty else { continue }
            titles.insert(title)
        }
        return titles
    }

    /// 세션을 띄운 Claude 창을 찾는다. 모든 Space를 본다(창 제목은 화면 기록 권한이 있어야 보인다).
    /// 1) 창 제목 = 세션 제목  2) 소거법: 어떤 세션 제목과도 안 맞는 창이 딱 하나면 그 창.
    /// 애매하면 nil. 엉뚱한 창으로 가는 것보다 아무것도 안 하는 편이 낫다.
    private static func claudeWindow(forSession sessionID: String, pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let windows: [(id: CGWindowID, title: String)] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? NSNumber)?.doubleValue ?? 0 >= 300,
                  (bounds["Height"] as? NSNumber)?.doubleValue ?? 0 >= 200,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            return (id, title)
        }
        guard !windows.isEmpty else { return nil }
        if let title = sessionTitle(sessionID), let match = windows.first(where: { $0.title == title }) {
            return match.id
        }
        let known = allSessionTitles()
        let unmatched = windows.filter { !known.contains($0.title) }
        return unmatched.count == 1 ? unmatched[0].id : nil
    }

    private static func mostRecentlyFocusedSession() -> (id: String, focusedAt: Double)? {
        guard let files = FileManager.default.enumerator(at: sessionsDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        var newest: (id: String, focusedAt: Double)?
        for case let url as URL in files where url.lastPathComponent.hasPrefix("local_")
            && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["sessionId"] as? String,
                  let focusedAt = (object["lastFocusedAt"] as? NSNumber)?.doubleValue else { continue }
            if focusedAt > (newest?.focusedAt ?? 0) { newest = (id, focusedAt) }
        }
        return newest
    }

    /// 현재 Space에서 가장 앞에 있는 Claude 창을 "마지막으로 쓴 창"으로 기록한다.
    /// 현재 Space에 Claude 창이 없으면(다른 Space로 넘어간 직후 등) 기존 기록을 유지한다.
    private func recordFrontWindow() {
        guard let pid = claudeApp?.processIdentifier,
              let id = Self.claudeWindowIDs(pid: pid, onScreenOnly: true).first else { return }
        lastWindowID = id
    }

    /// 앞쪽 창부터 정렬된 Claude의 일반 창 ID. 크기가 작은 보조 창(툴팁·팝오버 등)은 제외한다.
    private static func claudeWindowIDs(pid: pid_t, onScreenOnly: Bool) -> [CGWindowID] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 300, height >= 200,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return number
        }
    }

    // MARK: - Focus

    /// Claude Desktop의 "코드" 화면에서 새 세션을 연다.
    private static let codeNewSessionURL = URL(string: "claude://code/new?source=desktop_action")!

    /// 사용량 알림 클릭 시 호출. 마지막으로 쓰던 Claude 창이 있는 데스크톱으로 이동한다. Claude가 꺼져 있으면 실행만 한다.
    func focus() {
        guard let app = claudeApp else {
            WebDashboardOpener.openApp(bundleIdentifier: Self.bundleIdentifier, fallback: Self.launchURL)
            return
        }
        let pid = app.processIdentifier
        let allWindows = Self.claudeWindowIDs(pid: pid, onScreenOnly: false)
        let target = lastWindowID.flatMap { allWindows.contains($0) ? $0 : nil } ?? allWindows.first
        bring(target, pid: pid)
    }

    /// 메뉴 막대 Claude 아이콘 클릭 시 호출. 지금 보고 있는 데스크톱에 Claude 새 창을 열고 코드 화면을 보여준다.
    /// 다른 데스크톱에 있는 기존 창은 건드리지 않는다(앱 전체 활성화·딥링크로 기존 창을 끌어오지 않는다).
    /// Claude의 "새 창" 메뉴를 접근성으로 눌러 열고, 안 되면 새 코드 세션 주소로 대신한다.
    func openNewWindow(then url: URL) {
        guard let app = claudeApp else {
            NSWorkspace.shared.open(url)
            return
        }
        let opened = Self.pressNewWindowMenu(pid: app.processIdentifier)
        print("[focus] new window via menu: \(opened)")
        Task { @MainActor in
            // 새 창이 앞으로 올 때까지 잠깐 기다린 뒤, 그 창(가장 앞의 창)에서 코드 화면을 연다.
            try? await Task.sleep(nanoseconds: opened ? 700_000_000 : 0)
            NSWorkspace.shared.open(url)
        }
    }

    /// Claude의 메뉴 막대에서 "새 창" 항목을 찾아 누른다. 메뉴 이름이 언어에 따라 달라서 이름으로 찾는다.
    private static func pressNewWindowMenu(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else {
            print("[focus] accessibility permission is needed to open a new window")
            return false
        }
        let app = AXUIElementCreateApplication(pid)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBar else { return false }
        let names = ["new window", "새 윈도우", "새 창", "新規ウインドウ", "新建窗口", "nouvelle fenêtre", "neues fenster"]

        func title(_ element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 5 else { return nil }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let items = children as? [AXUIElement] else { return nil }
            for item in items {
                if let name = title(item)?.lowercased(), names.contains(where: { name.hasPrefix($0) }) { return item }
                if let found = search(item, depth: depth + 1) { return found }
            }
            return nil
        }
        // 가장 왼쪽 Apple 메뉴를 빼고 찾는다.
        guard let item = search(menuBar as! AXUIElement, depth: 0) else {
            print("[focus] no 'New Window' menu item found in Claude")
            return false
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// 작업 완료 알림 클릭 시 호출. 그 세션이 열려 있던 Space(데스크탑)로 전환한다.
    /// 현재 화면의 창을 위로 끌어오거나 현재 창에서 페이지만 바꾸는 일은 하지 않는다(딥링크 폴백 없음).
    func focus(sessionID: String) {
        requestPermissionsIfNeeded()
        guard let app = claudeApp else {
            NSWorkspace.shared.open(URL(string: "claude://code/continue?session=\(sessionID)&source=notification")!)
            return
        }
        let pid = app.processIdentifier
        let allWindows = Self.claudeWindowIDs(pid: pid, onScreenOnly: false)
        // 1) 창 제목 = 세션 제목(화면 기록 권한이 있을 때만 제목이 보인다) 2) 세션을 띄웠을 때 기록해 둔 Space
        // 둘 다 없으면 아무것도 하지 않는다(마지막으로 쓴 창으로 가는 폴백은 엉뚱한 창을 띄워서 뺐다).
        let titled = Self.claudeWindow(forSession: sessionID, pid: pid)
        let learned = windowSessions.first(where: { $0.value == sessionID && allWindows.contains($0.key) })?.key
        let window = titled ?? learned
        let space = window.flatMap { Self.spaceID(ofWindow: $0) }
            ?? sessionSpaces[sessionID]
        print("[focus] click session=\(sessionID) titled=\(titled.map(String.init) ?? "nil") learned=\(learned.map(String.init) ?? "nil") space=\(space.map(String.init) ?? "nil")")
        bring(window: window, space: space, pid: pid)
    }

    private func bring(_ target: CGWindowID?, pid: pid_t) {
        bring(window: target, space: target.flatMap { Self.spaceID(ofWindow: $0) }, pid: pid)
    }

    /// `afterArrival`은 그 Space에 도착한 뒤(또는 이동이 필요 없을 때) 한 번 실행한다.
    private func bring(window: CGWindowID?, space: UInt64?, pid: pid_t, afterArrival: (() -> Void)? = nil) {
        guard let space else {
            print("[focus] no target window/space for this session, doing nothing")
            afterArrival?()
            return
        }
        Task { @MainActor in
            let switched = await Self.switchToSpace(id: space)
            print("[focus] space=\(space) switchedSpace=\(switched) now=\(Self.activeSpaceID().map(String.init) ?? "nil")")
            // 앱 전체를 활성화하면 macOS가 마지막에 쓴 다른 창(다른 Space)을 앞으로 끌어올 수 있다.
            // 그래서 어느 창인지 알고 그 Space에 도착했을 때만 활성화하고, 모르면 Space 전환만 한다.
            let arrived = switched || space == Self.activeSpaceID()
            if arrived, let window {
                if switched { try? await Task.sleep(nanoseconds: 300_000_000) }
                NSRunningApplication(processIdentifier: pid)?.activate()
                Self.raise(windowID: window, pid: pid)
            }
            // 도착했을 때만 후속 동작(코드 화면 열기)을 한다. 못 갔는데 열면 엉뚱한 창에서 열린다.
            if arrived { afterArrival?() }
        }
    }

    // MARK: - Private CGS (best effort)

    private typealias MainConnectionFn = @convention(c) () -> UInt32
    private typealias ActiveSpaceFn = @convention(c) (UInt32) -> UInt64
    private typealias SpacesForWindowsFn = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn = @convention(c) (UInt32, CFString, UInt64) -> Void
    private typealias AXWindowIDFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func activeSpaceID() -> UInt64? {
        guard let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionFn.self),
              let activeSpace = symbol("CGSGetActiveSpace", as: ActiveSpaceFn.self) else { return nil }
        return activeSpace(mainConnection())
    }

    /// 창이 속한 Space ID.
    private static func spaceID(ofWindow windowID: CGWindowID) -> UInt64? {
        guard let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionFn.self),
              let spacesForWindows = symbol("CGSCopySpacesForWindows", as: SpacesForWindowsFn.self) else { return nil }
        let windows = [NSNumber(value: windowID)] as CFArray
        let spaces = spacesForWindows(mainConnection(), 0x7, windows)?.takeRetainedValue() as NSArray?
        return (spaces?.firstObject as? NSNumber)?.uint64Value
    }

    /// 그 Space로 전환한다. 시스템 단축키를 대신 눌러서 macOS가 직접 전환하게 한다.
    /// 번호 단축키("데스크탑 N으로 전환")가 켜져 있으면 가장 가까운 번호 데스크탑으로 한 번에 점프한 뒤,
    /// 남은 칸은 "왼쪽/오른쪽으로 Space 이동"(제어+←/→)으로 한 칸씩 간다. 분할 화면·전체 화면 Space에는
    /// 번호가 없어서 이 방식이 필요하다. 점프가 더 멀면 처음부터 한 칸씩 간다.
    /// 내부 CGS 함수로 Space를 지정하는 방식은 화면이 실제로 안 바뀌어서 쓰지 않는다.
    /// 실제로 도착했으면 true(이미 그 Space거나, 순서를 모르거나, 키가 안 먹으면 false).
    private static func switchToSpace(id targetSpace: UInt64) async -> Bool {
        guard let current = activeSpaceID(), targetSpace != current else { return false }
        guard let spaces = orderedSpaces(containing: targetSpace),
              let currentIndex = spaces.firstIndex(where: { $0.id == current }),
              let targetIndex = spaces.firstIndex(where: { $0.id == targetSpace }) else {
            print("[focus] cannot work out how far space \(targetSpace) is from \(current)")
            return false
        }
        guard AXIsProcessTrusted() else {
            print("[focus] accessibility permission is needed to press the Space shortcut")
            return false
        }

        // 점프 1번을 한 칸 이동과 같은 비용으로 보고 가장 싼 계획을 고른다.
        var jump: (index: Int, shortcut: (keyCode: CGKeyCode, flags: CGEventFlags))?
        var best = abs(targetIndex - currentIndex)
        var number = 0
        for (index, space) in spaces.enumerated() where space.type == 0 {
            number += 1
            guard let shortcut = desktopShortcut(number) else { continue }
            let cost = 1 + abs(targetIndex - index)
            if cost < best { best = cost; jump = (index, shortcut) }
        }

        var last = current
        if let jump {
            postKey(jump.shortcut.keyCode, flags: jump.shortcut.flags)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if activeSpaceID() == spaces[jump.index].id { break }
            }
            last = activeSpaceID() ?? last
            print("[focus] jumped to space \(spaces[jump.index].id) (index \(jump.index)) active=\(last)")
            guard last == spaces[jump.index].id else { return false }
            if last == targetSpace { return true }
        }

        let from = spaces.firstIndex(where: { $0.id == last }) ?? currentIndex
        let steps = targetIndex - from
        let key: CGKeyCode = steps > 0 ? 124 : 123  // → / ←
        for index in 0..<abs(steps) {
            postKey(key, flags: [.maskControl, .maskSecondaryFn])
            // 전환 애니메이션이 끝나 현재 Space가 바뀔 때까지 기다린다. 끝내 안 바뀌면 키가 안 먹은 것이다.
            var moved = false
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let now = activeSpaceID(), now != last { last = now; moved = true; break }
            }
            print("[focus] step \(index + 1)/\(abs(steps)) moved=\(moved) active=\(last)")
            if !moved { return false }
        }
        return last == targetSpace
    }

    /// 목표 Space가 있는 디스플레이의 Space를 왼쪽부터 순서대로(ID와 종류: 0=일반 데스크탑, 4=분할/전체 화면).
    private static func orderedSpaces(containing target: UInt64) -> [(id: UInt64, type: Int)]? {
        guard let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionFn.self),
              let displaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: DisplaySpacesFn.self),
              let displays = displaySpaces(mainConnection())?.takeRetainedValue() as NSArray? else { return nil }
        for case let display as [String: Any] in displays {
            guard let list = display["Spaces"] as? [[String: Any]] else { continue }
            let spaces = list.compactMap { entry -> (id: UInt64, type: Int)? in
                guard let id = (entry["id64"] as? NSNumber)?.uint64Value else { return nil }
                return (id, (entry["type"] as? NSNumber)?.intValue ?? 0)
            }
            if spaces.contains(where: { $0.id == target }) { return spaces }
        }
        return nil
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// 사용자가 켜 둔 "데스크탑 N으로 전환" 단축키(기본값은 제어+N). 꺼져 있으면 nil.
    private static func desktopShortcut(_ number: Int) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard (1...16).contains(number),
              let all = CFPreferencesCopyAppValue(
                  "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString
              ) as? [String: Any],
              let entry = all[String(117 + number)] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return nil }
        return (CGKeyCode(parameters[1].uint16Value), CGEventFlags(rawValue: parameters[2].uint64Value))
    }

    /// 접근성 권한이 있으면 해당 창을 맨 앞으로 올린다. 권한이 없으면 건너뛴다(앱 활성화만 적용).
    private static func raise(windowID: CGWindowID, pid: pid_t) {
        guard AXIsProcessTrusted(),
              let windowIDOf = symbol("_AXUIElementGetWindow", as: AXWindowIDFn.self) else { return }
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var id: CGWindowID = 0
            if windowIDOf(window, &id) == .success, id == windowID {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }
}
