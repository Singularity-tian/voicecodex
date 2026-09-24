import XCTest
@testable import VoiceCodexCore

final class MacCommandSequenceTests: XCTestCase {
    func testRequestedTencentMeetingSequenceRetainsNaturalStepWording() throws {
        XCTAssertEqual(try MacCommandSequence.parse("你可以打开腾讯会议，然后创建一个新的会议吗？"),
                       ["你可以打开腾讯会议", "创建一个新的会议吗？"])
    }

    func testEnglishAndChineseConnectorsDoNotDuplicatePrefixesOrAppNames() throws {
        XCTAssertEqual(try MacCommandSequence.parse("Please open Tencent Meeting, and then create a new meeting."),
                       ["Please open Tencent Meeting", "create a new meeting."])
        XCTAssertEqual(try MacCommandSequence.parse("打开 Chrome，然后再新建标签页，接着输入「你好」，再按回车"),
                       ["打开 Chrome", "新建标签页", "输入「你好」", "按回车"])
        XCTAssertEqual(try MacCommandSequence.parse("Open TextEdit THEN type hello and THEN press Return"),
                       ["Open TextEdit", "type hello", "press Return"])
    }

    func testBareAndAndWordsContainingThenOrZaiAreNotConnectors() throws {
        for transcript in ["Type rock and roll", "输入再见", "再次打开计算器", "Open Athena", "Open Another App"] {
            XCTAssertEqual(try MacCommandSequence.parse(transcript), [transcript])
        }
    }

    func testEverySupportedQuotePairProtectsLiteralSequenceWords() throws {
        for (open, close) in [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』")] {
            let literal = "输入\(open)先复制，然后粘贴 and then 再打开 🌏\n第二行\(close)"
            XCTAssertEqual(try MacCommandSequence.parse(literal + "，然后按回车"), [literal, "按回车"])
        }
    }

    func testNestedQuotesAndAdjacentChineseConnectorArePreserved() throws {
        XCTAssertEqual(try MacCommandSequence.parse("输入“他说「然后再见」”然后按回车"),
                       ["输入“他说「然后再见」”", "按回车"])
        XCTAssertEqual(try MacCommandSequence.parse("输入‘hello’然后按回车"), ["输入‘hello’", "按回车"])
    }

    func testApostrophesInOrdinaryWordsDoNotOpenQuotes() throws {
        XCTAssertEqual(try MacCommandSequence.parse("Don't close John's window then click Done"),
                       ["Don't close John's window", "click Done"])
        XCTAssertEqual(try MacCommandSequence.parse("Click users' settings then copy"), ["Click users' settings", "copy"])
        XCTAssertEqual(try MacCommandSequence.parse("输入“don't type then”然后复制"), ["输入“don't type then”", "复制"])
        XCTAssertEqual(try MacCommandSequence.parse("Type \"users' settings then proceed\" then copy"),
                       ["Type \"users' settings then proceed\"", "copy"])
        XCTAssertEqual(try MacCommandSequence.parse("Don't write l’élève then copy"), ["Don't write l’élève", "copy"])
    }

    func testEscapedQuotesStayWithinOneLiteralSpan() throws {
        let first = #"Type "say \"then\" now""#
        XCTAssertEqual(try MacCommandSequence.parse(first + " then copy"), [first, "copy"])
    }

    func testQuotedWordsCannotBeConsumedByAndThenWhitespaceMatch() throws {
        XCTAssertEqual(try MacCommandSequence.parse("Type \"hello\" and \"world\" then copy"),
                       ["Type \"hello\" and \"world\"", "copy"])
    }

    func testSixStepsAllowedAndSevenRejectedWithoutPartialResult() throws {
        let six = Array(repeating: "复制", count: 6)
        XCTAssertEqual(try MacCommandSequence.parse(six.joined(separator: "然后")), six)
        assertError(.tooManySteps, Array(repeating: "复制", count: 7).joined(separator: "然后"))
    }

    func testEmptyAndMalformedSequencesAreRejected() {
        for input in ["", " \n\t "] { assertError(.emptyCommand, input) }
        for input in ["then", "然后", "然后然后复制", "打开 Chrome 然后", "打开 Chrome 然后，接着复制", "Open Chrome then then copy", "，；"] {
            assertError(.malformedSequence, input)
        }
    }

    func testOneLeadingConnectorCanContinueAnEarlierStreamingUtterance() throws {
        XCTAssertEqual(try MacCommandSequence.parse("然后创建一个新的会议。"), ["创建一个新的会议。"])
        XCTAssertEqual(try MacCommandSequence.parse("And then click Done"), ["click Done"])
        XCTAssertEqual(try MacCommandSequence.parse("接着再输入「然后再见」"), ["输入「然后再见」"])
        let six = Array(repeating: "复制", count: 6)
        XCTAssertEqual(try MacCommandSequence.parse("然后" + six.joined(separator: "然后")), six)
    }

    func testAnyUnbalancedQuoteRejectsTheEntireSequence() {
        for input in ["打开 Chrome 然后输入“你好", "输入「你好』然后复制", "Open Chrome then type \"hello", "复制然后输入你好」"] {
            assertError(.unbalancedQuotes, input)
        }
    }

    func testCharacterAndByteLimitsAreCheckedBeforeParsing() throws {
        let limit = String(repeating: "a", count: MacCommandSequence.maximumTranscriptLength)
        XCTAssertEqual(try MacCommandSequence.parse(limit), [limit])
        assertError(.tooLong, limit + "a")
        assertError(.tooLong, "a" + String(repeating: "\u{301}", count: 20_000))
    }

    func testLiteralWhitespaceAndShellCharactersAreUnchanged() throws {
        let first = "输入「  $HOME `date` $(touch x)\n then 然后  」"
        XCTAssertEqual(try MacCommandSequence.parse("  " + first + "，然后 复制  "), [first, "复制"])
    }

    private func assertError(_ expected: MacCommandSequenceError, _ transcript: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MacCommandSequence.parse(transcript), file: file, line: line) {
            XCTAssertEqual($0 as? MacCommandSequenceError, expected, file: file, line: line)
        }
    }
}
