import AppKit
import AVFoundation
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
    private var runner: CodexRunner?
    private var recordingState = RecordingState.idle
    private var recordingGeneration = UUID()
    private var releaseRequested = false
    private var queue: [String] = []
    private var executing = false
    private var runTask: Task<Void, Never>?
    private var activeRunID: UUID?
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

        view = MainView(frame: NSRect(x: 0, y: 0, width: 860, height: 780))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "VoiceCodex"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
        window.contentView = view
        window.minSize = NSSize(width: 780, height: 760)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        wireButtons()
        setupMenuBar()
        do { try hotkey.register() } catch { lastError = error.localizedDescription }
        view.shortcutLabel.stringValue = hotkey.label
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.endRecording() }
        hotkey.onEscape = { [weak self] in self?.cancelRecording() }
        updateProject()
        if let data = try? String(contentsOf: LocalConfig.directory.appendingPathComponent("session-history.txt"), encoding: .utf8), !data.isEmpty {
            history = String(data.suffix(100_000))
            view.results.string = history
            view.results.textColor = Theme.ink
            view.results.scrollToEndOfDocument(nil)
        }
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
                                 (view.sendButton, #selector(sendTypedCommand))] {
            button.target = self
            button.action = action
        }
        view.commandField.target = self
        view.commandField.action = #selector(sendTypedCommand)
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func beginRecording() {
        guard recordingState == .idle, !choosingProject, !terminating else { return }
        guard !config.sonioxAPIKey.isEmpty else {
            showFailure("先在设置中填写 Soniox API key。")
            showSettings()
            return
        }
        guard config.projectPath != nil else { chooseProject(); return }
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
            self.cancelRecording()
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
                try await service.start(apiKey: self.config.sonioxAPIKey)
                guard self.recordingGeneration == generation else { service.cancel(); return }
                self.recordingState = .recording
                self.overlay.title.stringValue = "正在听 · 松手即执行"
                self.updateState()
                if self.releaseRequested { self.endRecording() }
            } catch {
                guard self.recordingGeneration == generation else { return }
                service.cancel()
                self.speech = nil
                self.recordingState = .idle
                self.hotkey.captureEscape(false)
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
                self.hotkey.captureEscape(false)
                self.view.showTranscript(text, active: false)
                if text.isEmpty {
                    self.showToast(title: "没有听清", text: "请再次按住快捷键说话。")
                    self.updateState()
                } else {
                    self.enqueue(text)
                    self.showToast(title: self.executing && !self.queue.isEmpty ? "指令已排队" : "已交给 Codex", text: text)
                }
            } catch {
                guard self.recordingGeneration == generation else { return }
                service.cancel()
                self.recordingState = .idle
                self.speech = nil
                self.hotkey.captureEscape(false)
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
        hotkey.captureEscape(false)
        overlay.hide()
        view.showTranscript("本次录音已取消", active: false)
        updateState()
    }

    @objc private func sendTypedCommand() {
        guard !choosingProject, !terminating else { return }
        let text = view.commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard config.projectPath != nil else { chooseProject(); return }
        view.commandField.stringValue = ""
        view.showTranscript(text, active: false)
        enqueue(text)
    }

    private func enqueue(_ text: String) {
        queue.append(text)
        appendHistory("你", text)
        lastError = ""
        updateState()
        executeNext()
    }

    private func executeNext() {
        guard !executing, !queue.isEmpty, let projectPath = config.projectPath else { return }
        guard FileManager.default.isExecutableFile(atPath: config.codexPath) else {
            queue.removeAll()
            showFailure("没有找到 Codex CLI。请在设置中选择已安装的 codex 可执行文件，并先运行 codex login。")
            return
        }
        let prompt = queue.removeFirst()
        let runID = UUID()
        activeRunID = runID
        executing = true
        updateState()
        let processRunner = CodexRunner(executableURL: URL(fileURLWithPath: config.codexPath))
        runner = processRunner
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let workspace: URL
                if let path = self.config.workspacePath, FileManager.default.fileExists(atPath: path) {
                    workspace = URL(fileURLWithPath: path)
                } else {
                    self.view.taskLabel.stringValue = "正在创建工作目录…"
                    let storage = LocalConfig.directory.appendingPathComponent("worktrees", isDirectory: true)
                    let preparation = Task.detached {
                        try WorkspaceManager.prepare(project: URL(fileURLWithPath: projectPath), storage: storage)
                    }
                    workspace = try await withTaskCancellationHandler {
                        try await preparation.value
                    } onCancel: {
                        preparation.cancel()
                    }
                    self.config.workspacePath = workspace.path
                    self.config.sessionID = nil
                    try self.config.save()
                    self.appendHistory("工作目录", workspace.path)
                }
                try Task.checkCancellation()
                self.updateProject()
                self.view.taskLabel.stringValue = "Codex 正在执行…"
                let result = try await processRunner.run(prompt: prompt, directory: workspace,
                                                        sessionID: self.config.sessionID) { [weak self] event in
                    Task { @MainActor in self?.receive(event, runID: runID) }
                }
                self.config.sessionID = result.sessionID ?? self.config.sessionID
                try self.config.save()
                self.appendHistory("Codex", result.answer.isEmpty ? "任务完成。" : result.answer)
                if self.recordingState == .idle {
                    self.showToast(title: "Codex 已完成", text: String(result.answer.prefix(100)))
                }
                self.lastError = ""
            } catch is CancellationError {
                self.appendHistory("系统", "任务已停止。")
            } catch {
                if !Task.isCancelled { self.showFailure(error.localizedDescription) }
            }
            self.executing = false
            self.activeRunID = nil
            self.runner = nil
            self.runTask = nil
            self.updateProject()
            self.updateState()
            if !Task.isCancelled { self.executeNext() }
        }
    }

    private func receive(_ event: CodexEvent, runID: UUID) {
        guard activeRunID == runID else { return }
        switch event {
        case .sessionID(let id):
            config.sessionID = id
            try? config.save()
            updateProject()
        case .activity(let activity):
            view.taskLabel.stringValue = String(activity.prefix(42))
            appendHistory("执行", String(activity.prefix(1200)))
        case .answer:
            break // The authoritative final answer is appended once at run completion.
        }
    }

    @objc private func stopExecution() {
        queue.removeAll()
        if recordingState != .idle { cancelRecording() }
        runner?.cancel()
        runTask?.cancel()
        updateState()
    }

    @objc private func chooseProject() {
        guard !choosingProject else { return }
        guard !executing, recordingState == .idle else { showToast(title: "任务进行中", text: "结束当前任务后再切换项目。"); return }
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
                      !self.executing, self.recordingState == .idle else { return }
                self.config.projectPath = url.path
                self.resetSession()
            }
        }
    }

    @objc private func newTask() {
        guard !executing, recordingState == .idle else { showToast(title: "任务进行中", text: "结束当前任务后再创建新任务。"); return }
        resetSession()
    }

    private func resetSession() {
        config.workspacePath = nil
        config.sessionID = nil
        activeRunID = nil
        queue.removeAll()
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
    }

    private func updateState() {
        let recording = recordingState == .starting || recordingState == .recording
        view.level.active = recording
        overlay.level.active = recording
        view.recordButton.title = recording ? "松开执行" : "按住说话"
        view.stopButton.isEnabled = executing || recordingState != .idle
        view.newTaskButton.isEnabled = !executing && recordingState == .idle
        view.projectButton.isEnabled = !executing && recordingState == .idle
        view.providerLabel.stringValue = config.sonioxAPIKey.isEmpty ? "SONIOX  /  等待配置" : "SONIOX  /  LIVE STT"
        let state: String
        switch recordingState {
        case .starting: state = "正在连接"
        case .recording: state = "正在听"
        case .finishing: state = "正在转写"
        case .idle:
            state = executing ? (queue.isEmpty ? "正在执行" : "执行中 · \(queue.count) 条排队") :
                (!lastError.isEmpty ? "需要留意" : (config.sonioxAPIKey.isEmpty ? "等待配置" : "准备就绪"))
        }
        view.stateLabel.stringValue = "●  " + state
        view.stateLabel.textColor = !lastError.isEmpty && recordingState == .idle ? .systemOrange : Theme.green
        if !executing { view.taskLabel.stringValue = config.sessionID == nil ? "等待第一条指令" : "可以继续说话" }
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

    private func persistHistory() {
        try? FileManager.default.createDirectory(at: LocalConfig.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = LocalConfig.directory.appendingPathComponent("session-history.txt")
        try? history.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func showFailure(_ message: String) {
        // Provider credentials are never included in visible errors, even if a
        // library unexpectedly echoes a request in its error description.
        let safe = config.sonioxAPIKey.isEmpty ? message : message.replacingOccurrences(of: config.sonioxAPIKey, with: "[redacted]")
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
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
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
        let content = vstack([textLabel("云端实时转写", size: 20, weight: .semibold),
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
            alert.informativeText = "当前录音或 Codex 进程会停止。已创建的工作目录会保留。"
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "继续运行")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        speech?.cancel()
        runner?.cancel()
        runTask?.cancel()
        hotkey.unregister()
        if let pending = runTask {
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
