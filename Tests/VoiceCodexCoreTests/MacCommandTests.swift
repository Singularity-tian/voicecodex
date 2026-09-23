import XCTest
@testable import VoiceCodexCore

final class MacCommandTests: XCTestCase {
    func testLiteralTextPreservesUnicodeWhitespaceAndShellCharacters() {
        XCTAssertEqual(MacLiteralText.request(in: "输入「  你好 $HOME `date` $(touch x)  」").candidates,
                       ["  你好 $HOME `date` $(touch x)  "])
    }

    func testQuotedTextExcludesSurroundingInstructions() {
        XCTAssertEqual(MacLiteralText.request(in: "type \"hello\" in the search field").candidates, ["hello"])
        XCTAssertTrue(MacLiteralText.request(in: "输入“你好”和「世界」").candidates.isEmpty)
        XCTAssertEqual(MacLiteralText.request(in: "输入『hello world』").candidates, ["hello world"])
    }

    func testMarkersExtractOnlyVerbatimPayload() {
        XCTAssertEqual(MacLiteralText.request(in: "输入：你好世界").candidates, ["你好世界"])
        XCTAssertEqual(MacLiteralText.request(in: "write the text hello there").candidates, ["hello there"])
        XCTAssertTrue(MacLiteralText.request(in: "search for Swift accessibility").candidates.isEmpty)
        XCTAssertTrue(MacLiteralText.request(in: "the content says hello").candidates.isEmpty)
        XCTAssertEqual(MacLiteralText.request(in: "Please enter hello world").candidates, ["hello world"])
        XCTAssertEqual(MacLiteralText.request(in: "insert the text hello 👋").candidates, ["hello 👋"])
    }

    func testQuotedMultilineTextPreservesNewlinesAndEmoji() {
        for (opening, closing) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("「", "」"), ("『", "』")] {
            let payload = "第一行 👋\n第二行 🌏"
            XCTAssertEqual(MacLiteralText.request(in: "输入\(opening)\(payload)\(closing)").candidates, [payload])
        }
    }

    func testLiteralEnvelopeKeepsCommandWordsOutOfRouting() {
        for transcript in ["输入「打开 Chrome」", "Type Open Calculator", "输入「关闭所有窗口」"] {
            let parsed = MacLiteralText.request(in: transcript)
            XCTAssertTrue(parsed.isTypingEnvelope)
            XCTAssertEqual(parsed.candidates.count, 1)
            XCTAssertFalse(parsed.routingTranscript.contains("Chrome"))
            XCTAssertFalse(parsed.routingTranscript.contains("Calculator"))
            XCTAssertFalse(parsed.routingTranscript.contains("关闭所有窗口"))
        }
    }

    func testQuotedAppAndControlNamesRemainRoutingInstructions() {
        for transcript in ["Open \"Google Chrome\"", "Click \"Done\"", "Open \"Type Helper\"", "Open Enterprise", "Open TypeScript", "Open Writer", "Press Enter", "hit Enter", "按 Enter", "Enter"] {
            let parsed = MacLiteralText.request(in: transcript)
            XCTAssertFalse(parsed.isTypingEnvelope)
            XCTAssertEqual(parsed.routingTranscript, transcript)
        }
    }

    func testNamedAppOutsidePayloadIsPreserved() {
        let parsed = MacLiteralText.request(in: "In \"TextEdit\", type \"Chrome\"")
        XCTAssertEqual(parsed.candidates, ["Chrome"])
        XCTAssertTrue(parsed.routingTranscript.contains("TextEdit"))
        XCTAssertFalse(parsed.routingTranscript.contains("Chrome"))
        XCTAssertFalse(parsed.hasSecondaryAction)
        let chinese = MacLiteralText.request(in: "在“文本编辑”里输入“复制并发送”")
        XCTAssertEqual(chinese.candidates, ["复制并发送"])
        XCTAssertTrue(chinese.routingTranscript.contains("文本编辑"))
        XCTAssertFalse(chinese.routingTranscript.contains("复制并发送"))
        XCTAssertFalse(chinese.hasSecondaryAction)
        let suffix = MacLiteralText.request(in: "type \"hello\" in \"TextEdit\"")
        XCTAssertEqual(suffix.candidates, ["hello"])
        XCTAssertTrue(suffix.routingTranscript.contains("TextEdit"))
        XCTAssertFalse(suffix.hasSecondaryAction)
        XCTAssertFalse(MacLiteralText.request(in: "在文本编辑里，输入“你好”").hasSecondaryAction)
    }

    func testSecondaryActionsOutsidePayloadAreNotMasked() {
        let quoted = MacLiteralText.request(in: "Type \"hello\" then close the window")
        XCTAssertEqual(quoted.candidates, ["hello"])
        XCTAssertTrue(quoted.routingTranscript.contains("then close the window"))
        XCTAssertTrue(quoted.hasSecondaryAction)
        let unquoted = MacLiteralText.request(in: "type hello and press Return")
        XCTAssertEqual(unquoted.candidates, ["hello"])
        XCTAssertTrue(unquoted.routingTranscript.contains("and press Return"))
        XCTAssertTrue(unquoted.hasSecondaryAction)
        let chinese = MacLiteralText.request(in: "输入hello然后按回车")
        XCTAssertEqual(chinese.candidates, ["hello"])
        XCTAssertTrue(chinese.routingTranscript.contains("然后按回车"))
        XCTAssertTrue(chinese.hasSecondaryAction)
        XCTAssertTrue(MacLiteralText.request(in: "Open Chrome then type hello").hasSecondaryAction)
    }

    func testNestedQuotedProseRetainsWholeUnquotedLiteral() {
        let parsed = MacLiteralText.request(in: "输入他说“你好”")
        XCTAssertEqual(parsed.candidates, ["他说“你好”"])
        XCTAssertFalse(parsed.routingTranscript.contains("你好"))
    }

    func testBareWriteGenerationDoesNotBecomeLiteralEnvelope() {
        for transcript in ["write a cheerful email", "write a poem about cats"] {
            let parsed = MacLiteralText.request(in: transcript)
            XCTAssertFalse(parsed.isTypingEnvelope)
            XCTAssertEqual(parsed.routingTranscript, transcript)
        }
        XCTAssertEqual(MacLiteralText.request(in: "write the text hello world").candidates, ["hello world"])
        XCTAssertTrue(MacLiteralText.request(in: "输入“hello”和“world”").candidates.isEmpty)
    }

    func testDoesNotInventTextOrTreatApostrophesAsQuotes() {
        XCTAssertTrue(MacLiteralText.request(in: "write a cheerful email").candidates.isEmpty)
        XCTAssertTrue(MacLiteralText.request(in: "打开 Chrome").candidates.isEmpty)
        XCTAssertEqual(MacLiteralText.request(in: "don't click John's button").candidates, [])
    }

    func testCommandRoundTripsWithoutChangingLiteralText() throws {
        let command = MacCommand(intent: .typeText, applicationID: "com.example.Editor",
                                 text: "第一行\n second line  ", confidence: 0.9)
        XCTAssertEqual(try JSONDecoder().decode(MacCommand.self, from: JSONEncoder().encode(command)), command)
    }
}
