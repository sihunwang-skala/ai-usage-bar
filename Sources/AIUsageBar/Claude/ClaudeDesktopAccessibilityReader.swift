import AppKit
import ApplicationServices

/// Reads only the two usage progress indicators rendered by Claude Desktop.
/// This is a fallback for versions of Claude Desktop that stop updating
/// `plan-usage-history.json`. It never reads cookies, tokens, or message text.
enum ClaudeDesktopAccessibilityReader {
    private static let bundleIdentifier = "com.anthropic.claudefordesktop"

    enum ReadError: LocalizedError {
        case permissionRequired
        case appNotRunning
        case usageButtonNotFound
        case valuesNotFound

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                tr("Accessibility permission is needed to read the latest usage from Claude Desktop.", "Claude Desktop의 최신 사용량을 읽으려면 접근성 권한이 필요해요.")
            case .appNotRunning:
                tr("Claude Desktop isn't running.", "Claude Desktop이 실행 중이 아니에요.")
            case .usageButtonNotFound:
                tr("Couldn't find the usage button in Claude Desktop.", "Claude Desktop에서 사용량 버튼을 찾지 못했어요.")
            case .valuesNotFound:
                tr("Couldn't read the usage values in Claude Desktop.", "Claude Desktop의 사용량 값을 읽지 못했어요.")
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func read() throws -> ClaudeUsageSnapshot {
        guard isTrusted else { throw ReadError.permissionRequired }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            throw ReadError.appNotRunning
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let visible = usageValues(in: appElement) {
            return snapshot(fiveHour: visible.fiveHour, weekly: visible.weekly)
        }

        guard let button = firstUsageButton(in: appElement) else {
            throw ReadError.usageButtonNotFound
        }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw ReadError.usageButtonNotFound
        }

        // The popover is rendered by Electron on the next UI pass.
        usleep(250_000)
        defer { _ = AXUIElementPerformAction(button, kAXPressAction as CFString) }

        guard let values = usageValues(in: appElement) else {
            throw ReadError.valuesNotFound
        }
        return snapshot(fiveHour: values.fiveHour, weekly: values.weekly)
    }

    private static func snapshot(fiveHour: Double, weekly: Double) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            fiveHour: ClaudeRateLimitWindow(usedPercent: fiveHour, resetsAt: nil),
            weekly: ClaudeRateLimitWindow(usedPercent: weekly, resetsAt: nil),
            updatedAt: Date()
        )
    }

    private static func firstUsageButton(in root: AXUIElement) -> AXUIElement? {
        firstElement(in: root) { element in
            guard stringAttribute(element, kAXRoleAttribute as CFString) == kAXPopUpButtonRole as String else {
                return false
            }
            let label = stringAttribute(element, kAXDescriptionAttribute as CFString)
                ?? stringAttribute(element, kAXTitleAttribute as CFString)
                ?? ""
            return label.hasPrefix("사용량:") || label.lowercased().hasPrefix("usage:")
        }
    }

    private static func usageValues(in root: AXUIElement) -> (fiveHour: Double, weekly: Double)? {
        var fiveHour: Double?
        var weekly: Double?
        visit(root) { element in
            guard stringAttribute(element, kAXRoleAttribute as CFString) == kAXLevelIndicatorRole as String else {
                return true
            }
            let label = stringAttribute(element, kAXDescriptionAttribute as CFString)
                ?? stringAttribute(element, kAXTitleAttribute as CFString)
                ?? ""
            guard let value = numberAttribute(element, kAXValueAttribute as CFString) else { return true }
            if label.contains("5시간") || label.localizedCaseInsensitiveContains("5 hour") {
                fiveHour = value
            } else if label.contains("주간") || label.localizedCaseInsensitiveContains("weekly") {
                weekly = value
            }
            return fiveHour == nil || weekly == nil
        }
        guard let fiveHour, let weekly else { return nil }
        return (max(0, min(100, fiveHour)), max(0, min(100, weekly)))
    }

    private static func firstElement(
        in root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var result: AXUIElement?
        visit(root) { element in
            if predicate(element) {
                result = element
                return false
            }
            return true
        }
        return result
    }

    /// Traverses roles and labels only. Values are read separately and only for progress indicators.
    private static func visit(_ root: AXUIElement, body: (AXUIElement) -> Bool) {
        var stack = [root]
        var visited = 0
        while let element = stack.popLast(), visited < 20_000 {
            visited += 1
            guard body(element) else { return }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func numberAttribute(_ element: AXUIElement, _ name: CFString) -> Double? {
        (attribute(element, name) as? NSNumber)?.doubleValue
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}
