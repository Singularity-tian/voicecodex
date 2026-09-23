import AppKit
import ApplicationServices
import VoiceCodexCore

enum MacControlError: LocalizedError {
    case noTarget, unavailableApplication, accessibilityRequired, focusChanged
    case unsupported, noEditableField, protectedField, terminalInput, staleElement
    case noControls, noWindow, blockedByDialog, actionFailed

    var errorDescription: String? {
        switch self {
        case .noTarget: return "请先切换到要控制的 App，再按住语音快捷键。"
        case .unavailableApplication: return "找不到这次指令指定的 App。"
        case .accessibilityRequired: return "请在设置中为 VoiceCodex 开启辅助功能权限。"
        case .focusChanged: return "目标 App 的焦点已变化，这次操作已停止。"
        case .unsupported: return "这个操作暂不支持；请换成打开 App、新窗口、输入文字或点击可见按钮。"
        case .noEditableField: return "没有找到可以安全输入文字的编辑框，请先点进目标编辑框。"
        case .protectedField: return "不会读取或修改密码等受保护的输入框。"
        case .terminalInput: return "语音 Mac 控制不会向终端或命令输入框输入、粘贴或回车。"
        case .staleElement: return "界面在识别后发生了变化，请重新说一次点击指令。"
        case .noControls: return "当前窗口没有提供可操作的辅助功能控件。"
        case .noWindow: return "目标 App 没有可操作的窗口。"
        case .blockedByDialog: return "目标 App 有待处理的对话框，请先处理后再继续。"
        case .actionFailed: return "系统没有接受这次操作；没有自动重试。"
        }
    }
}

/// Executes a small native action vocabulary. Jev selects an intent or an
/// observed element ID; it never supplies executable code or screen coordinates.
@MainActor
final class MacControlDriver {
    private(set) var foregroundApplicationID: String?
    private var activationObserver: NSObjectProtocol?
    private var applicationURLs: [String: URL] = [:]
    private let workspace = NSWorkspace.shared
    private let axTimeout: Float = 0.15

    init() {
        captureForegroundApplication()
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.rememberExternalApplication(app) }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Call only from an explicit settings button, never from execute().
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func captureForegroundApplication() {
        if let app = workspace.frontmostApplication { rememberExternalApplication(app) }
    }

    private func rememberExternalApplication(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, let id = app.bundleIdentifier, Self.isValidApplicationID(id) else { return }
        foregroundApplicationID = id
    }

    func applications() -> [MacApplication] {
        var urls: [String: URL] = [:]
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let entries = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var count = 0
            while let url = entries.nextObject() as? URL, count < 2_000 {
                count += 1
                if url.pathExtension == "app" {
                    entries.skipDescendants()
                    if let id = Bundle(url: url)?.bundleIdentifier, urls[id] == nil { urls[id] = url }
                } else if entries.level > 3 { entries.skipDescendants() }
            }
        }
        // Includes standard apps such as Finder that live outside those roots.
        for app in workspace.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, let url = app.bundleURL, urls[id] == nil { urls[id] = url }
        }
        urls = urls.filter { $0.key != Bundle.main.bundleIdentifier }
        let running = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        let applications = Array(urls.compactMap { id, url -> MacApplication? in
            let bundle = Bundle(url: url)
            return Self.applicationMetadata(id: id, names: [
                bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                url.deletingPathExtension().lastPathComponent
            ])
        }.sorted {
            if ($0.id == foregroundApplicationID) != ($1.id == foregroundApplicationID) { return $0.id == foregroundApplicationID }
            if running.contains($0.id) != running.contains($1.id) { return running.contains($0.id) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(2_000))
        let validIDs = Set(applications.map(\.id))
        applicationURLs = urls.filter { validIDs.contains($0.key) }
        return applications
    }

    nonisolated static func isValidApplicationID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }

    /// Some installed app bundles explicitly set an empty display name. Treat
    /// unusable labels as missing metadata so one app cannot invalidate a plan.
    nonisolated static func applicationMetadata(id: String, names: [String?]) -> MacApplication? {
        guard isValidApplicationID(id) else { return nil }
        let usable = names.compactMap { $0 }.map {
            $0.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty && $0.count <= 200 }
        return MacApplication(id: id, name: usable ?? String(id.prefix(200)))
    }

    func needsAccessibility(for intent: MacIntent) -> Bool {
        intent != .openApp && intent != .unsupported
    }

    func requiresConfirmation(_ command: MacCommand) -> Bool {
        switch command.intent {
        case .closeAllWindows, .pressReturn, .paste, .clickElement: return true
        default: return false
        }
    }

    func execute(command: MacCommand, goal: String = "", jev: JevClient) async throws -> String {
        try Task.checkCancellation()
        guard command.intent != .unsupported else { throw MacControlError.unsupported }
        guard let id = command.applicationID ?? foregroundApplicationID else { throw MacControlError.noTarget }
        if applicationURLs.isEmpty { _ = applications() }
        guard let url = applicationURLs[id] else { throw MacControlError.unavailableApplication }
        if needsAccessibility(for: command.intent), !accessibilityGranted { throw MacControlError.accessibilityRequired }

        if command.intent == .openApp {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try Task.checkCancellation()
            let app = try await workspace.openApplication(at: url, configuration: configuration)
            return "已打开 \(app.localizedName ?? id)；已观察到应用进程。"
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) else {
            throw MacControlError.unavailableApplication
        }
        try await focus(app)
        let ax = applicationElement(app)
        let name = app.localizedName ?? id
        switch command.intent {
        case .newTab:
            guard Self.tabApplicationIDs.contains(id) else { throw MacControlError.unsupported }
            try shortcut(17, flags: .maskCommand, app: app)
            return "已向 \(name) 发送新标签页快捷键（⌘T）；页面是否加载完成尚未验证。"
        case .newWindow:
            guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
            let before = try? windowSnapshot(ax)
            try shortcut(45, flags: .maskCommand, app: app)
            try await Task.sleep(nanoseconds: 180_000_000)
            if let before, let after = try? windowSnapshot(ax),
               after.contains(where: { candidate in !before.contains(where: { CFEqual(candidate, $0) }) }) {
                return "已观察到 \(name) 新建了窗口。"
            }
            return "已向 \(name) 发送新建快捷键（⌘N）；由该 App 决定新建窗口、文稿或便笺。"
        case .closeWindow: return try await closeWindows(app: app, all: false)
        case .closeAllWindows: return try await closeWindows(app: app, all: true)
        case .typeText:
            guard let text = command.text, !text.isEmpty else { throw MacControlError.noEditableField }
            let observed = try insertLiteralText(text, app: app, ax: ax)
            return observed ? "已读取并确认 \(name) 编辑框中的文字更新；未发送回车。"
                : "\(name) 已接受文字写入；无法读取确认最终内容，未发送回车。"
        case .pressReturn:
            let field = try validateInputContext(app: app, ax: ax, requireEditable: false)
            try verifyFocusedElement(field, app: app, ax: ax)
            try shortcut(36, flags: [], app: app)
            return "已向 \(name) 发送回车；提交结果尚未验证。"
        case .copy:
            try rejectProtectedField(elementAttribute(ax, kAXFocusedUIElementAttribute))
            try shortcut(8, flags: .maskCommand, app: app)
            return "已向 \(name) 发送复制快捷键；未读取剪贴板。"
        case .paste:
            let field = try validateInputContext(app: app, ax: ax, requireEditable: true)
            try verifyFocusedElement(field, app: app, ax: ax)
            try shortcut(9, flags: .maskCommand, app: app)
            return "已向 \(name) 发送粘贴快捷键；粘贴结果尚未验证。"
        case .undo:
            try shortcut(6, flags: .maskCommand, app: app)
            return "已向 \(name) 发送撤销快捷键；撤销结果尚未验证。"
        case .scrollDown, .scrollUp:
            guard let window = elementAttribute(ax, kAXFocusedWindowAttribute) else { throw MacControlError.noWindow }
            guard let point = center(of: window), let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: command.intent == .scrollDown ? -500 : 500, wheel2: 0, wheel3: 0) else {
                throw MacControlError.actionFailed
            }
            event.location = point
            try verifyFocus(app)
            event.postToPid(app.processIdentifier)
            return "已向 \(name) 当前窗口发送滚动；滚动位置尚未验证。"
        case .clickElement:
            return try await click(goal: goal.isEmpty ? (command.text ?? "") : goal, app: app, jev: jev)
        case .openApp, .unsupported: throw MacControlError.unsupported
        }
    }

    private func focus(_ app: NSRunningApplication) async throws {
        try Task.checkCancellation()
        guard !app.isTerminated, app.activate(options: []) else { throw MacControlError.focusChanged }
        try await Task.sleep(nanoseconds: 180_000_000)
        try verifyFocus(app)
    }

    private func verifyFocus(_ app: NSRunningApplication) throws {
        try Task.checkCancellation()
        guard !app.isTerminated, workspace.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw MacControlError.focusChanged
        }
    }

    private func shortcut(_ key: CGKeyCode, flags: CGEventFlags, app: NSRunningApplication) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { throw MacControlError.actionFailed }
        down.flags = flags; up.flags = flags
        try verifyFocus(app)
        down.postToPid(app.processIdentifier)
        // Always release a delivered key, even if cancellation arrives immediately after key-down.
        up.postToPid(app.processIdentifier)
    }

    private func insertLiteralText(_ text: String, app: NSRunningApplication, ax: AXUIElement) throws -> Bool {
        let field = try validateInputContext(app: app, ax: ax, requireEditable: true)
        if isSettable(field, kAXSelectedTextAttribute) {
            let expected: String?
            if let before = stringAttribute(field, kAXValueAttribute), before.utf16.count <= 100_000,
               let range = selectedRange(field) {
                expected = Self.replacingSelection(in: before, range: range, with: text)
            } else { expected = nil }
            try verifyFocusedElement(field, app: app, ax: ax)
            guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
                throw MacControlError.actionFailed
            }
            return expected.map { stringAttribute(field, kAXValueAttribute) == $0 } ?? false
        }
        // Preserve the rest of the document; never replace the whole field when
        // the app does not expose a reliable insertion/selection range.
        guard isSettable(field, kAXValueAttribute), let value = stringAttribute(field, kAXValueAttribute),
              value.utf16.count <= 100_000, let range = selectedRange(field),
              let replacement = Self.replacingSelection(in: value, range: range, with: text) else {
            throw MacControlError.noEditableField
        }
        try verifyFocusedElement(field, app: app, ax: ax)
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, replacement as CFString) == .success else {
            throw MacControlError.actionFailed
        }
        if isSettable(field, kAXSelectedTextRangeAttribute), (try? verifyFocusedElement(field, app: app, ax: ax)) != nil {
            var caret = CFRange(location: range.location + text.utf16.count, length: 0)
            if let value = AXValueCreate(.cfRange, &caret) {
                _ = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value)
            }
        }
        return stringAttribute(field, kAXValueAttribute) == replacement
    }

    private func verifyFocusedElement(_ field: AXUIElement, app: NSRunningApplication, ax: AXUIElement) throws {
        guard let current = elementAttribute(ax, kAXFocusedUIElementAttribute), CFEqual(current, field) else {
            throw MacControlError.focusChanged
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid == app.processIdentifier else { throw MacControlError.focusChanged }
        try verifyFocus(app)
    }

    nonisolated static func replacingSelection(in value: String, range: CFRange, with text: String) -> String? {
        let utf16 = Array(value.utf16)
        guard range.location >= 0, range.length >= 0, range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location else { return nil }
        func scalarBoundary(_ offset: Int) -> Bool {
            offset == 0 || offset == utf16.count || !(0xDC00...0xDFFF).contains(utf16[offset]) || !(0xD800...0xDBFF).contains(utf16[offset - 1])
        }
        guard scalarBoundary(range.location), scalarBoundary(range.location + range.length) else { return nil }
        return (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }

    nonisolated static func isTerminalApplication(_ id: String) -> Bool {
        let id = id.lowercased()
        return ["terminal", "iterm", "ghostty", "warp", "cmux", "wezterm", "alacritty", "kitty"].contains { id.contains($0) }
    }

    private func validateInputContext(app: NSRunningApplication, ax: AXUIElement, requireEditable: Bool) throws -> AXUIElement {
        if Self.isTerminalApplication(app.bundleIdentifier ?? "") { throw MacControlError.terminalInput }
        guard let field = elementAttribute(ax, kAXFocusedUIElementAttribute) else { throw MacControlError.noEditableField }
        try rejectProtectedField(field)
        var element: AXUIElement? = field
        for _ in 0..<6 {
            guard let current = element else { break }
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXRoleDescriptionAttribute, kAXIdentifierAttribute]
                .compactMap { stringAttribute(current, $0) }.joined(separator: " ").lowercased()
            if labels.contains("terminal") || labels.contains("终端") { throw MacControlError.terminalInput }
            element = elementAttribute(current, kAXParentAttribute)
        }
        if requireEditable {
            guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(stringAttribute(field, kAXRoleAttribute) ?? ""),
                  isSettable(field, kAXSelectedTextAttribute) || isSettable(field, kAXValueAttribute) else {
                throw MacControlError.noEditableField
            }
        }
        return field
    }

    private func rejectProtectedField(_ field: AXUIElement?) throws {
        guard let field else { return }
        if stringAttribute(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            || stringAttribute(field, kAXRoleAttribute) == "AXSecureTextField"
            || boolAttribute(field, "AXProtectedContent") == true {
            throw MacControlError.protectedField
        }
    }

    private func closeWindows(app: NSRunningApplication, all: Bool) async throws -> String {
        let ax = applicationElement(app)
        guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
        let windows: [AXUIElement]
        var limited = false
        if all {
            let snapshot = try windowSnapshot(ax)
            limited = snapshot.count > 24
            windows = Array(snapshot.prefix(24))
        }
        else if let window = elementAttribute(ax, kAXFocusedWindowAttribute) { windows = [window] }
        else { windows = [] }
        guard !windows.isEmpty else { throw MacControlError.noWindow }
        var observedClosed = 0
        for window in windows {
            guard let close = elementAttribute(window, kAXCloseButtonAttribute), boolAttribute(close, kAXEnabledAttribute) != false else {
                return "已观察到 \(observedClosed) 个窗口关闭；遇到无法关闭的窗口，已停止。"
            }
            try verifyFocus(app)
            guard AXUIElementPerformAction(close, kAXPressAction as CFString) == .success else {
                if observedClosed == 0 { throw MacControlError.actionFailed }
                return "已观察到 \(observedClosed) 个窗口关闭；后续关闭请求未被接受，已停止。"
            }
            try await Task.sleep(nanoseconds: 180_000_000)
            guard let remaining = try? windowSnapshot(ax) else {
                return "已观察到 \(observedClosed) 个窗口关闭；最新窗口状态无法读取，已停止。"
            }
            let disappeared = !remaining.contains { CFEqual($0, window) }
            if disappeared { observedClosed += 1 }
            if !disappeared || hasBlockingDialog(ax) {
                return "已观察到 \(observedClosed) 个窗口关闭；其余关闭结果未确认，可能正在等待保存对话框，已停止。"
            }
        }
        return "已观察到 \(observedClosed) 个窗口关闭。" + (limited ? "本次最多关闭 24 个，仍有其他窗口未处理。" : "")
    }

    private func windowSnapshot(_ app: AXUIElement) throws -> [AXUIElement] {
        guard let raw = attribute(app, kAXWindowsAttribute), let values = raw as? [CFTypeRef] else {
            throw MacControlError.actionFailed
        }
        return values.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { unsafeBitCast($0, to: AXUIElement.self) }
    }

    private struct ObservedControl {
        let element: AXUIElement
        let label: String
    }

    private func click(goal: String, app: NSRunningApplication, jev: JevClient) async throws -> String {
        let ax = applicationElement(app)
        guard let window = elementAttribute(ax, kAXFocusedWindowAttribute) else { throw MacControlError.noWindow }
        var controls: [String: ObservedControl] = [:]
        let deadline = Date().addingTimeInterval(4)
        for element in boundedDescendants(window) {
            guard Date() < deadline, !Task.isCancelled else { break }
            guard boolAttribute(element, kAXEnabledAttribute) != false,
                  boolAttribute(element, "AXHidden") != true,
                  actions(element).contains(kAXPressAction),
                  stringAttribute(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { continue }
            let label = controlLabel(element)
            guard !label.isEmpty else { continue }
            controls["e\(controls.count + 1)"] = ObservedControl(element: element, label: label)
            if controls.count == 60 { break }
        }
        guard !controls.isEmpty else { throw MacControlError.noControls }
        let selected = try await jev.chooseElement(goal: goal, elements: controls.mapValues(\.label))
        try Task.checkCancellation()
        guard let control = controls[selected] else { throw MacControlError.staleElement }
        try verifyFocus(app)
        guard let current = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(current, window),
              boundedDescendants(current).contains(where: { CFEqual($0, control.element) }),
              controlLabel(control.element) == control.label,
              boolAttribute(control.element, kAXEnabledAttribute) != false,
              actions(control.element).contains(kAXPressAction) else { throw MacControlError.staleElement }
        var pid: pid_t = 0
        guard AXUIElementGetPid(control.element, &pid) == .success, pid == app.processIdentifier else { throw MacControlError.staleElement }
        try verifyFocus(app)
        guard AXUIElementPerformAction(control.element, kAXPressAction as CFString) == .success else { throw MacControlError.actionFailed }
        return "已向 \(app.localizedName ?? "目标 App") 的控件发送点击；点击后的任务结果尚未验证。"
    }

    private func boundedDescendants(_ root: AXUIElement) -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(2)
        var queue = [root], result: [AXUIElement] = [], index = 0
        while index < queue.count, result.count < 180, Date() < deadline, !Task.isCancelled {
            let current = queue[index]; index += 1
            AXUIElementSetMessagingTimeout(current, axTimeout)
            result.append(current)
            let children = elementsAttribute(current, kAXChildrenAttribute)
            queue.append(contentsOf: children.prefix(max(0, 200 - queue.count)))
        }
        return result
    }

    private func controlLabel(_ element: AXUIElement) -> String {
        let role = stringAttribute(element, kAXRoleAttribute) ?? "control"
        let title = stringAttribute(element, kAXTitleAttribute) ?? ""
        let description = stringAttribute(element, kAXDescriptionAttribute) ?? ""
        return [role, String(title.prefix(100)), String(description.prefix(100))].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func hasBlockingDialog(_ app: AXUIElement) -> Bool {
        guard let focused = elementAttribute(app, kAXFocusedWindowAttribute) else {
            // A windowless app may safely create its first window. An unreadable
            // focused window is uncertain, not proof that no dialog exists.
            return (try? windowSnapshot(app).isEmpty) != true
        }
        if boolAttribute(focused, kAXModalAttribute) == true || stringAttribute(focused, kAXRoleAttribute) == kAXSheetRole { return true }
        let deadline = Date().addingTimeInterval(1)
        for child in elementsAttribute(focused, kAXChildrenAttribute).prefix(30) {
            // If the app cannot answer within the bound, stop instead of closing
            // additional windows under uncertain dialog state.
            if Date() >= deadline { return true }
            if stringAttribute(child, kAXRoleAttribute) == kAXSheetRole || boolAttribute(child, kAXModalAttribute) == true { return true }
        }
        return false
    }

    private func applicationElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, axTimeout)
        return element
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func stringAttribute(_ element: AXUIElement, _ key: String) -> String? { attribute(element, key) as? String }
    private func boolAttribute(_ element: AXUIElement, _ key: String) -> Bool? { attribute(element, key) as? Bool }
    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func elementsAttribute(_ element: AXUIElement, _ key: String) -> [AXUIElement] {
        guard let values = attribute(element, key) as? [CFTypeRef] else { return [] }
        return values.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { unsafeBitCast($0, to: AXUIElement.self) }
    }
    private func isSettable(_ element: AXUIElement, _ key: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, key as CFString, &settable) == .success && settable.boolValue
    }
    private func actions(_ element: AXUIElement) -> [String] {
        var values: CFArray?
        guard AXUIElementCopyActionNames(element, &values) == .success else { return [] }
        return values as? [String] ?? []
    }
    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var result = CFRange()
        return AXValueGetValue(value, .cfRange, &result) ? result : nil
    }
    private func center(of window: AXUIElement) -> CGPoint? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGPoint(x: point.x + dimensions.width / 2, y: point.y + dimensions.height / 2)
    }

    private static let tabApplicationIDs: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"]
}
