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
}
