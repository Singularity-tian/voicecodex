import XCTest
@testable import VoiceCodexCore

final class CodexRunnerTests: XCTestCase {
    func testSpeechCredentialIsRemovedWhileOtherEnvironmentSurvives() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executable = try fixture.script("""
        cat >/dev/null
        if [ "${SONIOX_API_KEY+x}" = x ]; then
            printf '%s\\n' 'Speech credential unexpectedly present' >&2
            exit 1
        fi
        printf '%s' "$VOICECODEX_TEST_CONTEXT" > \(fixture.quoted("context"))
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Environment checked"}}'
        """)
        var environment = ProcessInfo.processInfo.environment
        environment["SONIOX_API_KEY"] = "fake-speech-secret-for-test"
        environment["VOICECODEX_TEST_CONTEXT"] = "preserve literal $text 中文"
        let runner = CodexRunner(executableURL: executable, environment: environment)
        let result = try await runner.run(prompt: "test", directory: fixture.directory,
                                          sessionID: nil, onEvent: { _ in })
        XCTAssertEqual(result.answer, "Environment checked")
        XCTAssertEqual(try fixture.text("context"), "preserve literal $text 中文")
    }

    func testLiteralPromptArgumentsAndStreamingWithFullPipes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executable = try fixture.script("""
        printf '%s\\n' "$@" > \(fixture.quoted("arguments"))
        pwd > \(fixture.quoted("directory"))
        # Fill both output pipes before consuming a prompt larger than a pipe.
        dd if=/dev/zero bs=8192 count=32 2>/dev/null
        printf '\\n'
        (dd if=/dev/zero bs=8192 count=32 2>/dev/null) >&2
        cat > \(fixture.quoted("prompt"))
        printf '%s\\n' '{"type":"thread.started","thread_id":"session-123"}'
        printf '%s\\n' '{"type":"item.started","item":{"type":"command_execution","command":"ls -la"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"type":"command_execution","command":"ls -la","exit_code":0}}'
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Working…"}}'
        printf '%s' '{"type":"item.completed","item":{"type":"agent_message","text":"完成 ✓"}}'
        """)
        let prompt = "Literal: $(touch /should-not-exist) `echo nope` $HOME \\\" ' 中文\n"
            + String(repeating: "some text 中文\n", count: 24_000)
        let events = EventRecorder()
        let result = try await CodexRunner(executableURL: executable).run(
            prompt: prompt, directory: fixture.directory, sessionID: nil,
            onEvent: { events.append($0) }
        )
        XCTAssertEqual(try fixture.text("prompt"), prompt)
        XCTAssertEqual(try fixture.text("arguments").split(separator: "\n").map(String.init), [
            "-a", "never", "exec", "-C", fixture.directory.path,
            "--sandbox", "workspace-write", "--json", "-"
        ])
        let actualDirectory = try fixture.text("directory").trimmingCharacters(in: .newlines)
        // macOS may report /private/var for the /var temporary-directory alias.
        let actualAttributes = try FileManager.default.attributesOfItem(atPath: actualDirectory)
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        XCTAssertEqual(actualAttributes[.systemFileNumber] as? NSNumber,
                       expectedAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(result.sessionID, "session-123")
        XCTAssertEqual(result.answer, "完成 ✓")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(events.values, ["session:session-123", "activity:Running: ls -la",
                                       "activity:Finished: ls -la", "answer:Working…", "answer:完成 ✓"])
    }

    func testResumeUsesExplicitSessionAndStdin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executable = try fixture.script("""
        printf '%s\\n' "$@" > \(fixture.quoted("arguments"))
        cat > \(fixture.quoted("prompt"))
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Resumed"}}'
        """)
        let result = try await CodexRunner(executableURL: executable).run(
            prompt: "Continue", directory: fixture.directory, sessionID: "existing-session", onEvent: { _ in }
        )
        XCTAssertEqual(try fixture.text("arguments").split(separator: "\n").map(String.init), [
            "-a", "never", "exec", "-C", fixture.directory.path,
            "--sandbox", "workspace-write", "--json", "resume", "existing-session", "-"
        ])
        XCTAssertEqual(result.sessionID, "existing-session")
        XCTAssertEqual(result.answer, "Resumed")
        XCTAssertEqual(try fixture.text("prompt"), "Continue")
    }

    func testFailureIncludesBoundedUsefulDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executable = try fixture.script("""
        cat >/dev/null
        (dd if=/dev/zero bs=8192 count=2 2>/dev/null) >&2
        printf '%s\\n' 'Authentication failed: test diagnostic' >&2
        printf '%s\\n' '{"type":"turn.failed","error":{"message":"Model request failed"}}'
        exit 7
        """)
        do {
            _ = try await CodexRunner(executableURL: executable).run(
                prompt: "test", directory: fixture.directory, sessionID: nil, onEvent: { _ in }
            )
            XCTFail("Expected a nonzero exit to throw")
        } catch let CodexRunnerError.failed(code, message) {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(message.contains("Authentication failed: test diagnostic"))
            XCTAssertLessThanOrEqual(message.count, 6_000)
        }
    }

    func testFailedTurnThrowsEvenWhenCLIExitsZero() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executable = try fixture.script("""
        cat >/dev/null
        printf '%s\\n' '{"type":"turn.failed","error":{"message":"Quota exceeded"}}'
        """)
        do {
            _ = try await CodexRunner(executableURL: executable).run(
                prompt: "test", directory: fixture.directory, sessionID: nil, onEvent: { _ in }
            )
            XCTFail("Expected a failed turn to throw")
        } catch let CodexRunnerError.failed(code, message) {
            XCTAssertEqual(code, 0)
            XCTAssertTrue(message.contains("Quota exceeded"))
        }
    }

    func testCancelStopsAnExecutingProcessAndReleasesRunner() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executable = try fixture.script("""
        cat >/dev/null
        printf '%s\\n' '{"type":"thread.started","thread_id":"running"}'
        exec /bin/sleep 30
        """)
        let runner = CodexRunner(executableURL: executable)
        let events = EventRecorder()
        let started = expectation(description: "The child reports its running session")
        let task = Task {
            try await runner.run(prompt: "wait", directory: fixture.directory,
                                 sessionID: nil, onEvent: { event in
                events.append(event)
                if case .sessionID("running") = event { started.fulfill() }
            })
        }
        // Startup latency is independent of the cancellation deadline below.
        await fulfillment(of: [started], timeout: 10)
        XCTAssertEqual(events.values.first, "session:running")
        let start = Date()
        runner.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)

        _ = try fixture.script("cat >/dev/null")
        let next = try await runner.run(prompt: "next", directory: fixture.directory,
                                        sessionID: nil, onEvent: { _ in })
        XCTAssertEqual(next.exitCode, 0)
    }

    func testTaskCancellationAlsoStopsProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let executable = try fixture.script("""
        printf '%s\\n' '{"type":"thread.started","thread_id":"running"}'
        exec /bin/sleep 30
        """)
        let runner = CodexRunner(executableURL: executable)
        let events = EventRecorder()
        let started = expectation(description: "The child reports its running session")
        let task = Task {
            try await runner.run(prompt: "wait", directory: fixture.directory,
                                 sessionID: nil, onEvent: { event in
                events.append(event)
                if case .sessionID("running") = event { started.fulfill() }
            })
        }
        // Startup latency is independent of the cancellation deadline below.
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch is CancellationError {}
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ event: CodexEvent) {
        let value: String
        switch event {
        case let .sessionID(id): value = "session:" + id
        case let .activity(text): value = "activity:" + text
        case let .answer(text): value = "answer:" + text
        }
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}

private struct Fixture {
    let directory: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCodex tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        directory = temporary.resolvingSymlinksInPath()
    }

    func script(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("fake codex")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func quoted(_ name: String) -> String {
        "'" + directory.appendingPathComponent(name).path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
