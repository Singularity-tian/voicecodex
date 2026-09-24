// A disposable native target for manual end-to-end QA. No files or network.
// Build with script/build_qa_target.sh, then launch the generated .app.
import AppKit

/// Deliberately models custom-drawn launchers: the icon is clickable, its
/// caption is not, and no AXPress control is exposed. OCR must locate the
/// caption and associate the actual tile rather than claim the text was clicked.
final class QATile: NSView {
    var onActivate: (() -> Void)?
    private var tile: NSRect { NSRect(x: (bounds.width - 92) / 2, y: 38, width: 92, height: 92) }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 140) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: tile, xRadius: 18, yRadius: 18).fill()
        let mark: NSString = "+"
        mark.draw(at: NSPoint(x: tile.midX - 17, y: tile.midY - 25), withAttributes: [
            .font: NSFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: NSColor.white
        ])
        let label: NSString = "Tile action"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 19), .foregroundColor: NSColor.labelColor
        ]
        label.draw(at: NSPoint(x: (bounds.width - label.size(withAttributes: attributes).width) / 2, y: 8),
                   withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        if tile.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }
}

@MainActor
final class QATarget: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var nextWindow = 1
    private var counters: [ObjectIdentifier: Int] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit QA Target", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let new = fileMenu.addItem(withTitle: "New Test Window", action: #selector(newWindow), keyEquivalent: "n")
        new.target = self
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu
        menu.addItem(file)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        newWindow()
    }

    @objc func newWindow() {
        let number = nextWindow
        nextWindow += 1
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VoiceCodex QA — Window \(number)"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Disposable test window \(number)")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let count = NSTextField(labelWithString: "Counter: 0")
        count.setAccessibilityIdentifier("qa-counter")
        let increment = NSButton(title: "Increment counter", target: self, action: #selector(incrementCounter(_:)))
        increment.identifier = NSUserInterfaceItemIdentifier("qa-increment")
        let reset = NSButton(title: "Reset counter", target: self, action: #selector(resetCounter(_:)))
        let row = NSStackView(views: [count, increment, reset])
        row.orientation = .horizontal
        row.spacing = 16
        let noEffect = NSButton(title: "No effect", target: self, action: #selector(noEffect(_:)))
        let delayed = NSButton(title: "Delayed increment", target: self, action: #selector(delayedIncrement(_:)))
        let checks = NSStackView(views: [noEffect, delayed])
        checks.spacing = 16
        let tile = QATile()
        tile.setAccessibilityElement(false)
        tile.onActivate = { [weak self, weak window] in
            guard let self, let window else { return }
            self.counters[ObjectIdentifier(window), default: 0] += 1
            self.updateCounter(in: window)
        }
        let field = NSTextField(string: "")
        field.placeholderString = "Single-line input for literal typing"
        field.setAccessibilityLabel("QA single line input")
        field.setAccessibilityIdentifier("qa-single-line")
        let editor = NSTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 17)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.setAccessibilityLabel("QA multiline editor")
        editor.setAccessibilityIdentifier("qa-editor")
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor
        let help = NSTextField(labelWithString: "Only disposable QA content. Closing these windows cannot delete user documents.")
        help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, row, checks, tile, field, scroll, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tile.widthAnchor.constraint(equalToConstant: 150),
            tile.heightAnchor.constraint(equalToConstant: 140),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
        count.tag = 101
        counters[ObjectIdentifier(window)] = 0
        windows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func incrementCounter(_ sender: NSButton) {
        guard let window = sender.window else { return }
        let key = ObjectIdentifier(window)
        counters[key, default: 0] += 1
        updateCounter(in: window)
    }

    @objc private func resetCounter(_ sender: NSButton) {
        guard let window = sender.window else { return }
        counters[ObjectIdentifier(window)] = 0
        updateCounter(in: window)
    }

    @objc private func noEffect(_ sender: NSButton) {}

    @objc private func delayedIncrement(_ sender: NSButton) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak sender] in
            guard let sender else { return }
            self?.incrementCounter(sender)
        }
    }

    private func updateCounter(in window: NSWindow) {
        func label(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.tag == 101 { return field }
            return view.subviews.compactMap(label).first
        }
        label(window.contentView!)?.stringValue = "Counter: \(counters[ObjectIdentifier(window), default: 0])"
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = QATarget()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { application.run() }
}
