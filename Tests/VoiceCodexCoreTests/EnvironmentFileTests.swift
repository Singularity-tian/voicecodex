import XCTest
@testable import VoiceCodexCore

final class EnvironmentFileTests: XCTestCase {
    func testParsesCommentsExportsQuotesAndCRLFWithoutInterpolation() throws {
        let contents = """
        # local credentials
        export TYPESAFE_API_KEY = 'literal-$HOME-$(command)-`command`' # comment
        SONIOX_API_KEY="key#with=punctuation"
        URL=https://example.invalid/#fragment # separate comment
        EMPTY=
        BLANK= # comment
        """.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try EnvironmentFile.parse(contents), [
            "TYPESAFE_API_KEY": "literal-$HOME-$(command)-`command`",
            "SONIOX_API_KEY": "key#with=punctuation",
            "URL": "https://example.invalid/#fragment", "EMPTY": "", "BLANK": ""
        ])
    }

    func testEscapesAndMultilineValuesPreserveLiteralData() throws {
        let contents = #"DOUBLE="line\nnext\t\"quoted\"\\path\unknown""# + "\n"
            + #"SINGLE='literal\n${VARIABLE}'"# + "\n"
            + "MULTILINE=\"first  \n  second\" # comment\nAFTER=present\n"
        let values = try EnvironmentFile.parse(contents)
        XCTAssertEqual(values["DOUBLE"], "line\nnext\t\"quoted\"\\path\\unknown")
        XCTAssertEqual(values["SINGLE"], #"literal\n${VARIABLE}"#)
        XCTAssertEqual(values["MULTILINE"], "first  \n  second")
        XCTAssertEqual(values["AFTER"], "present")
    }

    func testAcceptsBOMAndLastAssignmentWins() throws {
        XCTAssertEqual(try EnvironmentFile.parse("\u{feff}  KEY=old\nKEY=new\n"), ["KEY": "new"])
    }

    func testMalformedLinesReportLineNumbersWithoutContents() {
        for badLine in ["private-secret", "1KEY=private-secret", "BAD KEY=private-secret",
                        "KEY='private-secret", "KEY=\"private-secret\" unexpected"] {
            XCTAssertThrowsError(try EnvironmentFile.parse("# heading\n\n" + badLine)) { error in
                XCTAssertEqual((error as? EnvironmentFile.ParseError)?.line, 3)
                XCTAssertTrue(error.localizedDescription.contains("line 3"))
                XCTAssertFalse(error.localizedDescription.contains("private-secret"))
                XCTAssertFalse(error.localizedDescription.contains("unexpected"))
            }
        }
    }
}
