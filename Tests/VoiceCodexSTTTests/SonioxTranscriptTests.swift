import Foundation
import XCTest
@testable import VoiceCodex

final class SonioxTranscriptTests: XCTestCase {
    func testProvisionalTailIsReplacedAndFinalTokensAreAppendedOnce() throws {
        var transcript = SonioxTranscript()
        XCTAssertFalse(try transcript.ingest(json(#"{"tokens":[{"text":"Read ","is_final":true},{"text":"Redmi","is_final":false}]}"#)))
        XCTAssertEqual(transcript.text, "Read Redmi")
        XCTAssertEqual(transcript.confirmedText, "Read")

        _ = try transcript.ingest(json(#"{"tokens":[{"text":"README","is_final":false}]}"#))
        XCTAssertEqual(transcript.text, "Read README")
        _ = try transcript.ingest(json(#"{"tokens":[{"text":"README","is_final":true},{"text":" please","is_final":false}]}"#))
        XCTAssertEqual(transcript.confirmedText, "Read README")
        XCTAssertEqual(transcript.text, "Read README please")

        _ = try transcript.ingest(json(#"{"tokens":[{"text":" please.","is_final":true}]}"#))
        XCTAssertTrue(try transcript.ingest(json(#"{"tokens":[],"finished":true}"#)))
        XCTAssertEqual(transcript.confirmedText, "Read README please.")
    }

    func testProtocolMarkersAreRemovedWithoutChangingUserText() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(json(#"{"tokens":[{"text":"修改 <header> 标签。","is_final":true},{"text":"<end>","is_final":true},{"text":"<fin>","is_final":true}]}"#))
        XCTAssertEqual(transcript.confirmedText, "修改 <header> 标签。")
    }

    func testOnlyProvisionalTextIsNeverAConfirmedCommand() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(json(#"{"tokens":[{"text":"an incomplete command","is_final":false}]}"#))
        XCTAssertFalse(transcript.text.isEmpty)
        XCTAssertTrue(transcript.confirmedText.isEmpty)
        XCTAssertTrue(try transcript.ingest(json(#"{"tokens":[],"finished":true}"#)))
        XCTAssertTrue(transcript.confirmedText.isEmpty)
    }

    func testProviderErrorsNeverEchoResponseSecrets() {
        for code in [401, 402, 429, 503] {
            var transcript = SonioxTranscript()
            let response = #"{"tokens":[],"error_code":CODE,"error_message":"sensitive-test-marker"}"#
                .replacingOccurrences(of: "CODE", with: String(code))
            XCTAssertThrowsError(try transcript.ingest(json(response))) { error in
                XCTAssertFalse(error.localizedDescription.contains("sensitive-test-marker"))
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testMalformedPayloadFailsWithoutEchoingIt() {
        var transcript = SonioxTranscript()
        XCTAssertThrowsError(try transcript.ingest(json("sensitive-test-marker"))) { error in
            XCTAssertFalse(error.localizedDescription.contains("sensitive-test-marker"))
        }
    }

    private func json(_ value: String) -> Data { Data(value.utf8) }
}
