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
}
