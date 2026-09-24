import AppKit
import ApplicationServices
import VoiceCodexCore

enum MacControlError: LocalizedError {
    case noTarget, unavailableApplication, applicationNotRunning, accessibilityRequired, focusChanged
    case unsupported, noEditableField, protectedField, terminalInput, staleElement
    case noControls, noWindow, blockedByDialog, actionFailed
    case incomplete(String), visualTargetChanged(String)
    case windowStateUnreadable(Int32)

    var errorDescription: String? {
        switch self {
        case .incomplete(let receipt): return receipt
        case .visualTargetChanged(let reason): return "点击前重新检查未通过（\(reason)），这次操作已停止。"
        case .windowStateUnreadable(let code): return "无法读取目标 App 的窗口状态（AXWindows 错误 \(code)）。"
        case .noTarget: return "请先切换到要控制的 App，再按住语音快捷键。"
        case .unavailableApplication: return "找不到这次指令指定的 App。"
        case .applicationNotRunning: return "目标 App 尚未运行，请先打开它再执行这个操作。"
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
        // macOS can hide Safari's application symlink, and Finder lives outside
        // the scanned application folders. Resolve their installed bundles via
        // Launch Services rather than depending on OS-version-specific paths.
        for id in ["com.apple.Safari", "com.apple.finder"] where urls[id] == nil {
            if let url = workspace.urlForApplication(withBundleIdentifier: id), Bundle(url: url)?.bundleIdentifier == id {
                urls[id] = url
            }
        }
        // Includes other running apps that live outside those roots.
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

    /// App launch may finish before its first window is exposed to Accessibility.
    /// Retry only observation, never the action itself.
    func waitForInterface(command: MacCommand) async throws {
        guard let id = command.applicationID ?? foregroundApplicationID else { throw MacControlError.noTarget }
        let deadline = Date().addingTimeInterval(3)
        var sawWindow = false
        repeat {
            try Task.checkCancellation()
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) else {
                throw MacControlError.applicationNotRunning
            }
            let ax = applicationElement(app)
            if elementAttribute(ax, kAXFocusedWindowAttribute) != nil {
                sawWindow = true
                // A click will select and revalidate one concrete control in
                // this window. Its own overlay checks use positive evidence;
                // slow AX children alone must not be called a dialog.
                if command.intent == .clickElement { return }
                // During launch, AX may expose a window before its child
                // attributes respond. Give the dialog check time to settle;
                // a transient timeout must not immediately look like a modal.
                if !hasBlockingDialog(ax) { return }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        if sawWindow { throw MacControlError.blockedByDialog }
        throw MacControlError.noWindow
    }

    func execute(command: MacCommand, goal: String = "", jev: JevClient,
                 onProgress: (String) -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()
        guard command.intent != .unsupported else { throw MacControlError.unsupported }
        guard let id = command.applicationID ?? foregroundApplicationID else { throw MacControlError.noTarget }
        if applicationURLs.isEmpty { _ = applications() }
        guard let url = applicationURLs[id] else { throw MacControlError.unavailableApplication }
        if [.newTab, .closeTab].contains(command.intent), !Self.tabApplicationIDs.contains(id) {
            throw MacControlError.unsupported
        }
        if needsAccessibility(for: command.intent), !accessibilityGranted { throw MacControlError.accessibilityRequired }

        if command.intent == .openApp {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try Task.checkCancellation()
            let app = try await workspace.openApplication(at: url, configuration: configuration)
            return "已打开 \(app.localizedName ?? id)；已观察到应用进程。"
        }
        var application = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated })
        let launchedForCreation = application == nil && [.newTab, .newWindow].contains(command.intent)
        if launchedForCreation {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try Task.checkCancellation()
            application = try await workspace.openApplication(at: url, configuration: configuration)
        }
        guard let app = application else { throw MacControlError.applicationNotRunning }
        try await focus(app)
        if [.clickElement, .paste, .pressReturn, .closeAllWindows].contains(command.intent) {
            try await waitForInterface(command: command)
            try verifyFocus(app)
        }
        let ax = applicationElement(app)
        let name = app.localizedName ?? id
        switch command.intent {
        case .newTab:
            guard Self.tabApplicationIDs.contains(id) else { throw MacControlError.unsupported }
            guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
            try await shortcut(17, flags: .maskCommand, app: app) { [self] in
                guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
            }
            return "已向 \(name) 发送新标签页快捷键（⌘T）；页面是否加载完成尚未验证。"
        case .closeTab:
            guard Self.tabApplicationIDs.contains(id) else { throw MacControlError.unsupported }
            guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
            guard let window = elementAttribute(ax, kAXFocusedWindowAttribute) else { throw MacControlError.noWindow }
            try await shortcut(13, flags: .maskCommand, app: app) { [self] in
                guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
                guard let current = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(current, window) else {
                    throw MacControlError.focusChanged
                }
            }
            return "已向 \(name) 发送关闭当前标签页快捷键（⌘W）；关闭结果尚未验证。"
        case .newWindow:
            let initial = try await Self.observeWindowTransition(read: { try readUnblockedWindowSnapshot(ax) }, until: { _ in true })
            let before = initial.windows
            if launchedForCreation, let before, !before.isEmpty {
                return "已启动 \(name)，并观察到它打开了窗口。"
            }
            try await shortcut(45, flags: .maskCommand, app: app) { [self] in
                guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
            }
            var readError = initial.readError
            if let before {
                let observation = try await Self.observeWindowTransition(read: { try readUnblockedWindowSnapshot(ax) }) { after in
                    after.contains { candidate in !before.contains { CFEqual(candidate, $0) } }
                }
                if observation.completed {
                    return "已观察到 \(name) 新建了窗口。"
                }
                readError = observation.readError
            }
            let detail = readError.map { " \($0.localizedDescription)" } ?? ""
            return "已向 \(name) 发送新建快捷键（⌘N）；由该 App 决定新建窗口、文稿或便笺。\(detail)"
        case .closeWindow: return try await closeWindows(app: app, all: false)
        case .closeAllWindows: return try await closeWindows(app: app, all: true)
        case .typeText:
            guard let text = command.text, !text.isEmpty else { throw MacControlError.noEditableField }
            let observed = try await insertLiteralText(text, app: app, ax: ax)
            return observed ? "已读取并确认 \(name) 编辑框中的文字更新；未发送回车。"
                : "\(name) 已接受文字写入；无法读取确认最终内容，未发送回车。"
        case .pressReturn:
            let field = try await validateInputContext(app: app, ax: ax, requireEditable: false)
            try await shortcut(36, flags: [], app: app) { [self] in
                try verifyFocusedElement(field, app: app, ax: ax)
                try rejectProtectedField(field)
            }
            return "已向 \(name) 发送回车；提交结果尚未验证。"
        case .copy:
            try await shortcut(8, flags: .maskCommand, app: app) { [self] in
                try rejectProtectedField(elementAttribute(ax, kAXFocusedUIElementAttribute))
            }
            return "已向 \(name) 发送复制快捷键；未读取剪贴板。"
        case .paste:
            let field = try await validateInputContext(app: app, ax: ax, requireEditable: true)
            try await shortcut(9, flags: .maskCommand, app: app) { [self] in
                try verifyFocusedElement(field, app: app, ax: ax)
                try rejectProtectedField(field)
            }
            return "已向 \(name) 发送粘贴快捷键；粘贴结果尚未验证。"
        case .undo:
            try await shortcut(6, flags: .maskCommand, app: app)
            return "已向 \(name) 发送撤销快捷键；撤销结果尚未验证。"
        case .scrollDown, .scrollUp:
            guard let window = elementAttribute(ax, kAXFocusedWindowAttribute) else { throw MacControlError.noWindow }
            guard let point = scrollPoint(app: ax, window: window, processID: app.processIdentifier),
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: command.intent == .scrollDown ? -500 : 500, wheel2: 0, wheel3: 0) else {
                throw MacControlError.actionFailed
            }
            event.location = point
            try await Self.withNativeActionCheckpoint {
                guard let current = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(current, window) else {
                    throw MacControlError.focusChanged
                }
                try verifyFocus(app)
                event.postToPid(app.processIdentifier)
            }
            return "已向 \(name) 当前窗口发送滚动；滚动位置尚未验证。"
        case .clickElement:
            return try await click(goal: goal.isEmpty ? (command.text ?? "") : goal, app: app, jev: jev, onProgress: onProgress)
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

    /// AX reads are synchronous. Let the main actor process queued Stop/Escape
    /// callbacks before revalidating the target and performing a native action.
    static func withNativeActionCheckpoint<Result>(_ action: () throws -> Result) async throws -> Result {
        try await Task.sleep(nanoseconds: 1_000_000)
        try Task.checkCancellation()
        return try action()
    }

    private func shortcut(_ key: CGKeyCode, flags: CGEventFlags, app: NSRunningApplication,
                          revalidate: (() throws -> Void)? = nil) async throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { throw MacControlError.actionFailed }
        down.flags = flags; up.flags = flags
        try await Self.withNativeActionCheckpoint {
            try revalidate?()
            try verifyFocus(app)
            down.postToPid(app.processIdentifier)
            // Always release a delivered key; never suspend between key-down and key-up.
            up.postToPid(app.processIdentifier)
        }
    }

    private func insertLiteralText(_ text: String, app: NSRunningApplication, ax: AXUIElement) async throws -> Bool {
        let field = try await validateInputContext(app: app, ax: ax, requireEditable: true)
        if isSettable(field, kAXSelectedTextAttribute) {
            let before = stringAttribute(field, kAXValueAttribute)
            let range = selectedRange(field)
            let expected: String?
            if let before, before.utf16.count <= 100_000, let range {
                expected = Self.replacingSelection(in: before, range: range, with: text)
            } else { expected = nil }
            try await Self.withNativeActionCheckpoint {
                try verifyFocusedElement(field, app: app, ax: ax)
                try verifyTextSelection(field, value: before, range: range)
                guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
                    throw MacControlError.actionFailed
                }
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
        try await Self.withNativeActionCheckpoint {
            try verifyFocusedElement(field, app: app, ax: ax)
            try verifyTextSelection(field, value: value, range: range)
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, replacement as CFString) == .success else {
                throw MacControlError.actionFailed
            }
        }
        if isSettable(field, kAXSelectedTextRangeAttribute), (try? verifyFocusedElement(field, app: app, ax: ax)) != nil {
            var caret = CFRange(location: range.location + text.utf16.count, length: 0)
            if let value = AXValueCreate(.cfRange, &caret) {
                _ = AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value)
            }
        }
        return stringAttribute(field, kAXValueAttribute) == replacement
    }

    private func verifyTextSelection(_ field: AXUIElement, value: String?, range: CFRange?) throws {
        try rejectProtectedField(field)
        if let value, stringAttribute(field, kAXValueAttribute) != value { throw MacControlError.focusChanged }
        if let range {
            guard let current = selectedRange(field), current.location == range.location, current.length == range.length else {
                throw MacControlError.focusChanged
            }
        }
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

    nonisolated static func isTerminalElement(role: String?, identifier: String?, roleDescription: String?) -> Bool {
        // Window/app labels can be arbitrary document titles, not widget types.
        guard role != kAXWindowRole, role != kAXApplicationRole else { return false }
        let metadata = [role, identifier, roleDescription].compactMap { $0 }.joined(separator: " ").lowercased()
        return metadata.contains("terminal") || metadata.contains("xterm") || metadata.contains("终端")
    }

    private func validateInputContext(app: NSRunningApplication, ax: AXUIElement, requireEditable: Bool) async throws -> AXUIElement {
        if Self.isTerminalApplication(app.bundleIdentifier ?? "") { throw MacControlError.terminalInput }
        guard let field = elementAttribute(ax, kAXFocusedUIElementAttribute) else { throw MacControlError.noEditableField }
        try rejectProtectedField(field)
        var element: AXUIElement? = field
        for _ in 0..<6 {
            try await Self.withNativeActionCheckpoint {}
            guard let current = element else { break }
            if Self.isTerminalElement(role: stringAttribute(current, kAXRoleAttribute),
                                      identifier: stringAttribute(current, kAXIdentifierAttribute),
                                      roleDescription: stringAttribute(current, kAXRoleDescriptionAttribute)) {
                throw MacControlError.terminalInput
            }
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
        let initial = try await Self.observeWindowTransition(read: { () throws -> [AXUIElement]? in
            if all { return try readUnblockedWindowSnapshot(ax) }
            // Closing one focused window does not require the app to expose an
            // AXWindows array. Keep that action available, with an honest
            // unverified receipt if the post-action list remains unreadable.
            if let focused = elementAttribute(ax, kAXFocusedWindowAttribute) {
                guard !hasBlockingDialog(in: focused) else { throw MacControlError.blockedByDialog }
                return [focused]
            }
            return try windowSnapshot(ax).isEmpty ? [] : nil
        }, until: { _ in true })
        guard let snapshot = initial.windows else { throw initial.readError ?? MacControlError.actionFailed }
        let windows: [AXUIElement]
        var limited = false
        if all {
            limited = snapshot.count > 24
            windows = Array(snapshot.prefix(24))
        }
        else { windows = snapshot }
        guard !windows.isEmpty else { throw MacControlError.noWindow }
        var observedClosed = 0
        for window in windows {
            // Closing a window can briefly hide the next window's AX close
            // button. Refresh its handle by identity and retry reads only;
            // never substitute another window or repeat an accepted press.
            let readiness = try await Self.observeWindowTransition(read: { () throws -> [ObservedWindowClose]? in
                let current: AXUIElement
                if all {
                    guard let remaining = try readUnblockedWindowSnapshot(ax) else { return nil }
                    guard let matching = remaining.first(where: { CFEqual($0, window) }) else {
                        throw MacControlError.staleElement
                    }
                    current = matching
                } else {
                    guard let focused = elementAttribute(ax, kAXFocusedWindowAttribute) else { return nil }
                    guard CFEqual(focused, window) else { throw MacControlError.focusChanged }
                    guard !hasBlockingDialog(in: focused) else { throw MacControlError.blockedByDialog }
                    current = focused
                }
                guard let close = elementAttribute(current, kAXCloseButtonAttribute),
                      boolAttribute(close, kAXEnabledAttribute) != false else { return nil }
                return [ObservedWindowClose(window: current, button: close)]
            }, until: { !$0.isEmpty })
            guard let target = readiness.windows?.first else {
                if let error = readiness.readError {
                    throw MacControlError.incomplete("已观察到 \(observedClosed) 个窗口关闭；\(error.localizedDescription)已停止。")
                }
                throw MacControlError.incomplete("已观察到 \(observedClosed) 个窗口关闭；遇到无法关闭的窗口，已停止。")
            }
            let delivered = try await Self.withNativeActionCheckpoint {
                guard !hasBlockingDialog(ax) else { throw MacControlError.blockedByDialog }
                if all {
                    guard try windowSnapshot(ax).contains(where: { CFEqual($0, target.window) }) else { throw MacControlError.staleElement }
                } else {
                    guard let focused = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(focused, target.window) else {
                        throw MacControlError.focusChanged
                    }
                }
                guard let currentClose = elementAttribute(target.window, kAXCloseButtonAttribute), CFEqual(currentClose, target.button),
                      boolAttribute(target.button, kAXEnabledAttribute) != false else { throw MacControlError.staleElement }
                try verifyFocus(app)
                return AXUIElementPerformAction(target.button, kAXPressAction as CFString)
            }
            guard delivered == .success else {
                if observedClosed == 0 { throw MacControlError.actionFailed }
                throw MacControlError.incomplete("已观察到 \(observedClosed) 个窗口关闭；后续关闭请求未被接受，已停止。")
            }
            let observation: WindowObservation<AXUIElement>
            do {
                observation = try await Self.observeWindowTransition(read: { try readUnblockedWindowSnapshot(ax) }) { remaining in
                    !remaining.contains { CFEqual($0, window) }
                }
            } catch MacControlError.blockedByDialog {
                throw MacControlError.incomplete("已观察到 \(observedClosed) 个窗口关闭；目标 App 出现待处理的对话框，已停止。")
            }
            guard observation.windows != nil else {
                let detail = observation.readError?.localizedDescription ?? "最新窗口状态无法读取。"
                throw MacControlError.incomplete("已观察到 \(observedClosed) 个窗口关闭；\(detail)已停止。")
            }
            if !observation.completed {
                throw MacControlError.incomplete("已观察到 \(observedClosed) 个窗口关闭；其余关闭结果未确认，可能正在等待保存对话框，已停止。")
            }
            observedClosed += 1
        }
        if limited { throw MacControlError.incomplete("已观察到 \(observedClosed) 个窗口关闭。本次最多关闭 24 个，仍有其他窗口未处理，后续步骤已停止。") }
        return "已观察到 \(observedClosed) 个窗口关闭。"
    }

    private struct ObservedWindowClose {
        let window: AXUIElement
        let button: AXUIElement
    }

    struct WindowObservation<Window> {
        let windows: [Window]?
        let completed: Bool
        let readError: MacControlError?
    }

    /// Accessibility can lag after a delivered key or AXPress. Retry only
    /// observations, with a fixed attempt budget; this helper cannot send input.
    /// An unchanged readable list is not success, and a failed read is not an
    /// empty list. Keep the last read so timeouts report the current uncertainty.
    static func observeWindowTransition<Window>(
        attempts: Int = 16,
        read: () throws -> [Window]?,
        until isComplete: ([Window]) -> Bool,
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 150_000_000) }
    ) async throws -> WindowObservation<Window> {
        try Task.checkCancellation()
        var latest: [Window]?
        var readError: MacControlError?
        for attempt in 0..<max(0, attempts) {
            try Task.checkCancellation()
            if attempt > 0 { try await wait() }
            try Task.checkCancellation()
            do {
                latest = try read()
                readError = nil
            } catch MacControlError.windowStateUnreadable(let code) {
                latest = nil
                readError = .windowStateUnreadable(code)
            }
            try Task.checkCancellation()
            if let latest, isComplete(latest) {
                return WindowObservation(windows: latest, completed: true, readError: nil)
            }
        }
        return WindowObservation(windows: latest, completed: false, readError: readError)
    }

    /// A temporarily missing focused window during an animation is unreadable,
    /// not a dialog. Actual modal windows still stop observation immediately.
    private func readUnblockedWindowSnapshot(_ app: AXUIElement) throws -> [AXUIElement]? {
        let windows = try windowSnapshot(app)
        if let focused = elementAttribute(app, kAXFocusedWindowAttribute) {
            guard !hasBlockingDialog(in: focused) else { throw MacControlError.blockedByDialog }
        } else if !windows.isEmpty {
            return nil
        }
        return windows
    }

    private func windowSnapshot(_ app: AXUIElement) throws -> [AXUIElement] {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard result == .success else { throw MacControlError.windowStateUnreadable(result.rawValue) }
        guard let raw, let values = raw as? [CFTypeRef] else {
            throw MacControlError.actionFailed
        }
        return values.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { unsafeBitCast($0, to: AXUIElement.self) }
    }

    private struct ObservedControl {
        let element: AXUIElement
        let label: String
    }

    /// Only describes the current external target. A typed command may have
    /// brought VoiceCodex forward; inspecting its remembered target is read-only.
    /// Never activate another app or read text-field contents to help planning.
    func planningContext(applicationID: String?) async -> [String: String] {
        guard accessibilityGranted, let id = applicationID ?? foregroundApplicationID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) else { return [:] }
        let callerPID = workspace.frontmostApplication?.processIdentifier
        func validTarget() -> Bool {
            guard !Task.isCancelled, !app.isTerminated,
                  workspace.frontmostApplication?.processIdentifier == callerPID else { return false }
            return callerPID == app.processIdentifier ||
                (callerPID == ProcessInfo.processInfo.processIdentifier && foregroundApplicationID == id)
        }
        guard validTarget() else { return [:] }
        let ax = applicationElement(app)
        let window = await Self.waitForPlanningWindow(validTarget: validTarget, read: {
            self.elementAttribute(ax, kAXFocusedWindowAttribute) ?? self.elementAttribute(ax, kAXMainWindowAttribute)
                ?? (try? self.windowSnapshot(ax)).flatMap { $0.count == 1 ? $0.first : nil }
        })
        guard let window else { return [:] }
        var labels: [String: String] = [:]
        let deadline = Date().addingTimeInterval(3)
        for element in boundedDescendants(window) {
            guard validTarget() else { return [:] }
            guard Date() < deadline else { break }
            guard (try? rejectProtectedField(element)) != nil,
                  boolAttribute(element, "AXHidden") != true,
                  boolAttribute(element, kAXEnabledAttribute) != false,
                  actions(element).contains(kAXPressAction),
                  !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
                    .contains(stringAttribute(element, kAXSubroleAttribute) ?? "") else { continue }
            let label = controlLabel(element)
            if !label.isEmpty { labels["ctx_ax_\(labels.count + 1)"] = label }
            if labels.count == 40 { break }
        }
        if labels.count < 3, CGPreflightScreenCaptureAccess(), let bounds = frame(of: window),
           (try? rejectProtectedField(elementAttribute(ax, kAXFocusedUIElementAttribute))) != nil,
           let snapshot = try? await VisualControlObserver().observe(processID: app.processIdentifier, expectedWindowFrame: bounds) {
            guard validTarget() else { return [:] }
            // AX and OCR can describe the same button. Keep a single source,
            // rather than invent two ambiguous controls with identical labels.
            // No within-source duplicates are collapsed by this handoff.
            let visualLabels = Dictionary(uniqueKeysWithValues: snapshot.candidates.prefix(40).map {
                ("ctx_\($0.id)", "屏幕文字 · " + $0.text)
            })
            if !visualLabels.isEmpty {
                labels = visualLabels
            }
        }
        return validTarget() ? labels : [:]
    }

    /// Process launch can precede its first readable window. Poll only reads,
    /// without activating anything; cancellation or any target change ends it.
    static func waitForPlanningWindow<Window>(
        validTarget: () -> Bool, read: () -> Window?,
        now: () -> Date = Date.init,
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 150_000_000) }
    ) async -> Window? {
        let deadline = now().addingTimeInterval(3)
        // Reserve 450 ms for the three bounded AX reads in the final attempt.
        for _ in 0..<20 {
            guard !Task.isCancelled, validTarget(), now().addingTimeInterval(0.45) <= deadline else { return nil }
            let window = read()
            guard !Task.isCancelled, validTarget() else { return nil }
            if let window { return window }
            guard now().addingTimeInterval(0.6) <= deadline else { return nil }
            do { try await wait() } catch { return nil }
        }
        return nil
    }

    struct ClickState {
        let windows: [AXUIElement]?
        /// Local, bounded widget labels/status values; never uploaded to Jev.
        let semantics: [String]?
        let visualLabels: Set<String>?
        let contentWindow: AXUIElement?

        init(windows: [AXUIElement]? = nil, semantics: [String]? = nil,
             visualLabels: Set<String>? = nil, contentWindow: AXUIElement? = nil) {
            self.windows = windows
            self.semantics = semantics
            self.visualLabels = visualLabels
            self.contentWindow = contentWindow
        }
    }

    /// This helper owns exactly one dispatch. Subsequent attempts only read;
    /// unreadable/no-op results cannot advance the command sequence.
    static func performVerifiedClick<State, Evidence: Equatable>(
        baseline: State?, attempts: Int = 8,
        action: () async throws -> Void,
        observe: () async throws -> State?,
        evidence: (State, State) -> Evidence?,
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }
    ) async throws {
        try Task.checkCancellation()
        guard let baseline else {
            throw MacControlError.incomplete("无法读取点击前的界面，未执行点击；后续步骤已停止。")
        }
        try await action()
        var previousEvidence: Evidence?
        var lastWasReadable = false
        for _ in 0..<max(0, attempts) {
            try Task.checkCancellation()
            try await wait()
            try Task.checkCancellation()
            let current = try await observe()
            try Task.checkCancellation()
            lastWasReadable = current != nil
            guard let current, let changed = evidence(baseline, current) else {
                previousEvidence = nil
                continue
            }
            // A single transient frame, hover hint, or partially loaded tree
            // is not enough to claim that the click produced a UI transition.
            if previousEvidence == changed { return }
            previousEvidence = changed
        }
        let reason = lastWasReadable ? "没有观察到界面内容变化，可能没有点中" : "点击后的界面无法可靠读取，结果未知"
        throw MacControlError.incomplete("已发送一次点击，但\(reason)；未重复点击，后续步骤已停止。")
    }

    static func clickChange(_ before: ClickState, _ after: ClickState) -> String? {
        if let previous = before.windows, let current = after.windows,
           current.count != previous.count || current.contains(where: { candidate in !previous.contains { CFEqual(candidate, $0) } }) {
            return "windows:" + current.map { String(CFHash($0)) }.sorted().joined(separator: ",")
        }
        // A switch between two existing windows does not prove a click worked.
        switch (before.contentWindow, after.contentWindow) {
        case let (.some(a), .some(b)): guard CFEqual(a, b) else { return nil }
        case (.none, .none): break
        default: return nil
        }
        if let previous = before.semantics, let current = after.semantics,
           !previous.isEmpty, !current.isEmpty, current != previous {
            let added = Set(current).subtracting(previous), removed = Set(previous).subtracting(current)
            if (!added.isEmpty && !removed.isEmpty) || added.count >= 2 {
                return "ax:" + current.joined(separator: "\n")
            }
        }
        if let previous = before.visualLabels, let current = after.visualLabels {
            // Geometry, cursor movement, and one added tooltip do not count.
            // Require a persistent content replacement with multiple new labels.
            let added = current.subtracting(previous), removed = previous.subtracting(current)
            if added.count >= 2, !removed.isEmpty {
                return "ocr:" + current.sorted().joined(separator: "\n")
            }
        }
        return nil
    }

    private func clickState(app: NSRunningApplication, includeVisual: Bool,
                            visual: VisualControlObserver.Snapshot? = nil) async -> ClickState? {
        guard !Task.isCancelled, !app.isTerminated,
              workspace.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        let ax = applicationElement(app)
        let windows = try? windowSnapshot(ax).filter {
            try observationAttribute($0, kAXSubroleAttribute) as? String != "AXHelpTag"
        }
        let window = elementAttribute(ax, kAXFocusedWindowAttribute)
        let semantics = window.flatMap { try? semanticClickState(in: $0) }
        var labels = visual.map { Set($0.candidates.compactMap { Self.stableClickText(VisualControlObserver.labelIdentity($0.text)) }) }
        if includeVisual, labels == nil, let window, let bounds = frame(of: window),
           (try? rejectProtectedField(elementAttribute(ax, kAXFocusedUIElementAttribute))) != nil,
           let snapshot = try? await VisualControlObserver().observe(processID: app.processIdentifier, expectedWindowFrame: bounds) {
            labels = Set(snapshot.candidates.compactMap { Self.stableClickText(VisualControlObserver.labelIdentity($0.text)) })
        }
        guard !Task.isCancelled, workspace.frontmostApplication?.processIdentifier == app.processIdentifier,
              windows != nil || semantics != nil || labels != nil else { return nil }
        return ClickState(windows: windows, semantics: semantics, visualLabels: labels, contentWindow: window)
    }

    /// A strict observation reader: a timeout is unknown, not an empty tree.
    /// Excludes focus/geometry and editable or protected values. Only widget
    /// captions, static status text and numeric/bool toggle values are compared.
    private func semanticClickState(in window: AXUIElement) throws -> [String]? {
        let deadline = Date().addingTimeInterval(1.5)
        var queue = [window], index = 0, rows: [String] = []
        let roles = [kAXButtonRole, kAXStaticTextRole, kAXCheckBoxRole, kAXRadioButtonRole,
                     kAXPopUpButtonRole, kAXMenuItemRole, kAXDisclosureTriangleRole]
        while index < queue.count {
            guard index < 140, Date() < deadline, !Task.isCancelled else { return nil }
            let element = queue[index]; index += 1
            let role = try observationAttribute(element, kAXRoleAttribute) as? String
            let subrole = try observationAttribute(element, kAXSubroleAttribute) as? String
            guard role != "AXSecureTextField", subrole != kAXSecureTextFieldSubrole,
                  subrole != "AXHelpTag", role != "AXHelpTag",
                  try observationAttribute(element, "AXProtectedContent") as? Bool != true,
                  try observationAttribute(element, "AXHidden") as? Bool != true else { continue }
            if roles.contains(role ?? ""), !["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(subrole ?? "") {
                var parts = [role ?? ""]
                for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = try observationAttribute(element, key) as? String, let stable = Self.stableClickText(text) { parts.append(stable) }
                }
                if let value = try observationAttribute(element, kAXValueAttribute) {
                    if role == kAXStaticTextRole, let text = value as? String, let stable = Self.stableClickText(text) { parts.append(stable) }
                    else if [kAXCheckBoxRole, kAXRadioButtonRole, kAXDisclosureTriangleRole].contains(role ?? ""), let number = value as? NSNumber {
                        parts.append(number.stringValue)
                    }
                }
                if parts.count > 1 { rows.append(parts.joined(separator: " · ")) }
            }
            if let children = try observationAttribute(element, kAXChildrenAttribute) as? [CFTypeRef] {
                guard queue.count + children.count <= 180 else { return nil }
                queue.append(contentsOf: children.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { unsafeBitCast($0, to: AXUIElement.self) })
            }
        }
        return rows.sorted()
    }

    nonisolated static func stableClickText(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // A wall clock or meeting-duration ticker can advance during a missed
        // click. It is unrelated to the requested action, even if AX exposes it.
        let clock = #"^\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APap][Mm])?$"#
        guard value.range(of: clock, options: .regularExpression) == nil else { return nil }
        return String(value.prefix(160))
    }

    private func observationAttribute(_ element: AXUIElement, _ key: String) throws -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default: throw MacControlError.actionFailed
        }
    }

    private func click(goal: String, app: NSRunningApplication, jev: JevClient,
                       onProgress: (String) -> Void) async throws -> String {
        let ax = applicationElement(app)
        guard let window = elementAttribute(ax, kAXFocusedWindowAttribute) else { throw MacControlError.noWindow }
        guard !hasChildSheet(in: window) else { throw MacControlError.blockedByDialog }
        var controls: [String: ObservedControl] = [:]
        let deadline = Date().addingTimeInterval(4)
        for element in boundedDescendants(window) {
            guard Date() < deadline, !Task.isCancelled else { break }
            guard boolAttribute(element, kAXEnabledAttribute) != false,
                  boolAttribute(element, "AXHidden") != true,
                  actions(element).contains(kAXPressAction),
                  ![kAXSecureTextFieldSubrole, "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
                    .contains(stringAttribute(element, kAXSubroleAttribute) ?? "") else { continue }
            let label = controlLabel(element)
            guard !label.isEmpty else { continue }
            controls["e\(controls.count + 1)"] = ObservedControl(element: element, label: label)
            if controls.count == 60 { break }
        }
        guard !controls.isEmpty else {
            return try await clickVisual(goal: goal, app: app, window: window, jev: jev, onProgress: onProgress)
        }
        let selected: String
        do {
            selected = try await jev.chooseElement(goal: goal, elements: controls.mapValues(\.label))
        } catch JevClientError.unsupportedCommand {
            // Some windows expose only an unrelated toolbar through AX while
            // drawing the requested control themselves. An explicit no-match
            // may use a fresh visual observation; uncertain/failed choices may not.
            try Task.checkCancellation()
            return try await clickVisual(goal: goal, app: app, window: window, jev: jev, onProgress: onProgress)
        }
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
        let verifyVisual = CGPreflightScreenCaptureAccess()
        let before = await clickState(app: app, includeVisual: verifyVisual)
        try await Self.performVerifiedClick(baseline: before, action: {
            try await Self.withNativeActionCheckpoint {
                guard let current = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(current, window),
                      controlLabel(control.element) == control.label,
                      boolAttribute(control.element, "AXHidden") != true,
                      boolAttribute(control.element, kAXEnabledAttribute) != false,
                      actions(control.element).contains(kAXPressAction) else { throw MacControlError.staleElement }
                guard !hasChildSheet(in: current) else { throw MacControlError.blockedByDialog }
                try verifyFocus(app)
                guard AXUIElementPerformAction(control.element, kAXPressAction as CFString) == .success else { throw MacControlError.actionFailed }
            }
            onProgress("正在检查点击结果…")
        }, observe: {
            try self.verifyFocus(app)
            return await self.clickState(app: app, includeVisual: verifyVisual)
        }, evidence: Self.clickChange)
        return "已点击 \(app.localizedName ?? "目标 App") 的「\(control.label)」，并观察到界面内容变化；业务结果尚未确认。"
    }

    private func clickVisual(goal: String, app: NSRunningApplication, window: AXUIElement, jev: JevClient,
                             onProgress: (String) -> Void) async throws -> String {
        try verifyFocus(app)
        let ax = applicationElement(app)
        guard !hasChildSheet(in: window) else { throw MacControlError.blockedByDialog }
        guard let focusedWindow = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(focusedWindow, window) else {
            throw MacControlError.visualTargetChanged("目标窗口已切换")
        }
        guard let bounds = frame(of: window) else { throw MacControlError.noWindow }
        let observer = VisualControlObserver()
        let initial = try await observer.observe(processID: app.processIdentifier, expectedWindowFrame: bounds)
        let (snapshot, selected) = try await Self.chooseVisualTarget(from: initial,
            observe: { try await observer.observe(processID: app.processIdentifier, expectedWindowFrame: bounds) },
            validate: {
                try self.verifyFocus(app)
                guard !self.hasChildSheet(in: window) else { throw MacControlError.blockedByDialog }
                guard let current = self.elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(current, window),
                      self.frame(of: current) == bounds else { throw MacControlError.visualTargetChanged("窗口或位置已变化") }
            }, choose: { observation in
                let labels = Dictionary(uniqueKeysWithValues: observation.candidates.map { ($0.id, "屏幕文字 · " + $0.text) })
                guard !labels.isEmpty else { throw MacControlError.noControls }
                return try await jev.chooseElement(goal: goal, elements: labels)
            })
        guard let candidate = snapshot.candidates.first(where: { $0.id == selected }) else {
            throw MacControlError.visualTargetChanged("未找到所选文字")
        }
        try verifyFocus(app)
        guard let currentWindow = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(currentWindow, window),
              frame(of: currentWindow) == bounds else { throw MacControlError.visualTargetChanged("窗口或位置已变化") }
        let fresh = try await observer.observe(processID: app.processIdentifier, expectedWindowFrame: bounds)
        guard let current = VisualControlObserver.revalidatedCandidate(candidate, from: snapshot, in: fresh),
              let point = VisualControlObserver.screenPoint(for: current, in: fresh) else {
            throw MacControlError.visualTargetChanged("按钮文字或位置未能匹配")
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw MacControlError.actionFailed
        }
        let before = await clickState(app: app, includeVisual: true, visual: fresh)
        try await Self.performVerifiedClick(baseline: before, action: {
            try await Self.withNativeActionCheckpoint {
                try verifyFocus(app)
                guard !hasChildSheet(in: window) else { throw MacControlError.blockedByDialog }
                guard let finalWindow = elementAttribute(ax, kAXFocusedWindowAttribute), CFEqual(finalWindow, window),
                      frame(of: finalWindow) == bounds else { throw MacControlError.visualTargetChanged("点击前窗口已变化") }
                // Validate the point against its actual process and window.
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                      let hit else { throw MacControlError.visualTargetChanged("无法读取点击位置的控件") }
                var hitPID: pid_t = 0
                guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == app.processIdentifier else { throw MacControlError.focusChanged }
                // A sheet may resolve to its parent AXWindow while having a
                // separate WindowServer surface. Prove capture ownership even
                // when the AX hit supplies a seemingly matching parent window.
                guard Self.frontmostWindow(at: point, in: onScreenHitWindows()).map({
                    $0.processID == app.processIdentifier && $0.windowID == fresh.windowID
                }) == true else { throw MacControlError.visualTargetChanged("点击位置被其他窗口或面板遮挡") }
                if let hitWindow = containingWindow(of: hit) {
                    guard CFEqual(hitWindow, window) else { throw MacControlError.visualTargetChanged("点击位置属于另一个窗口") }
                }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            onProgress("正在检查点击结果…")
        }, observe: {
            try self.verifyFocus(app)
            return await self.clickState(app: app, includeVisual: true)
        }, evidence: Self.clickChange)
        return "已点击 \(app.localizedName ?? "目标 App") 的「\(candidate.text)」，并观察到界面内容变化；业务结果尚未确认。"
    }

    /// A just-opened app can replace its loading view while Jev is choosing.
    /// Replan once only after an explicit no-match and genuinely changed visual
    /// evidence in the identical window. No input is sent by this helper.
    static func chooseVisualTarget(
        from initial: VisualControlObserver.Snapshot,
        observe: () async throws -> VisualControlObserver.Snapshot,
        validate: () throws -> Void,
        choose: (VisualControlObserver.Snapshot) async throws -> String
    ) async throws -> (VisualControlObserver.Snapshot, String) {
        try Task.checkCancellation()
        try validate()
        let selected: String
        do {
            selected = try await choose(initial)
        } catch JevClientError.unsupportedCommand {
            try Task.checkCancellation()
            try validate()
            let refreshed = try await observe()
            try Task.checkCancellation()
            try validate()
            guard refreshed.processID == initial.processID, refreshed.windowID == initial.windowID,
                  refreshed.bounds == initial.bounds else { throw MacControlError.visualTargetChanged("目标窗口已切换") }
            let changed = refreshed.candidates.count != initial.candidates.count || initial.candidates.contains {
                VisualControlObserver.revalidatedCandidate($0, from: initial, in: refreshed) == nil
            }
            guard changed else { throw JevClientError.unsupportedCommand }
            let retry = try await choose(refreshed)
            try Task.checkCancellation()
            try validate()
            return (refreshed, retry)
        }
        try Task.checkCancellation()
        try validate()
        return (initial, selected)
    }

    private func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let item = current else { return nil }
            if stringAttribute(item, kAXRoleAttribute) == kAXWindowRole { return item }
            if let window = elementAttribute(item, kAXWindowAttribute) { return window }
            current = elementAttribute(item, kAXParentAttribute)
        }
        return nil
    }

    struct HitWindow {
        let processID: pid_t
        let windowID: CGWindowID
        let bounds: CGRect
        let alpha: Double
    }

    private func onScreenHitWindows() -> [HitWindow] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return windows.compactMap { info in
            guard let processID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowID = info[kCGWindowNumber as String] as? NSNumber,
                  let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds) else { return nil }
            return HitWindow(processID: processID.int32Value, windowID: windowID.uint32Value, bounds: bounds,
                             alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    /// CGWindowListCopyWindowInfo supplies front-to-back order. Never search
    /// past an opaque overlay for a preferred process or window.
    nonisolated static func frontmostWindow(at point: CGPoint, in windows: [HitWindow]) -> HitWindow? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return windows.first {
            $0.alpha.isFinite && $0.alpha > 0 && $0.bounds.contains(point)
        }
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
        Self.controlLabel(role: stringAttribute(element, kAXRoleAttribute), title: stringAttribute(element, kAXTitleAttribute),
                          description: stringAttribute(element, kAXDescriptionAttribute)) ?? ""
    }

    nonisolated static func controlLabel(role: String?, title: String?, description: String?) -> String? {
        let labels = [title, description].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(100))
        }
        // A role such as AXButton says nothing about a control's function and
        // must not prevent visual fallback for an otherwise unlabelled window.
        guard !labels.isEmpty else { return nil }
        let role = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ([role.isEmpty ? "control" : role] + labels).joined(separator: " · ")
    }

    private func hasBlockingDialog(_ app: AXUIElement) -> Bool {
        guard let focused = elementAttribute(app, kAXFocusedWindowAttribute) else {
            // A windowless app may safely create its first window. An unreadable
            // focused window is uncertain, not proof that no dialog exists.
            return (try? windowSnapshot(app).isEmpty) != true
        }
        return hasBlockingDialog(in: focused)
    }

    /// Clicking an explicitly observed modal window is valid. A sheet covering
    /// its parent is different: the captured parent does not include that sheet.
    /// Only positive metadata counts here; slow AX reads are not dialog proof.
    /// Native clicks additionally prove frontmost WindowServer point ownership.
    private func hasChildSheet(in window: AXUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        for child in elementsAttribute(window, kAXChildrenAttribute).prefix(30) {
            guard Date() < deadline, !Task.isCancelled else { return false }
            if boolAttribute(child, "AXHidden") == true { continue }
            if stringAttribute(child, kAXRoleAttribute) == kAXSheetRole || boolAttribute(child, kAXModalAttribute) == true {
                return true
            }
        }
        return false
    }

    private func hasBlockingDialog(in focused: AXUIElement) -> Bool {
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

    private func scrollPoint(app: AXUIElement, window: AXUIElement, processID: pid_t) -> CGPoint? {
        let deadline = Date().addingTimeInterval(1)
        var candidate = elementAttribute(app, kAXFocusedUIElementAttribute)
        for _ in 0..<8 {
            guard let element = candidate, Date() < deadline, !Task.isCancelled else { break }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == processID else { break }
            if stringAttribute(element, kAXRoleAttribute) == kAXScrollAreaRole, let point = center(of: element) { return point }
            if CFEqual(element, window) { break }
            candidate = elementAttribute(element, kAXParentAttribute)
        }
        return center(of: window)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func center(of window: AXUIElement) -> CGPoint? {
        guard let bounds = frame(of: window) else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private static let tabApplicationIDs: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"]
}
