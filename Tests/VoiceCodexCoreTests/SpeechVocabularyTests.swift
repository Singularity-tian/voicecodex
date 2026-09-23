import XCTest
@testable import VoiceCodexCore

final class SpeechVocabularyTests: XCTestCase {
    func testEmptyInventoryPreservesOriginalCodingTermsAndBoundedGeneralContext() throws {
        let vocabulary = SpeechVocabulary.build(applications: [], currentApplicationID: nil)
        XCTAssertEqual(vocabulary.terms, ["Codex", "GitHub", "README", "worktree", "Swift", "Persom"])
        XCTAssertEqual(vocabulary.includedApplicationCount, 0)
        XCTAssertEqual(vocabulary.omittedApplicationCount, 0)
        let general = try XCTUnwrap(vocabulary.context["general"] as? [[String: String]])
        XCTAssertEqual(general.map { $0["key"] }, ["domain", "topic"])
        XCTAssertNil(vocabulary.context["text"])
        XCTAssertNil(vocabulary.context["translation_terms"])
        try assertExactBound(vocabulary)
    }

    func testInstalledNamesAndBilingualAliasesAreIncludedWithoutUninstalledApps() throws {
        let vocabulary = SpeechVocabulary.build(applications: [
            MacApplication(id: "com.google.Chrome", name: "Google Chrome"),
            MacApplication(id: "com.apple.Notes", name: "备忘录"),
            MacApplication(id: "com.apple.Stickies", name: "Stickies"),
            MacApplication(id: "com.electron.lark", name: "Feishu"),
            MacApplication(id: "com.tencent.xinWeChat", name: "WeChat"),
            MacApplication(id: "com.example.Editor", name: "Sample Editor")
        ], currentApplicationID: nil)
        for term in ["Google Chrome", "Chrome", "谷歌浏览器", "Notes", "Apple Notes", "备忘录",
                     "Stickies", "便笺", "便签", "Feishu", "Lark", "飞书", "WeChat", "微信", "Sample Editor"] {
            XCTAssertTrue(vocabulary.terms.contains(term), "Missing installed term: \(term)")
        }
        for term in ["Safari", "Cursor", "VS Code", "Terminal", "终端", "Calculator", "计算器"] {
            XCTAssertFalse(vocabulary.terms.contains(term), "Uninstalled app leaked: \(term)")
        }
        XCTAssertFalse(vocabulary.terms.contains("com.example.Editor"))
        XCTAssertEqual(vocabulary.includedApplicationCount, 6)
        XCTAssertEqual(vocabulary.omittedApplicationCount, 0)
        try assertExactBound(vocabulary)
    }

    func testCurrentAppThenCallerPriorityOrderAndDuplicateIdentifiers() {
        let vocabulary = SpeechVocabulary.build(applications: [
            MacApplication(id: "com.example.running", name: "Running App"),
            MacApplication(id: "com.example.idle", name: "Idle App"),
            MacApplication(id: "com.example.current", name: "Current App"),
            MacApplication(id: "COM.EXAMPLE.CURRENT", name: "Duplicate App")
        ], currentApplicationID: "COM.EXAMPLE.CURRENT")
        XCTAssertEqual(Array(vocabulary.terms.dropFirst(6)), ["Current App", "Running App", "Idle App"])
        XCTAssertEqual(vocabulary.includedApplicationCount, 3)
        XCTAssertEqual(vocabulary.omittedApplicationCount, 0)
    }

    func testCaseInsensitiveAndCanonicallyEquivalentTermsDeduplicate() {
        let vocabulary = SpeechVocabulary.build(applications: [
            MacApplication(id: "com.example.one", name: "swift"),
            MacApplication(id: "com.example.two", name: "CAFÉ"),
            MacApplication(id: "com.example.three", name: "cafe\u{301}"),
            MacApplication(id: "com.google.Chrome", name: "chrome")
        ], currentApplicationID: nil)
        XCTAssertEqual(vocabulary.terms.filter { $0.lowercased() == "swift" }, ["Swift"])
        XCTAssertEqual(vocabulary.terms.filter { $0.lowercased() == "chrome" }, ["chrome"])
        XCTAssertEqual(vocabulary.terms.filter { $0.lowercased().hasPrefix("caf") }.count, 1)
        XCTAssertEqual(vocabulary.includedApplicationCount, 4)
    }

    func testControlsWhitespacePathsAndOversizedNamesAreSanitizedOrExcluded() throws {
        let vocabulary = SpeechVocabulary.build(applications: [
            MacApplication(id: "com.example.one", name: "  Useful\n\tApp\u{0000}  "),
            MacApplication(id: "com.example.two", name: "/Users/example/Private Project.app"),
            MacApplication(id: "com.example.three", name: "C:\\Private\\Secret.app"),
            MacApplication(id: "com.example.four", name: "~/Private.app"),
            MacApplication(id: "com.example.five", name: "file:Private.app"),
            MacApplication(id: "com.example.six", name: String(repeating: "长", count: 81)),
            MacApplication(id: "com.example.seven", name: "\n\u{0000}"),
            MacApplication(id: "com.example.eight", name: "A\u{202e} B"),
            MacApplication(id: "com.apple.Terminal", name: String(repeating: "x", count: 200))
        ], currentApplicationID: nil)
        XCTAssertTrue(vocabulary.terms.contains("Useful App"))
        XCTAssertTrue(vocabulary.terms.contains("A B"))
        XCTAssertTrue(vocabulary.terms.contains("Terminal"))
        XCTAssertTrue(vocabulary.terms.contains("终端"))
        XCTAssertEqual(vocabulary.includedApplicationCount, 3)
        XCTAssertEqual(vocabulary.omittedApplicationCount, 6)
        XCTAssertTrue(vocabulary.terms.allSatisfy { term in
            term.count <= 80 && !term.contains("/") && !term.contains("\\") &&
            term.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        })
        try assertExactBound(vocabulary)
    }

    func testThousandsOfUnicodeNamesRespectFullJSONBudgetAndCurrentAppPriority() throws {
        let apps = (0..<2_000).map {
            MacApplication(id: "com.example.\($0)", name: "\($0) " + String(repeating: "中文🌏\"", count: 16))
        }
        let vocabulary = SpeechVocabulary.build(applications: apps, currentApplicationID: apps.last?.id)
        XCTAssertEqual(vocabulary.terms[6], apps.last?.name)
        XCTAssertEqual(vocabulary.terms[7], apps.first?.name)
        XCTAssertGreaterThan(vocabulary.omittedApplicationCount, 0)
        XCTAssertEqual(vocabulary.includedApplicationCount + vocabulary.omittedApplicationCount, 2_000)
        XCTAssertEqual(vocabulary.terms, SpeechVocabulary.build(applications: apps, currentApplicationID: apps.last?.id).terms)
        try assertExactBound(vocabulary)
    }

    func testSmallAppsAfterOversizedCandidateCanStillFit() throws {
        let apps = (0..<80).map {
            MacApplication(id: "com.example.\($0)", name: "\($0) " + String(repeating: "中", count: 76))
        } + [MacApplication(id: "com.example.small", name: "Q")]
        let vocabulary = SpeechVocabulary.build(applications: apps, currentApplicationID: nil)
        XCTAssertTrue(vocabulary.terms.contains("Q"))
        XCTAssertGreaterThan(vocabulary.omittedApplicationCount, 0)
        try assertExactBound(vocabulary)
    }

    func testSharedKnownAliasLookupIsBundleSpecificAndCaseInsensitive() {
        XCTAssertTrue(MacApplicationAliases.aliases(forBundleIdentifier: "COM.APPLE.NOTES").contains("备忘录"))
        XCTAssertTrue(MacApplicationAliases.aliases(forBundleIdentifier: "com.apple.MobileSMS").contains("信息"))
        XCTAssertTrue(MacApplicationAliases.aliases(forBundleIdentifier: "com.microsoft.VSCode").contains("VS Code"))
        XCTAssertTrue(MacApplicationAliases.aliases(forBundleIdentifier: "com.todesktop.230313mzl4w4u92").contains("Cursor"))
        XCTAssertTrue(MacApplicationAliases.aliases(forBundleIdentifier: "com.example.Chrome").isEmpty)
    }

    private func assertExactBound(_ vocabulary: SpeechVocabulary, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONSerialization.data(withJSONObject: vocabulary.context)
        XCTAssertEqual(vocabulary.contextUTF8ByteCount, data.count, file: file, line: line)
        XCTAssertLessThanOrEqual(data.count, SpeechVocabulary.maximumContextUTF8Bytes, file: file, line: line)
        XCTAssertEqual(vocabulary.context["terms"] as? [String], vocabulary.terms, file: file, line: line)
    }
}
