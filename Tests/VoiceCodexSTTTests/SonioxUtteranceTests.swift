import Foundation
import XCTest
@testable import VoiceCodex

final class SonioxUtteranceTests: XCTestCase {
    func testMultipleEndpointsDeliverInOrderAndKeepTheFullTranscript() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(message([
            ("打开 Chrome。", true), ("<end>", true),
            (" 然后打开计算器！", true), ("<end>", true),
        ]))
        XCTAssertEqual(transcript.takeUtterances(), ["打开 Chrome。", "然后打开计算器！"])
        XCTAssertEqual(transcript.confirmedText, "打开 Chrome。 然后打开计算器！")
        XCTAssertEqual(transcript.text, transcript.confirmedText)
        XCTAssertEqual(transcript.takeUtterances(), [])
    }

    func testRevisedProvisionalTextWaitsForDelayedFinalTokensAndEndpoint() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(message([("打开 ", true), ("Cro", false)]))
        XCTAssertEqual(transcript.takeUtterances(), [])
        _ = try transcript.ingest(message([("Chrome", false)]))
        XCTAssertEqual(transcript.text, "打开 Chrome")
        XCTAssertEqual(transcript.takeUtterances(), [])
        _ = try transcript.ingest(message([("Chrome", true), ("，好吗", false)]))
        XCTAssertEqual(transcript.takeUtterances(), [])
        _ = try transcript.ingest(message([("。", true)]))
        XCTAssertEqual(transcript.takeUtterances(), [])
        _ = try transcript.ingest(message([("<end>", true)]))
        XCTAssertEqual(transcript.takeUtterances(), ["打开 Chrome。"])
        XCTAssertEqual(transcript.confirmedText, "打开 Chrome。")
    }

    func testOnlyConfirmedEndpointIsABoundary() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(message([
            ("type hello", true), ("<end>", false), ("<fin>", true),
        ]))
        XCTAssertEqual(transcript.takeUtterances(), [])
        _ = try transcript.ingest(message([(" world.", true), ("<end>", true)]))
        XCTAssertEqual(transcript.takeUtterances(), ["type hello world."])
    }

    func testSuccessfulEOFFlushesOnlyConfirmedTailExactlyOnce() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(message([("first.", true), ("<end>", true)]))
        XCTAssertEqual(transcript.takeUtterances(), ["first."])
        _ = try transcript.ingest(message([(" second", true), (" maybe", false)]))
        XCTAssertEqual(transcript.takeUtterances(), [])
        XCTAssertTrue(try transcript.ingest(message([], finished: true)))
        // A provider flag alone does not authorize the final remainder.
        XCTAssertEqual(transcript.takeUtterances(), [])
        XCTAssertEqual(transcript.takeUtterances(successfulEOF: true), ["second"])
        XCTAssertEqual(transcript.takeUtterances(successfulEOF: true), [])
        XCTAssertEqual(transcript.confirmedText, "first. second")
    }

    func testEndpointInFinalPacketIsNotRepeatedAsEOFRemainder() throws {
        var transcript = SonioxTranscript()
        XCTAssertTrue(try transcript.ingest(message([
            ("hello.", true), ("<end>", true), ("<fin>", true),
        ], finished: true)))
        XCTAssertEqual(transcript.takeUtterances(successfulEOF: true), ["hello."])
        XCTAssertEqual(transcript.takeUtterances(successfulEOF: true), [])
    }

    func testDuplicateEmptyBoundariesDoNotSuppressRepeatedSpokenCommands() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(message([
            ("<end>", true), (" \n ", true), ("<end>", true),
            ("copy", true), ("<end>", true), ("<end>", true),
            (" copy", true), ("<end>", true),
        ]))
        XCTAssertEqual(transcript.takeUtterances(), ["copy", "copy"])
    }

    func testLiteralPunctuationAndInteriorWhitespaceArePreserved() {
        var accumulator = SonioxUtteranceAccumulator()
        XCTAssertNil(accumulator.appendFinalToken("  输入“第一行\n  第二行🙂 <header>”。\n"))
        XCTAssertEqual(accumulator.appendFinalToken("<end>"), "输入“第一行\n  第二行🙂 <header>”。")
        XCTAssertNil(accumulator.finish())
    }

    func testDiscardDropsQueuedEndpointsAndTailAndIgnoresLateBoundaries() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(message([
            ("queued", true), ("<end>", true), (" incomplete", true),
        ]))
        transcript.discardUtterances()
        _ = try transcript.ingest(message([(" late", true), ("<end>", true)]))
        XCTAssertEqual(transcript.takeUtterances(successfulEOF: true), [])
    }

    func testProvisionalOnlyEOFNeverProducesAnUtterance() throws {
        var transcript = SonioxTranscript()
        _ = try transcript.ingest(message([("delete everything", false)]))
        XCTAssertTrue(try transcript.ingest(message([], finished: true)))
        XCTAssertEqual(transcript.takeUtterances(successfulEOF: true), [])
    }

    private func message(_ tokens: [(String, Bool)], finished: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tokens": tokens.map { ["text": $0.0, "is_final": $0.1] as [String: Any] },
            "finished": finished,
        ])
    }
}
