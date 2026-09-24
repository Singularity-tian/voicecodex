import AppKit
import AVFoundation
import Darwin
import VoiceCodexCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var config = LocalConfig.load()
    private var window: NSWindow!
    private var view: MainView!
    private var statusItem: NSStatusItem!
    private let hotkey = GlobalHotkey()
    private let overlay = RecordingOverlay()
    private var speech: RealtimeSTT?
    private let macDriver = MacControlDriver()
    private var speechVocabulary: SpeechVocabulary?
    private var macTask: Task<Void, Never>?
    private let macSequence = MacSequenceExecutor()
    private var liveMacRecording = false
    private var macStatus = "等待语音指令"
    private var recordingTargetID: String?
    private var activationObserver: NSObjectProtocol?
    private var isMacMode: Bool { config.executionMode == "mac" }
    private var terminal: TerminalSession?
    private var terminalLaunch: TerminalLaunchFiles?
    private var monitorTask: Task<Void, Never>?
    private var submitting = false
    private var terminalActive = false
    private var waitingForApproval = false
    private var recordingState = RecordingState.idle
    private var recordingGeneration = UUID()
    private var releaseRequested = false
    private struct PendingPrompt {
        let id = UUID().uuidString
        let text: String
    }
    private var queue: [PendingPrompt] = []
    private var deliveryGeneration = 0
    private var deliveryPaused = false
    private var executing = false
    private var runTask: Task<Void, Never>?
    private var choosingProject = false
    private var terminating = false
    private var lastError = ""
    private var history = ""
    private var settingsWindow: NSWindow?
    private var apiKeyField: NSSecureTextField?
    private var executableField: NSTextField?
    private var overlayTimer: Timer?
    private enum RecordingState { case idle, starting, recording, finishing }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 VoiceCodex", action: #selector(showWindow), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 VoiceCodex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        view = MainView(frame: NSRect(x: 0, y: 0, width: 900, height: 850))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "VoiceCodex"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
        window.contentView = view
        window.minSize = NSSize(width: 840, height: 830)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        wireButtons()
        setupMenuBar()
        do { try hotkey.register() } catch { lastError = error.localizedDescription }
        view.shortcutLabel.stringValue = hotkey.label
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }
        hotkey.onEscape = { [weak self] in
            guard let self else { return }
            if self.isMacMode && self.executing { self.stopExecution() }
            else { self.cancelRecording() }
        }
        macDriver.captureForegroundApplication()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.macDriver.captureForegroundApplication()
                self?.updateMacTarget()
            }
        }
        view.configureMode(mac: isMacMode)
        _ = refreshSpeechVocabulary()
        updateProject()
        loadHistory()
        updateState()
        showWindow()
        if !lastError.isEmpty { appendHistory("系统", lastError) }
    }

    private func wireButtons() {
        view.recordButton.onPress = { [weak self] in self?.beginRecording() }
        view.recordButton.onRelease = { [weak self] in self?.endRecording() }
        for (button, action) in [(view.projectButton, #selector(chooseProject)),
                                 (view.newTaskButton, #selector(newTask)),
                                 (view.settingsButton, #selector(showSettings)),
                                 (view.stopButton, #selector(stopExecution)),
                                 (view.openWorktreeButton, #selector(openWorktree)),
                                 (view.openTerminalButton, #selector(openTerminal)),
                                 (view.permissionsButton, #selector(enableAccessibility)),
                                 (view.screenPermissionButton, #selector(enableScreenRecognition)),
                                 (view.environmentButton, #selector(openEnvironment)),
                                 (view.examplesButton, #selector(fillExample)),
                                 (view.sendButton, #selector(sendTypedCommand))] {
            button.target = self
            button.action = action
        }
        view.commandField.target = self
        view.commandField.action = #selector(sendTypedCommand)
        view.modeSelector.target = self
        view.modeSelector.action = #selector(changeMode)
        view.liveExecutionToggle.target = self
        view.liveExecutionToggle.action = #selector(changeLiveExecution)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceCodex")
        statusItem.button?.toolTip = "VoiceCodex · 按住 Control Option Space 说话"
        let menu = NSMenu()
        for (title, action) in [("打开 VoiceCodex", #selector(showWindow)),
                                ("新任务", #selector(newTask)),
                                ("选择项目…", #selector(chooseProject)),
                                ("设置…", #selector(showSettings)),
                                ("停止当前任务", #selector(stopExecution))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func showWindow() {
        guard let window, !terminating else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The menu-bar process survives the red close button. Finder/Spotlight
        // opening the app again must restore the existing window and session.
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !executing else { return }
        config.reloadCredentials()
        updateState()
    }

    private func beginRecording() {
        guard recordingState == .idle, !choosingProject, !terminating else { return }
        if isMacMode && executing { showToast(title: "正在执行", text: "完成当前动作后再说下一句；Esc 可停止。"); return }
        config.reloadCredentials()
        if let error = config.environmentError { showFailure(error); return }
        if isMacMode && config.jevAPIKey.isEmpty { showFailure("请在 .env 填入 TYPESAFE_API_KEY，然后再次按住说话。"); return }
        guard !config.sonioxAPIKey.isEmpty else {
            showFailure("先在设置中填写 Soniox API key。")
            showSettings()
            return
        }
        if !isMacMode && config.projectPath == nil { chooseProject(); return }
        if isMacMode {
            macDriver.captureForegroundApplication()
            recordingTargetID = macDriver.foregroundApplicationID
            liveMacRecording = config.liveMacExecution
        }
        overlayTimer?.invalidate()
        releaseRequested = false
        lastError = ""
        let generation = UUID()
        recordingGeneration = generation
        recordingState = .starting
        view.showTranscript("", active: true)
        overlay.title.stringValue = "正在连接实时语音…"
        overlay.transcript.stringValue = "请按住快捷键说话"
        overlay.show()
        hotkey.captureEscape(true)
        updateState()
        let service = RealtimeSTT()
        speech = service
        service.onTranscript = { [weak self] text, _ in
            guard let self, self.recordingGeneration == generation else { return }
            self.view.showTranscript(text, active: true)
            self.overlay.transcript.stringValue = text.isEmpty ? "正在听…" : text
        }
        service.onUtterance = { [weak self] text in
            guard let self, self.recordingGeneration == generation, self.liveMacRecording, self.isMacMode else { return }
            self.executeMac(text, target: self.recordingTargetID)
        }
        service.onLevel = { [weak self] level in
            guard let self, self.recordingGeneration == generation else { return }
            self.view.level.level = level
            self.overlay.level.level = level
        }
        service.onStatus = { [weak self] status in
            guard let self, self.recordingGeneration == generation else { return }
            self.overlay.title.stringValue = status
        }
        service.onError = { [weak self] error in
            guard let self, self.recordingGeneration == generation else { return }
            if self.isMacMode { self.stopExecution() } else { self.cancelRecording() }
            self.showFailure(error.localizedDescription)
        }
        Task { [weak self] in
            guard let self else { return }
            guard self.recordingGeneration == generation else { return }
            if self.releaseRequested { self.cancelRecording(); return }
            do {
                // Ask once before opening a stream, so releasing during the OS dialog
                // never leaves a recording running after permission is granted.
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    guard self.recordingGeneration == generation else { service.cancel(); return }
                    guard allowed else { throw DemoError.message("需要麦克风权限。请在系统设置 → 隐私与安全性 → 麦克风中允许 VoiceCodex。") }
                    if self.releaseRequested {
                        self.cancelRecording()
                        self.showToast(title: "麦克风已就绪", text: "再次按住 \(self.hotkey.label) 开始说话。")
                        return
                    }
                }
                try await service.start(apiKey: self.config.sonioxAPIKey, vocabularyProvider: { [weak self] in
                    self?.refreshSpeechVocabulary() ?? SonioxConnection.defaultContext
                })
                guard self.recordingGeneration == generation else { service.cancel(); return }
                self.recordingState = .recording
                self.overlay.title.stringValue = self.liveMacRecording && self.isMacMode ? "正在听 · 停顿一句，执行一句" : "正在听 · 松手即执行"
                self.updateState()
                if self.releaseRequested { self.endRecording() }
            } catch {
                guard self.recordingGeneration == generation else { return }
                service.cancel()
                self.speech = nil
                self.recordingState = .idle
                self.hotkey.captureEscape(self.executing)
                if self.isMacMode { self.stopExecution() }
                self.showFailure(error.localizedDescription)
            }
        }
    }

    private func endRecording() {
        if recordingState == .starting {
            releaseRequested = true
            speech?.stopCapture()
            return
        }
        guard recordingState == .recording, let service = speech else { return }
        recordingState = .finishing
        overlay.title.stringValue = "正在完成转写…"
        updateState()
        let generation = recordingGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await service.finish().trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.recordingGeneration == generation else { return }
                self.recordingState = .idle
                self.speech = nil
                self.hotkey.captureEscape(self.executing)
                self.view.showTranscript(text, active: false)
                if text.isEmpty {
                    self.showToast(title: "没有听清", text: "请再次按住快捷键说话。")
                    self.updateState()
                } else {
                    if self.isMacMode {
                        // Live callbacks already submitted each endpoint and the EOF tail.
                        if !self.liveMacRecording { self.executeMac(text, target: self.recordingTargetID) }
                    } else { self.enqueue(text) }
                    self.showToast(title: self.isMacMode ? (self.executing ? "正在依次执行" : "本次语音已结束") : (self.executing && !self.queue.isEmpty ? "指令已排队" : "已交给 Codex"), text: text)
                    self.updateState()
                }
            } catch {
                guard self.recordingGeneration == generation else { return }
                service.cancel()
                self.recordingState = .idle
                self.speech = nil
                self.hotkey.captureEscape(self.executing)
                if self.isMacMode { self.stopExecution() }
                self.showFailure(error.localizedDescription)
            }
        }
    }

    private func cancelRecording() {
        recordingGeneration = UUID()
        speech?.cancel()
        speech = nil
        recordingState = .idle
        releaseRequested = false
        hotkey.captureEscape(executing)
        overlay.hide()
        view.showTranscript("本次录音已取消", active: false)
        updateState()
    }

    @objc private func sendTypedCommand() {
        guard !choosingProject, !terminating else { return }
        guard !isMacMode || !executing else { return }
        guard !isMacMode || recordingState == .idle else { return }
        let text = view.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !isMacMode && config.projectPath == nil { chooseProject(); return }
        view.commandField.stringValue = ""
        view.showTranscript(text, active: false)
        enqueue(text)
    }

    private func enqueue(_ text: String) {
        if isMacMode {
            macDriver.captureForegroundApplication()
            executeMac(text, target: macDriver.foregroundApplicationID)
            return
        }
        if !(deliveryPaused && queue.first?.text == text) {
            queue.append(PendingPrompt(text: text))
            appendHistory("你", text)
        }
        deliveryPaused = false
        lastError = ""
        updateState()
        executeNext()
    }

    private func executeMac(_ text: String, target: String?) {
        config.reloadCredentials()
        do {
            if let error = config.environmentError { throw DemoError.message(error) }
            guard !config.jevAPIKey.isEmpty else {
                throw DemoError.message("请在 .env 填入 TYPESAFE_API_KEY。保存后可直接重试，无需重启。")
            }
            let count = try macSequence.enqueue(text, target: target)
            appendHistory("你", text)
            if count > 1 { appendHistory("步骤", "已排入 \(count) 个连续动作，按顺序执行。") }
        } catch {
            stopExecution()
            showFailure(error.localizedDescription)
            return
        }
        updateState()
        guard !executing else { return }
        let client = JevClient(apiKey: config.jevAPIKey, model: config.jevModel)
        executing = true
        lastError = ""
        hotkey.captureEscape(true)
        macTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.executing = false
                self.macTask = nil
                self.hotkey.captureEscape(self.recordingState != .idle)
                self.updateState()
            }
            do {
                try await self.macSequence.run(plan: { text, target in
                    try await client.plan(transcript: text, applications: self.macDriver.applications(), currentApplicationID: target)
                }, perform: { command, step in
                    let applications = self.macDriver.applications()
                    let appName = applications.first { $0.id == command.applicationID }?.name ?? "当前应用"
                    let description = "步骤 \(step.index)/\(step.total) · \(self.actionName(command.intent)) · \(appName)"
                    self.macStatus = description
                    self.appendHistory("Jev", description)
                    self.updateState()
                    if self.macDriver.needsAccessibility(for: command.intent), !self.macDriver.accessibilityGranted {
                        throw DemoError.message("需要辅助功能权限来执行这个动作。点击「启用辅助功能」，在系统设置中允许 VoiceCodex 后重试。")
                    }
                    if [.clickElement, .paste, .pressReturn, .closeAllWindows].contains(command.intent) {
                        try await self.macDriver.waitForInterface(command: command)
                    }
                    try Task.checkCancellation()
                    return try await self.macDriver.execute(command: command, goal: step.text, jev: client)
                }, onStep: { step in
                    self.macStatus = "步骤 \(step.index)/\(step.total) · Jev 正在理解…"
                    self.updateState()
                }, onReceipt: { command, receipt in
                    self.appendHistory("Mac", receipt)
                    if self.recordingState != .idle, let target = command.applicationID { self.recordingTargetID = target }
                })
                self.macStatus = self.recordingState == .idle ? "连续动作已结束 · 可以继续说话" : "已执行 · 正在听下一句"
                if self.recordingState == .idle { self.showToast(title: "动作已结束", text: "已完成本次动作队列。") }
            } catch is CancellationError {
                if self.recordingState != .idle { self.cancelRecording() }
                self.macStatus = "已停止"
                self.appendHistory("系统", "已停止后续操作。已执行的动作不会自动撤销。")
            } catch {
                if self.recordingState != .idle { self.cancelRecording() }
                self.macStatus = "动作未完成 · 后续步骤已停止"
                self.showFailure(error.localizedDescription)
            }
        }
        updateState()
    }

    private func actionName(_ intent: MacIntent) -> String {
        switch intent {
        case .openApp: return "打开应用"
        case .newTab: return "新建标签页"
        case .closeTab: return "关闭当前标签页"
        case .newWindow: return "新建窗口 / 文稿"
        case .closeWindow: return "关闭窗口"
        case .closeAllWindows: return "关闭全部窗口"
        case .typeText: return "输入原文"
        case .pressReturn: return "按回车"
        case .copy: return "复制"
        case .paste: return "粘贴"
        case .undo: return "撤销"
        case .scrollDown: return "向下滚动"
        case .scrollUp: return "向上滚动"
        case .clickElement: return "点击控件"
        case .unsupported: return "暂不支持"
        }
    }

    @objc private func changeLiveExecution() {
        guard !executing, recordingState == .idle else { return }
        config.liveMacExecution = view.liveExecutionToggle.state == .on
        do { try config.save() } catch { showFailure(error.localizedDescription) }
        updateState()
    }

    @objc private func changeMode() {
        guard !executing, recordingState == .idle else { return }
        persistHistory()
        config.executionMode = view.modeSelector.selectedSegment == 0 ? "mac" : "codex"
        executing = isMacMode ? (macTask != nil) : (submitting || terminalActive)
        do { try config.save() } catch { showFailure(error.localizedDescription); return }
        lastError = ""
        view.configureMode(mac: isMacMode)
        loadHistory()
        updateProject()
        updateState()
    }

    @objc private func enableAccessibility() {
        macDriver.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func enableScreenRecognition() {
        // Only an explicit user press opens the OS permission flow.
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openEnvironment() {
        let file = config.envFile
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let template = "TYPESAFE_API_KEY=\nTYPESAFE_DEFAULT_MODEL=jev-1.13.0\nSONIOX_API_KEY=\n"
                try template.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { showFailure(error.localizedDescription); return }
        }
        NSWorkspace.shared.open(file)
    }

    @objc private func fillExample() {
        view.commandField.stringValue = "打开腾讯会议，然后创建一个新的会议"
        window.makeFirstResponder(view.commandField)
    }

    private func updateMacTarget() {
        guard view != nil, isMacMode else { return }
        let name = macDriver.foregroundApplicationID.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
        }
        view.macTargetLabel.stringValue = name.map { "当前应用：\($0)" } ?? "此 Mac · 说出应用名称"
        view.permissionsButton.title = macDriver.accessibilityGranted ? "辅助功能已开启 ✓" : "启用辅助功能"
        view.screenPermissionButton.title = CGPreflightScreenCaptureAccess() ? "屏幕识别已开启 ✓" : "启用屏幕识别"
    }

    private var historyFile: URL {
        LocalConfig.directory.appendingPathComponent(isMacMode ? "mac-history.txt" : "session-history.txt")
    }

    private func loadHistory() {
        history = (try? String(contentsOf: historyFile, encoding: .utf8)).map { String($0.suffix(100_000)) } ?? ""
        view.results.string = history.isEmpty ? (isMacMode ?
            "从一句简单指令开始。\n\n「打开 Chrome」　「新建一个标签页」\n「打开便笺」　「输入『hello world』」\n\n可用「然后」连接动作。边说边做时，停顿一句就开始执行；这里显示每一步的结果。" :
            "语音和文字指令会发送到 Terminal 中的 Codex 会话。") : history
        view.results.textColor = history.isEmpty ? Theme.muted : Theme.ink
        view.results.scrollToEndOfDocument(nil)
        view.showTranscript(isMacMode ? "试着说：打开腾讯会议，然后创建一个新的会议。" : "试着说：帮我看看这个项目。", active: false)
    }

    private func executeNext() {
        guard !submitting, !queue.isEmpty, let projectPath = config.projectPath else { return }
        guard FileManager.default.isExecutableFile(atPath: config.codexPath) else {
            queue.removeAll()
            showFailure("没有找到 Codex CLI。请在设置中选择已安装的 codex 可执行文件，并先运行 codex login。")
            return
        }
        let submission = queue[0]
        deliveryPaused = false
        submitting = true
        executing = true
        updateState()
        runTask = Task { [weak self] in
            guard let self else { return }
            var attemptedDelivery = false
            var delivered = false
            do {
                let workspace = try await self.prepareWorkspace(projectPath: projectPath)
                let session = try await self.ensureTerminal(workspace: workspace)
                try Task.checkCancellation()
                guard let terminal = self.terminal, self.terminalIsOpen else {
                    throw DemoError.message("Terminal 已关闭。请重新发送指令。")
                }
                attemptedDelivery = true
                _ = try await terminal.enqueue(prompt: submission.text, sessionID: session, clientMessageID: submission.id)
                try Task.checkCancellation()
                guard self.terminal === terminal else { throw CancellationError() }
                if self.queue.first?.id == submission.id { self.queue.removeFirst() }
                delivered = true
                self.deliveryGeneration += 1
                self.terminalActive = true
                self.appendHistory("Terminal", "指令已送达。完整执行过程、确认提示和回复在终端显示。")
                self.lastError = ""
            } catch is CancellationError {
                self.appendHistory("系统", "发送已取消。")
            } catch {
                if !Task.isCancelled {
                    self.deliveryPaused = true
                    if attemptedDelivery {
                        // Queue IDs are correlation fields, not deduplication keys.
                        // Never retry a request that might already have executed.
                        if self.queue.first?.id == submission.id { self.queue.removeFirst() }
                        self.showFailure(error.localizedDescription + " 送达状态未确认；请先查看 Terminal，再决定是否重发这条指令。")
                    } else {
                        self.showFailure(error.localizedDescription + " 指令已保留，打开终端后可继续发送。")
                    }
                }
            }
            self.submitting = false
            self.executing = self.terminalActive
            self.runTask = nil
            self.updateProject()
            self.updateState()
            if !Task.isCancelled, delivered { self.executeNext() }
        }
    }

    private func prepareWorkspace(projectPath: String) async throws -> URL {
        if let path = config.workspacePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        view.taskLabel.stringValue = "正在创建工作目录…"
        let storage = LocalConfig.directory.appendingPathComponent("worktrees", isDirectory: true)
        let preparation = Task.detached {
            try WorkspaceManager.prepare(project: URL(fileURLWithPath: projectPath), storage: storage)
        }
        let workspace = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        config.workspacePath = workspace.path
        config.sessionID = nil
        try config.save()
        appendHistory("工作目录", workspace.path)
        updateProject()
        return workspace
    }

    private var terminalIsOpen: Bool {
        guard let launch = terminalLaunch else { return false }
        guard !FileManager.default.fileExists(atPath: launch.exitedURL.path),
              let started = try? String(contentsOf: launch.startedURL, encoding: .utf8),
              let pid = Int32(started.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0
    }

    private func ensureTerminal(workspace: URL) async throws -> String {
        if !terminalIsOpen || terminal == nil {
            closeTerminalConnection()
            view.taskLabel.stringValue = "正在打开 Terminal…"
            let connection = TerminalSession(executableURL: URL(fileURLWithPath: config.codexPath))
            terminal = connection
            let address = try await connection.start()
            try Task.checkCancellation()
            guard terminal === connection else { throw CancellationError() }
            let resumeID = try await connection.restorableSessionID(config.sessionID, workspace: workspace)
            try Task.checkCancellation()
            guard terminal === connection else { throw CancellationError() }
            if config.sessionID != resumeID {
                config.sessionID = resumeID
                try config.save()
                updateProject()
            }
            let launch = try TerminalLauncher.prepare(
                executableURL: URL(fileURLWithPath: config.codexPath), workspaceURL: workspace,
                remoteAddress: address, authTokenFileURL: connection.tokenFileURL,
                prompt: nil, sessionID: resumeID,
                storageURL: LocalConfig.directory.appendingPathComponent("terminal", isDirectory: true))
            terminalLaunch = launch
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw DemoError.message("没有找到 macOS Terminal。")
            }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = true
            _ = try await NSWorkspace.shared.open([launch.commandURL], withApplicationAt: app, configuration: options)
            try Task.checkCancellation()
            guard terminal === connection else { throw CancellationError() }
            appendHistory("Terminal", "已打开交互式 Codex。首次使用时，请在终端完成启动提示。")
        }
        guard let connection = terminal, let launch = terminalLaunch else { throw CancellationError() }
        view.taskLabel.stringValue = "等待终端就绪…"
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: launch.exitedURL.path) {
                throw DemoError.message("Codex 已退出。请查看 Terminal 中的错误，修复后重新发送。需要支持 --remote 的新版 Codex CLI。")
            }
            if terminalIsOpen,
               let id = try await connection.discover(workspace: workspace, expectedSessionID: config.sessionID) {
                try Task.checkCancellation()
                guard terminal === connection else { throw CancellationError() }
                config.sessionID = id
                try config.save()
                updateProject()
                startTerminalMonitor(connection: connection, sessionID: id, launch: launch)
                return id
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw DemoError.message("Terminal 尚未就绪，指令没有发送。请完成终端中的启动提示，再重新发送。")
    }

    private func startTerminalMonitor(connection: TerminalSession, sessionID: String, launch: TerminalLaunchFiles) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.terminalIsOpen {
                    self.appendTerminalHistory("终端会话已关闭。再次说话会恢复这个会话。")
                    self.closeTerminalConnection()
                    self.updateState()
                    return
                }
                do {
                    let generation = self.deliveryGeneration
                    let state = try await connection.snapshot(sessionID: sessionID)
                    try Task.checkCancellation()
                    guard self.terminal === connection else { return }
                    if self.deliveryGeneration != generation { continue }
                    self.terminalActive = state.isActive
                    self.waitingForApproval = state.waitingForApproval
                    if !self.isMacMode { self.executing = self.submitting || state.isActive }
                    self.updateState()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.terminal === connection else { return }
                    self.closeTerminalConnection()
                    if self.isMacMode { self.appendTerminalHistory("Terminal 连接已断开。切回编程模式后可重新连接。") }
                    else { self.showFailure("Terminal 连接已断开：" + error.localizedDescription) }
                    return
                }
            }
        }
    }

    private func closeTerminalConnection() {
        monitorTask?.cancel()
        monitorTask = nil
        terminal?.shutdown()
        terminal = nil
        terminalLaunch = nil
        terminalActive = false
        waitingForApproval = false
        if !isMacMode { executing = submitting }
    }

    @objc private func openTerminal() {
        guard !isMacMode, !submitting, !choosingProject, !terminating else { return }
        if terminalIsOpen {
            if deliveryPaused && !queue.isEmpty { executeNext() }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?
                .activate(options: [.activateAllWindows])
            return
        }
        guard let projectPath = config.projectPath else { chooseProject(); return }
        submitting = true
        executing = true
        updateState()
        runTask = Task { [weak self] in
            guard let self else { return }
            var opened = false
            do {
                let workspace = try await self.prepareWorkspace(projectPath: projectPath)
                _ = try await self.ensureTerminal(workspace: workspace)
                opened = true
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.showFailure(error.localizedDescription) } }
            self.submitting = false
            self.executing = self.terminalActive
            self.runTask = nil
            self.updateState()
            if !Task.isCancelled, opened { self.executeNext() }
        }
    }

    @objc private func stopExecution() {
        if isMacMode {
            macSequence.clear()
            macTask?.cancel()
            if recordingState != .idle { cancelRecording() }
            macStatus = executing ? "正在停止…" : "已停止"
            updateState()
            return
        }
        queue.removeAll()
        if recordingState != .idle { cancelRecording() }
        runTask?.cancel()
        if submitting {
            closeTerminalConnection()
        } else if let terminal, let id = config.sessionID {
            Task {
                do {
                    try await terminal.interrupt(sessionID: id)
                    appendHistory("系统", "已请求停止当前任务并清空排队指令。终端仍可继续使用。")
                } catch { showFailure(error.localizedDescription) }
            }
        }
        updateState()
    }

    @objc private func chooseProject() {
        guard !choosingProject else { return }
        guard !executing, !submitting, !terminalActive, recordingState == .idle else {
            showToast(title: "任务进行中", text: "结束当前任务后再切换项目。")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "使用这个项目"
        panel.message = "选择一个 Git 项目。新任务会从已提交的 HEAD 创建独立 worktree。"
        choosingProject = true
        showWindow()
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.choosingProject = false
                guard response == .OK, let url = panel.url,
                      !self.executing, !self.submitting, !self.terminalActive,
                      self.recordingState == .idle else { return }
                self.config.projectPath = url.path
                self.resetSession()
            }
        }
    }

    @objc private func newTask() {
        guard !executing, recordingState == .idle else { showToast(title: "任务进行中", text: "结束当前任务后再创建新任务。"); return }
        if isMacMode {
            history = ""
            persistHistory()
            loadHistory()
            lastError = ""
            updateState()
            return
        }
        resetSession()
    }

    private func resetSession() {
        closeTerminalConnection()
        config.workspacePath = nil
        config.sessionID = nil
        queue.removeAll()
        deliveryPaused = false
        lastError = ""
        history = ""
        view.results.string = "新任务已准备好。说出你的第一条指令。"
        view.transcript.string = "试着说：帮我看看这个项目，下一步可以做什么。"
        view.transcript.textColor = Theme.muted
        persistHistory()
        do { try config.save() } catch { showFailure(error.localizedDescription) }
        updateProject()
        updateState()
    }

    @objc private func openWorktree() {
        guard let path = config.workspacePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func updateProject() {
        view.projectButton.title = config.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent + "  ▾" } ?? "选择项目  ▾"
        view.projectButton.toolTip = config.projectPath
        view.sessionLabel.stringValue = config.sessionID.map { "会话 " + String($0.suffix(8)) } ?? "新会话"
        view.openWorktreeButton.isEnabled = config.workspacePath != nil
        view.openTerminalButton.isEnabled = config.projectPath != nil && !submitting
    }

    @discardableResult
    private func refreshSpeechVocabulary() -> [String: Any] {
        let vocabulary = SpeechVocabulary.build(applications: macDriver.applications(),
                                                 currentApplicationID: macDriver.foregroundApplicationID)
        speechVocabulary = vocabulary
        updateSpeechLabel()
        return vocabulary.context
    }

    private func updateSpeechLabel() {
        if config.sonioxAPIKey.isEmpty {
            view.providerLabel.stringValue = "SONIOX  /  等待配置"
        } else {
            view.providerLabel.stringValue = "SONIOX · 中文 / English · \(speechVocabulary?.terms.count ?? 0) 热词"
        }
        if let vocabulary = speechVocabulary {
            view.providerLabel.toolTip = "已载入 \(vocabulary.includedApplicationCount) 个 App 的名称及常见中英文叫法。每次录音自动刷新，优先当前和正在运行的 App。" +
                (vocabulary.omittedApplicationCount > 0 ? "词表已达到容量限制，另有 \(vocabulary.omittedApplicationCount) 个 App 未纳入。" : "")
        }
    }

    private func updateState() {
        guard view != nil else { return }
        let recording = recordingState == .starting || recordingState == .recording
        view.level.active = recording
        overlay.level.active = recording
        view.recordButton.title = recording ? (isMacMode && liveMacRecording ? "松开结束" : "松开执行") : "按住说话"
        view.liveExecutionToggle.state = config.liveMacExecution ? .on : .off
        view.liveExecutionToggle.isEnabled = !executing && recordingState == .idle
        view.shortcutHint.stringValue = isMacMode && config.liveMacExecution ? "停顿一句 · 执行一句" : "按住说话 · 松开执行"
        view.stopButton.isEnabled = executing || !queue.isEmpty || recordingState != .idle
        view.openTerminalButton.isEnabled = config.projectPath != nil && !submitting
        view.newTaskButton.isEnabled = !executing && recordingState == .idle
        view.projectButton.isEnabled = !executing && recordingState == .idle
        view.modeSelector.isEnabled = !executing && recordingState == .idle
        view.sendButton.isEnabled = !isMacMode || (!executing && recordingState == .idle)
        view.recordButton.isEnabled = !isMacMode || !executing || recordingState != .idle
        view.examplesButton.isEnabled = !executing
        view.permissionsButton.isEnabled = !executing
        view.screenPermissionButton.isEnabled = !executing
        updateMacTarget()
        updateSpeechLabel()
        let state: String
        switch recordingState {
        case .starting: state = "正在连接"
        case .recording: state = isMacMode && executing ? "正在听 · 正在执行" : "正在听"
        case .finishing: state = "正在转写"
        case .idle:
            if isMacMode {
                state = executing ? "正在执行" : (!lastError.isEmpty ? "需要留意" : (config.jevAPIKey.isEmpty ? "等待 Jev key" : "准备就绪"))
            } else {
                state = executing ? (waitingForApproval ? "请在终端确认" : (submitting ? "正在发送" : "终端执行中")) :
                    (!lastError.isEmpty ? "需要留意" : (config.sonioxAPIKey.isEmpty ? "等待配置" : "准备就绪"))
            }
        }
        view.stateLabel.stringValue = "●  " + state
        view.stateLabel.textColor = !lastError.isEmpty && recordingState == .idle ? .systemOrange : Theme.green
        if isMacMode {
            view.taskLabel.stringValue = macStatus + (macSequence.pendingCount > 0 ? " · 待执行 \(macSequence.pendingCount) 步" : "")
        } else if !submitting {
            view.taskLabel.stringValue = waitingForApproval ? "请在终端确认" :
                (terminalActive ? "Codex 正在终端执行…" : (terminalIsOpen ? "终端已连接 · 可以继续说话" : "等待打开终端"))
        }
        statusItem?.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : (executing ? "waveform.badge.mic" : "waveform"),
                                          accessibilityDescription: "VoiceCodex · " + state)
    }

    private func appendHistory(_ role: String, _ text: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        history += (history.isEmpty ? "" : "\n\n") + "\(role)  ·  \(time)\n\(text)"
        if history.count > 100_000 { history = String(history.suffix(100_000)) }
        view.results.string = history
        view.results.textColor = Theme.ink
        view.results.scrollToEndOfDocument(nil)
        persistHistory()
    }

    private func appendTerminalHistory(_ text: String) {
        guard isMacMode else { appendHistory("Terminal", text); return }
        let file = LocalConfig.directory.appendingPathComponent("session-history.txt")
        let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let next = String((previous + "\n\nTerminal · \(time)\n" + text).suffix(100_000))
        try? next.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func persistHistory() {
        try? FileManager.default.createDirectory(at: LocalConfig.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = historyFile
        try? history.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func showFailure(_ message: String) {
        // Provider credentials are never included in visible errors, even if a
        // library unexpectedly echoes a request in its error description.
        let safe = [config.sonioxAPIKey, config.jevAPIKey].filter { !$0.isEmpty }.reduce(message) {
            $0.replacingOccurrences(of: $1, with: "[redacted]")
        }
        lastError = String(safe.prefix(1600))
        appendHistory("出错了", lastError)
        updateState()
        if recordingState == .idle { showToast(title: "需要留意", text: String(lastError.prefix(110))) }
    }

    private func showToast(title: String, text: String) {
        overlayTimer?.invalidate()
        overlay.title.stringValue = title
        overlay.transcript.stringValue = text
        overlay.level.active = false
        overlay.show()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingState == .idle else { return }
                self.overlay.hide()
            }
        }
    }

    @objc private func showSettings() {
        config.reloadCredentials()
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "VoiceCodex 设置"
        panel.isReleasedWhenClosed = false
        let keyField = NSSecureTextField()
        keyField.placeholderString = config.sonioxAPIKey.isEmpty ? "填入 Soniox API key" : "已配置 · 留空保持当前 key"
        keyField.setAccessibilityLabel("Soniox API key")
        let pathField = NSTextField(string: config.codexPath)
        pathField.setAccessibilityLabel("Codex CLI 路径")
        apiKeyField = keyField
        executableField = pathField
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let envButton = NSButton(title: "打开 Jev 的 .env", target: self, action: #selector(openEnvironment))
        envButton.bezelStyle = .rounded
        let jevLabel = textLabel(config.jevAPIKey.isEmpty ? "Jev：等待 TYPESAFE_API_KEY" : "Jev：已配置 · \(config.jevModel)", size: 12, color: Theme.muted)
        let content = vstack([textLabel("语音与执行", size: 20, weight: .semibold),
                              hstack([jevLabel, spacer(), envButton]),
                              textLabel("Soniox API key", size: 12, weight: .medium), keyField,
                              textLabel("Codex CLI 路径", size: 12, weight: .medium), pathField,
                              textLabel("凭证保存在本机 Application Support，文件权限为 600。", size: 11, color: Theme.muted),
                              hstack([spacer(), save])], spacing: 12)
        let container = CardView(content: content, inset: 24, color: Theme.background)
        panel.contentView = container
        for field in [keyField, pathField] { field.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        settingsWindow = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveSettings() {
        if let key = apiKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { config.sonioxAPIKey = key }
        if let path = executableField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) { config.codexPath = path }
        do {
            try config.save()
            config.reloadCredentials()
            apiKeyField?.stringValue = ""
            settingsWindow?.close()
            settingsWindow = nil
            lastError = ""
            updateState()
        } catch { showFailure(error.localizedDescription) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        if recordingState != .idle || executing {
            let alert = NSAlert()
            alert.messageText = "退出并停止当前任务？"
            alert.informativeText = isMacMode ? "当前录音和后续 Mac 操作会停止；已经完成的动作会保留。" : "当前录音与本应用打开的 Codex 终端连接会停止。工作目录和会话会保留。"
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "继续运行")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        speech?.cancel()
        macTask?.cancel()
        closeTerminalConnection()
        runTask?.cancel()
        hotkey.unregister()
        if let pending = macTask ?? runTask {
            terminating = true
            Task {
                await pending.value
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    private enum DemoError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
