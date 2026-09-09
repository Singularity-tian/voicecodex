import AppKit

enum Theme {
    static let ink = NSColor(hex: 0x202B26)
    static let muted = NSColor(hex: 0x748078)
    static let green = NSColor(hex: 0x247B56)
    static let mint = NSColor(hex: 0xE1F2E6)
    static let background = NSColor(hex: 0xF4F5F0)
    static let border = NSColor(hex: 0xDFE5DB)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

func textLabel(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
               color: NSColor = Theme.ink) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

func hstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

func vstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
}

func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    return view
}

final class CardView: NSView {
    init(content: NSView, inset: CGFloat = 20, color: NSColor = .white) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class HoldButton: NSButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isHighlighted = true
        onPress?()
    }
    override func mouseUp(with event: NSEvent) {
        guard isHighlighted else { return }
        isHighlighted = false
        onRelease?()
    }
    override func accessibilityPerformPress() -> Bool {
        if isHighlighted { isHighlighted = false; onRelease?() }
        else { isHighlighted = true; onPress?() }
        return true
    }
}

final class LevelView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 90, height: 28) }
    override func draw(_ dirtyRect: NSRect) {
        (active ? Theme.green : Theme.border).setFill()
        for index in 0..<15 {
            let modulation = CGFloat(0.3 + abs(sin(Double(index) * 1.7)) * 0.7)
            let height = max(4, min(27, CGFloat(level) * 100 * modulation + (active ? modulation * 6 : 0)))
            NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * 6, y: (bounds.height - height) / 2,
                                           width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

@MainActor
final class MainView: NSView {
    let stateLabel = textLabel("●  准备就绪", size: 12, weight: .medium, color: Theme.green)
    let providerLabel = textLabel("SONIOX  /  LIVE STT", size: 10, weight: .semibold, color: Theme.muted)
    let shortcutLabel = textLabel("⌃  ⌥  Space", size: 20, weight: .medium)
    let transcript = NSTextView()
    let results = NSTextView()
    let recordButton = HoldButton(title: "按住说话", target: nil, action: nil)
    let level = LevelView()
    let projectButton = NSButton(title: "选择项目", target: nil, action: nil)
    let newTaskButton = NSButton(title: "新任务", target: nil, action: nil)
    let settingsButton = NSButton(title: "设置", target: nil, action: nil)
    let stopButton = NSButton(title: "停止", target: nil, action: nil)
    let openWorktreeButton = NSButton(title: "打开工作目录", target: nil, action: nil)
    let commandField = NSTextField()
    let sendButton = NSButton(title: "执行 ↗", target: nil, action: nil)
    let taskLabel = textLabel("等待第一条指令", size: 11, color: Theme.muted)
    let sessionLabel = textLabel("新会话", size: 10, color: Theme.muted)
    let footerLabel = textLabel("按住期间，音频实时发送至 Soniox。Esc 取消录音。", size: 10, color: Theme.muted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "VoiceCodex")!)
        icon.contentTintColor = Theme.green
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let wordmark = vstack([textLabel("VoiceCodex", size: 18, weight: .semibold),
                              textLabel("VOICE IN. WORK DONE.", size: 9, weight: .medium, color: Theme.muted)], spacing: 3)
        let top = hstack([icon, wordmark, spacer(), stateLabel, settingsButton], spacing: 12)
        settingsButton.bezelStyle = .inline
        settingsButton.font = .systemFont(ofSize: 11)

        let hero = vstack([textLabel("说一句，交给 Codex。", size: 32, weight: .semibold),
                           textLabel("在任何 App 里按住快捷键。松手，工作就开始。", size: 13, color: Theme.muted)], spacing: 8)
        let shortcut = hstack([shortcutLabel, textLabel("按住说话 · 松开执行", size: 12, color: Theme.muted),
                              spacer(), level, recordButton], spacing: 16)
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.contentTintColor = Theme.green
        recordButton.font = .systemFont(ofSize: 14, weight: .semibold)
        recordButton.widthAnchor.constraint(equalToConstant: 126).isActive = true
        recordButton.heightAnchor.constraint(equalToConstant: 38).isActive = true
        recordButton.setAccessibilityLabel("按住说话")

        setupTextView(transcript, font: .systemFont(ofSize: 19, weight: .medium))
        transcript.string = "试着说：帮我看看这个项目，下一步可以做什么。"
        transcript.textColor = Theme.muted
        transcript.setAccessibilityIdentifier("transcript")
        let transcriptScroll = scrolling(transcript)
        transcriptScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        let transcriptHeading = hstack([textLabel("实时转写", size: 11, weight: .semibold, color: Theme.muted),
                                        spacer(), providerLabel])
        let voiceContent = vstack([shortcut, separator(), transcriptHeading, transcriptScroll], spacing: 15)
        [shortcut, transcriptHeading, transcriptScroll].forEach { $0.widthAnchor.constraint(equalTo: voiceContent.widthAnchor).isActive = true }
        let voiceCard = CardView(content: voiceContent)

        projectButton.bezelStyle = .inline
        projectButton.font = .systemFont(ofSize: 12, weight: .medium)
        projectButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        projectButton.imagePosition = .imageLeading
        projectButton.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        newTaskButton.bezelStyle = .inline
        newTaskButton.font = .systemFont(ofSize: 11)
        let projectRow = hstack([textLabel("当前项目", size: 11, color: Theme.muted), projectButton,
                                spacer(), sessionLabel, newTaskButton])

        setupTextView(results, font: .systemFont(ofSize: 13))
        results.string = "你的指令和 Codex 的执行结果会显示在这里。\n\n每个新任务在独立 worktree 中运行；继续说话会沿用同一个会话。"
        results.textColor = Theme.muted
        results.setAccessibilityIdentifier("execution-results")
        let resultScroll = scrolling(results)
        resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        resultScroll.setContentHuggingPriority(.init(1), for: .vertical)
        stopButton.bezelStyle = .inline
        stopButton.isEnabled = false
        stopButton.font = .systemFont(ofSize: 11)
        openWorktreeButton.bezelStyle = .inline
        openWorktreeButton.font = .systemFont(ofSize: 11)
        openWorktreeButton.isEnabled = false
        let resultHeader = hstack([textLabel("执行记录", size: 12, weight: .semibold), taskLabel,
                                   spacer(), openWorktreeButton, stopButton])
        let resultContent = vstack([resultHeader, resultScroll], spacing: 14)
        [resultHeader, resultScroll].forEach { $0.widthAnchor.constraint(equalTo: resultContent.widthAnchor).isActive = true }
        let resultCard = CardView(content: resultContent)

        commandField.placeholderString = "也可以输入一句指令，按回车执行…"
        commandField.font = .systemFont(ofSize: 13)
        commandField.bezelStyle = .roundedBezel
        commandField.controlSize = .large
        commandField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        commandField.setAccessibilityLabel("文字指令")
        commandField.setContentHuggingPriority(.init(1), for: .horizontal)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .large
        sendButton.contentTintColor = Theme.green
        let inputRow = hstack([commandField, sendButton])
        let footer = hstack([footerLabel, spacer(), textLabel("DEMO  ·  0.1", size: 9, weight: .medium, color: Theme.muted)])

        let layout = vstack([top, hero, voiceCard, projectRow, resultCard, inputRow, footer], spacing: 18)
        layout.setCustomSpacing(28, after: top)
        layout.setCustomSpacing(24, after: hero)
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
        for row in [top, hero, voiceCard, projectRow, resultCard, inputRow, footer] {
            row.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func separator() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func setupTextView(_ view: NSTextView, font: NSFont) {
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = font
        view.textColor = Theme.ink
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
    }

    private func scrolling(_ view: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }

    func showTranscript(_ text: String, active: Bool) {
        transcript.string = text.isEmpty ? (active ? "正在听…" : "没有识别到文字。") : text
        transcript.textColor = text.isEmpty ? Theme.muted : Theme.ink
        transcript.scrollToEndOfDocument(nil)
    }
}

@MainActor
final class RecordingOverlay {
    let panel: NSPanel
    let title = textLabel("正在听…", size: 12, weight: .semibold, color: Theme.green)
    let transcript = textLabel("", size: 15, weight: .medium)
    let level = LevelView()
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 114),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let row = hstack([title, spacer(), level, textLabel("Esc 取消", size: 10, color: Theme.muted)])
        transcript.maximumNumberOfLines = 2
        transcript.lineBreakMode = .byWordWrapping
        let content = vstack([row, transcript], spacing: 12)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        transcript.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        panel.contentView = CardView(content: content, inset: 18)
    }
    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 270, y: screen.visibleFrame.minY + 36))
        }
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}
