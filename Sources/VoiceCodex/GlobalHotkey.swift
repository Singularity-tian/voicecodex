import AppKit
import Carbon

@MainActor
final class GlobalHotkey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var held = false
    private(set) var label = "⌃ ⌥ Space"

    func register() throws {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            let kind = GetEventKind(event)
            let object = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            Task { @MainActor in object.handle(id: id, kind: kind) }
            return noErr
        }, types.count, &types, pointer, &handler)
        guard status == noErr else { throw HotkeyError.unavailable }
        let id = EventHotKeyID(signature: OSType(0x56434458), id: 1)
        var result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                        GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr {
            label = "⌃ ⇧ Space"
            result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | shiftKey), id,
                                        GetApplicationEventTarget(), 0, &hotkey)
        }
        guard result == noErr else { throw HotkeyError.unavailable }
    }

    private func handle(id: UInt32, kind: UInt32) {
        if id == 2, kind == UInt32(kEventHotKeyPressed) { onEscape?(); return }
        if kind == UInt32(kEventHotKeyPressed), !held { held = true; onPress?() }
        if kind == UInt32(kEventHotKeyReleased), held { held = false; onRelease?() }
    }

    func captureEscape(_ active: Bool) {
        if active, escapeKey == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x56434458), id: 2),
                                GetApplicationEventTarget(), 0, &escapeKey)
        } else if !active, let escapeKey {
            UnregisterEventHotKey(escapeKey)
            self.escapeKey = nil
        }
    }

    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    enum HotkeyError: LocalizedError {
        case unavailable
        var errorDescription: String? { "全局快捷键注册失败。可以先使用窗口中的按住说话按钮。" }
    }
}
