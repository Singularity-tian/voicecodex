import ApplicationServices
import XCTest
@testable import VoiceCodex

final class MacControlDriverTests: XCTestCase {
    func testEmptyDisplayNameFallsBackWithoutInvalidatingOtherApplications() {
        let app = MacControlDriver.applicationMetadata(id: "com.example.Notes", names: ["", " \n ", "Notes"])
        XCTAssertEqual(app?.id, "com.example.Notes")
        XCTAssertEqual(app?.name, "Notes")
    }

    func testOverlongLabelsAndMissingMetadataUseBoundedFallback() {
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: "com.example.Notes", names: [String(repeating: "a", count: 201), "Notes"])?.name, "Notes")
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: "com.example.Notes", names: [nil, " "])?.name, "com.example.Notes")
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: String(repeating: "a", count: 256), names: [])?.name.count, 200)
    }

    func testMalformedApplicationIDsAreExcludedWithoutRewritingIdentity() {
        for id in ["", " com.example.Notes", "com.example.Notes\n", "com.example/Notes", String(repeating: "a", count: 257)] {
            XCTAssertNil(MacControlDriver.applicationMetadata(id: id, names: ["Notes"]))
        }
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: "com.example.App_2-beta", names: ["Notes"])?.id, "com.example.App_2-beta")
    }

    func testInsertionPreservesDocumentAndLiteralCommandCharacters() {
        let literal = "$(touch /tmp/example); `whoami`\nhello"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: "before AFTER", range: CFRange(location: 7, length: 5), with: literal),
                       "before " + literal)
    }

    func testUnicodeSelectionUsesUTF16OffsetsWithoutSplittingEmoji() {
        XCTAssertEqual(MacControlDriver.replacingSelection(in: "A👩🏽‍💻B", range: CFRange(location: 1, length: 7), with: "你好"), "A你好B")
        XCTAssertNil(MacControlDriver.replacingSelection(in: "A😀B", range: CFRange(location: 2, length: 1), with: "x"))
    }

    func testMultilineChineseAndEmojiInsertAtCursorWithoutChangingSurroundingDocument() {
        let before = "已有内容 🧑🏽‍🚀\n"
        let after = "\n保留后面的内容"
        let text = "第一行：你好，世界 👋\n第二行：🚀 ready\n"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: before + after,
            range: CFRange(location: before.utf16.count, length: 0), with: text), before + text + after)
    }

    func testEmptyDocumentAndEndOfDocumentAcceptLiteralMultilineText() {
        let text = "你好\n👩🏽‍💻\n"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: "", range: CFRange(location: 0, length: 0), with: text), text)
        let existing = "文档😀"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: existing,
            range: CFRange(location: existing.utf16.count, length: 0), with: text), existing + text)
    }

    func testInsertionPreservesUnicodeScalarSpellingInsteadOfNormalizingIt() {
        let text = "e\u{301}\r\n\t café 😀"
        let result = MacControlDriver.replacingSelection(in: "prefixsuffix", range: CFRange(location: 6, length: 0), with: text)
        XCTAssertEqual(result.map { Array($0.utf16) }, Array(("prefix" + text + "suffix").utf16))
    }

    func testSelectionEndingInsideASurrogatePairIsRejected() {
        XCTAssertNil(MacControlDriver.replacingSelection(in: "A😀B", range: CFRange(location: 0, length: 2), with: "x"))
        XCTAssertNil(MacControlDriver.replacingSelection(in: "😀", range: CFRange(location: 1, length: 0), with: "x"))
        XCTAssertNil(MacControlDriver.replacingSelection(in: "abc", range: CFRange(location: Int.max, length: 0), with: "x"))
    }

    func testLocalizedApplicationNamesAreRetainedAndControlCharactersRemoved() {
        let application = MacControlDriver.applicationMetadata(id: "com.example.Notes", names: ["  便笺\nNotes\t "])
        XCTAssertEqual(application?.name, "便笺 Notes")
    }

    func testOutOfBoundsSelectionCannotReplaceWholeField() {
        for range in [CFRange(location: -1, length: 0), CFRange(location: 0, length: -1),
                      CFRange(location: 4, length: 0), CFRange(location: 1, length: Int.max)] {
            XCTAssertNil(MacControlDriver.replacingSelection(in: "abc", range: range, with: "replacement"))
        }
    }

    func testCommonTerminalAppsAreBlockedFromInput() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                   "com.cmuxterm.app", "org.alacritty", "net.kovidgoyal.kitty"] {
            XCTAssertTrue(MacControlDriver.isTerminalApplication(id))
        }
        XCTAssertFalse(MacControlDriver.isTerminalApplication("com.apple.Stickies"))
        XCTAssertFalse(MacControlDriver.isTerminalApplication("com.google.Chrome"))
    }

    func testDocumentMetadataCannotTurnAnOrdinaryEditorIntoATerminal() {
        XCTAssertFalse(MacControlDriver.isTerminalElement(role: kAXWindowRole,
            identifier: "Terminal notes.txt", roleDescription: "终端使用说明"))
        XCTAssertFalse(MacControlDriver.isTerminalElement(role: kAXApplicationRole,
            identifier: "com.example.terminal-tutorial", roleDescription: "Terminal documentation"))
        XCTAssertFalse(MacControlDriver.isTerminalElement(role: kAXTextAreaRole,
            identifier: "document-editor", roleDescription: "text area"))
    }

    func testEmbeddedTerminalWidgetMetadataIsStillRejected() {
        XCTAssertTrue(MacControlDriver.isTerminalElement(role: kAXTextAreaRole,
            identifier: "terminal-input", roleDescription: "text area"))
        XCTAssertTrue(MacControlDriver.isTerminalElement(role: kAXTextAreaRole,
            identifier: "xterm-helper-textarea", roleDescription: "text area"))
        XCTAssertTrue(MacControlDriver.isTerminalElement(role: "AXTerminal",
            identifier: nil, roleDescription: "终端"))
    }

    @MainActor
    func testStopQueuedDuringSynchronousInspectionPreventsThePendingWrite() async throws {
        var stopDelivered = false
        var writes = 0
        var operation: Task<Void, Error>?
        operation = Task { @MainActor in
            // Models an Escape callback queued on the same actor while an AX
            // read blocks. This fixture performs no accessibility or UI action.
            Task { @MainActor in
                stopDelivered = true
                operation?.cancel()
            }
            Self.delayedReadFixture()
            XCTAssertFalse(stopDelivered)
            try await MacControlDriver.withNativeActionCheckpoint { writes += 1 }
        }
        do {
            try await operation?.value
            XCTFail("The queued stop should cancel the native-action checkpoint")
        } catch is CancellationError {
            XCTAssertTrue(stopDelivered)
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testNativeActionCheckpointDeliversAnUncancelledActionExactlyOnce() async throws {
        var writes = 0
        let result = try await MacControlDriver.withNativeActionCheckpoint {
            writes += 1
            return "delivered"
        }
        XCTAssertEqual(result, "delivered")
        XCTAssertEqual(writes, 1)
    }

    private static func delayedReadFixture() {
        Thread.sleep(forTimeInterval: 0.02)
    }
}
