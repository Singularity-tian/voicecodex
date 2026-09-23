import Foundation
import XCTest
@testable import VoiceCodex

@MainActor
final class SonioxLifecycleTests: XCTestCase {
    func testFailureCannotProduceACommandAndIsDeliveredOnce() async {
        let connection = SonioxConnection()
        var failures = 0
        var transcripts = 0
        connection.onFailure = { _ in failures += 1 }
        connection.onTranscript = { _, _ in transcripts += 1 }
        connection.fail(SpeechFailure.message("test failure"))
        connection.fail(SpeechFailure.message("duplicate failure"))
        do {
            _ = try await connection.finish()
            XCTFail("A failed connection must not produce a command")
        } catch {
            XCTAssertEqual(error.localizedDescription, "test failure")
        }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(transcripts, 0)
    }

    func testCancellationBeforeFinishThrowsCancellation() async {
        let connection = SonioxConnection()
        connection.cancel()
        do {
            _ = try await connection.finish()
            XCTFail("A cancelled connection must not produce a command")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationReleasesAPendingFinish() async {
        let connection = SonioxConnection()
        let pending = Task { try await connection.finish() }
        await Task.yield()
        connection.cancel()
        do {
            _ = try await pending.value
            XCTFail("Cancellation must fail a pending finish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testReentrantFailureCallbackKeepsTheOriginalError() async {
        let connection = SonioxConnection()
        connection.onFailure = { _ in connection.cancel() }
        connection.fail(SpeechFailure.message("original error"))
        do {
            _ = try await connection.finish()
            XCTFail("The connection failed")
        } catch {
            XCTAssertEqual(error.localizedDescription, "original error")
        }
    }

    func testEndpointIsDeliveredWhileListeningBeforeFinishIsRequested() {
        let connection = SonioxConnection()
        defer { connection.cancel() }
        var utterances: [String] = []
        var finalTranscripts: [String] = []
        connection.onUtterance = { utterances.append($0) }
        connection.onTranscript = { text, final in if final { finalTranscripts.append(text) } }
        XCTAssertFalse(connection.ingestServerMessage(json(#"{"tokens":[{"text":"打开 Chrome。","is_final":true},{"text":"<end>","is_final":true}]}"#)))
        XCTAssertEqual(utterances, ["打开 Chrome。"])
        XCTAssertFalse(connection.isFinishing)
        XCTAssertEqual(finalTranscripts, [])
    }

    func testSuccessfulFinishDeliversTailOnceAndPreservesFullTranscriptResult() async throws {
        let connection = SonioxConnection()
        var utterances: [String] = []
        var finalTranscripts: [String] = []
        connection.onUtterance = { utterances.append($0) }
        connection.onTranscript = { text, final in if final { finalTranscripts.append(text) } }
        connection.ingestServerMessage(json(#"{"tokens":[{"text":"first.","is_final":true},{"text":"<end>","is_final":true},{"text":" second", "is_final":true}]}"#))
        let pending = Task { try await connection.finish() }
        for _ in 0..<100 where !connection.isFinishing { await Task.yield() }
        guard connection.isFinishing else {
            connection.cancel()
            _ = try? await pending.value
            return XCTFail("finish() must request EOF before waiting for its result")
        }
        let final = json(#"{"tokens":[{"text":".","is_final":true},{"text":"<fin>","is_final":true}],"finished":true}"#)
        XCTAssertTrue(connection.ingestServerMessage(final))
        let result = try await pending.value
        XCTAssertEqual(result, "first. second.")
        XCTAssertEqual(utterances, ["first.", "second."])
        XCTAssertEqual(finalTranscripts, ["first. second."])
        // Repeated finish calls and late socket packets cannot replay commands.
        let repeatedResult = try await connection.finish()
        XCTAssertEqual(repeatedResult, result)
        XCTAssertTrue(connection.ingestServerMessage(final))
        XCTAssertEqual(utterances, ["first.", "second."])
        XCTAssertEqual(finalTranscripts, [result])
    }

    func testCancellationDropsPendingTailAndLateServerPackets() async {
        let connection = SonioxConnection()
        var utterances: [String] = []
        connection.onUtterance = { utterances.append($0) }
        connection.ingestServerMessage(json(#"{"tokens":[{"text":"already delivered","is_final":true},{"text":"<end>","is_final":true},{"text":" unfinished", "is_final":true}]}"#))
        connection.cancel()
        XCTAssertTrue(connection.ingestServerMessage(json(#"{"tokens":[{"text":"<end>","is_final":true}],"finished":true}"#)))
        XCTAssertEqual(utterances, ["already delivered"])
        do {
            _ = try await connection.finish()
            XCTFail("Cancelled pending text must not become a command")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testProviderFailureDoesNotEmitTheFailingPacketsTokensOrPendingTail() async {
        let connection = SonioxConnection()
        var utterances: [String] = []
        var failures = 0
        connection.onUtterance = { utterances.append($0) }
        connection.onFailure = { _ in failures += 1 }
        connection.ingestServerMessage(json(#"{"tokens":[{"text":"pending","is_final":true}]}"#))
        XCTAssertTrue(connection.ingestServerMessage(json(#"{"error_code":503,"tokens":[{"text":"<end>","is_final":true}]}"#)))
        XCTAssertTrue(connection.ingestServerMessage(json(#"{"finished":true}"#)))
        XCTAssertEqual(utterances, [])
        XCTAssertEqual(failures, 1)
        do {
            _ = try await connection.finish()
            XCTFail("Failed pending text must not become a command")
        } catch { XCTAssertTrue(error is SpeechFailure) }
    }

    func testUnexpectedEOFCannotDeliverItsEndpointOrFinalRemainder() async {
        let connection = SonioxConnection()
        var utterances: [String] = []
        var finalTranscripts: [String] = []
        connection.onUtterance = { utterances.append($0) }
        connection.onTranscript = { text, final in if final { finalTranscripts.append(text) } }
        XCTAssertTrue(connection.ingestServerMessage(json(#"{"tokens":[{"text":"open Chrome","is_final":true},{"text":"<end>","is_final":true},{"text":"and Calculator","is_final":true}],"finished":true}"#)))
        XCTAssertEqual(utterances, [])
        XCTAssertEqual(finalTranscripts, [])
        do {
            _ = try await connection.finish()
            XCTFail("Unrequested EOF must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("提前结束")) }
    }

    func testCancellingFromFirstUtteranceSuppressesLaterEndpointsInSamePacket() {
        let connection = SonioxConnection()
        var utterances: [String] = []
        connection.onUtterance = {
            utterances.append($0)
            connection.cancel()
        }
        XCTAssertTrue(connection.ingestServerMessage(json(#"{"tokens":[{"text":"first","is_final":true},{"text":"<end>","is_final":true},{"text":"second","is_final":true},{"text":"<end>","is_final":true}]}"#)))
        XCTAssertEqual(utterances, ["first"])
    }

    func testCancellingFromTranscriptCallbackSuppressesUtteranceDelivery() {
        let connection = SonioxConnection()
        var utterances: [String] = []
        connection.onTranscript = { _, _ in connection.cancel() }
        connection.onUtterance = { utterances.append($0) }
        XCTAssertTrue(connection.ingestServerMessage(json(#"{"tokens":[{"text":"cancelled","is_final":true},{"text":"<end>","is_final":true}]}"#)))
        XCTAssertEqual(utterances, [])
    }

    private func json(_ value: String) -> Data { Data(value.utf8) }
}
