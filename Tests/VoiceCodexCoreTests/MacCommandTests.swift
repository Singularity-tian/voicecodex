import XCTest
@testable import VoiceCodexCore

final class MacCommandTests: XCTestCase {
    func testLiteralTextPreservesUnicodeWhitespaceAndShellCharacters() {
        XCTAssertEqual(MacLiteralText.candidates(in: "输入「  你好 $HOME `date` $(touch x)  」"),
                       ["  你好 $HOME `date` $(touch x)  "])
    }

    func testQuotedTextExcludesSurroundingInstructions() {
        XCTAssertEqual(MacLiteralText.candidates(in: "type \"hello\" in the search field"), ["hello"])
        XCTAssertEqual(MacLiteralText.candidates(in: "输入“你好”和「世界」"), ["你好", "世界"])
        XCTAssertEqual(MacLiteralText.candidates(in: "输入『hello world』"), ["hello world"])
    }

    func testMarkersExtractOnlyVerbatimPayload() {
        XCTAssertEqual(MacLiteralText.candidates(in: "输入：你好世界"), ["你好世界"])
        XCTAssertEqual(MacLiteralText.candidates(in: "write the text hello there"), ["hello there"])
        XCTAssertEqual(MacLiteralText.candidates(in: "search for Swift accessibility"), ["Swift accessibility"])
        XCTAssertEqual(MacLiteralText.candidates(in: "the content says hello"), ["hello"])
    }

    func testDoesNotInventTextOrTreatApostrophesAsQuotes() {
        XCTAssertEqual(MacLiteralText.candidates(in: "write a cheerful email"), ["a cheerful email"])
        // Candidate extraction is literal; Jev must still reject content generation.
        XCTAssertTrue(MacLiteralText.candidates(in: "打开 Chrome").isEmpty)
        XCTAssertEqual(MacLiteralText.candidates(in: "don't click John's button"), [])
    }

    func testCommandRoundTripsWithoutChangingLiteralText() throws {
        let command = MacCommand(intent: .typeText, applicationID: "com.example.Editor",
                                 text: "第一行\n second line  ", confidence: 0.9)
        XCTAssertEqual(try JSONDecoder().decode(MacCommand.self, from: JSONEncoder().encode(command)), command)
    }
}
