import Foundation
import XCTest
import VoiceCodexCore
@testable import VoiceCodex

@MainActor
final class SonioxConfigurationTests: XCTestCase {
    func testSessionKeepsBilingualTranscriptionAndRawPCMContract() throws {
        let config = SonioxConnection.configuration(apiKey: "fixture-key")
        let encoded = try JSONSerialization.data(withJSONObject: config)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(decoded["language_hints"] as? [String], ["zh", "en"])
        XCTAssertNil(decoded["language_hints_strict"])
        XCTAssertNil(decoded["translation"])
        XCTAssertEqual(decoded["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(decoded["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(decoded["num_channels"] as? Int, 1)
        let context = try XCTUnwrap(decoded["context"] as? [String: Any])
        XCTAssertEqual(context["terms"] as? [String], SpeechVocabulary.defaultTerms)
    }

    func testAppVocabularyReachesEncodedSonioxSessionWithoutLosingChinese() throws {
        let vocabulary = SpeechVocabulary.build(applications: [
            MacApplication(id: "com.google.Chrome", name: "Google Chrome"),
            MacApplication(id: "com.example.Editor", name: "中文编辑器")
        ], currentApplicationID: "com.example.Editor")
        let config = SonioxConnection.configuration(apiKey: "fixture-key", context: vocabulary.context)
        let encoded = try JSONSerialization.data(withJSONObject: config)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let context = try XCTUnwrap(decoded["context"] as? [String: Any])
        let terms = try XCTUnwrap(context["terms"] as? [String])
        XCTAssertEqual(terms, vocabulary.terms)
        XCTAssertTrue(terms.contains("中文编辑器"))
        XCTAssertTrue(terms.contains("Google Chrome"))
        XCTAssertNotNil(context["general"])
        XCTAssertNil(context["translation_terms"])
        XCTAssertNil(context["text"])
    }
}
