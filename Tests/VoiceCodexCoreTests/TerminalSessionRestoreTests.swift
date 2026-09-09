import XCTest
@testable import VoiceCodexCore

@MainActor
final class TerminalSessionRestoreTests: XCTestCase {
    private let sessionID = "12345678-1234-4234-8234-123456789abc"
    private let workspace = URL(fileURLWithPath: "/tmp/voicecodex-restore-test")

    func testFreshSessionNeedsNoHistoryLookup() async throws {
        let bridge = makeBridge { _, _ in
            XCTFail("A new task must not issue a restoration request")
            return [:]
        }
        let result = try await bridge.restorableSessionID(nil, workspace: workspace)
        XCTAssertNil(result)
    }

    func testUnpersistedSessionStartsFreshInTheSameWorkspace() async throws {
        let expectedID = sessionID
        let bridge = makeBridge { method, parameters in
            XCTAssertEqual(method, "thread/read")
            XCTAssertEqual(parameters["threadId"] as? String, expectedID)
            throw TerminalSessionError.rpc(code: -32600, message: "thread not loaded: \(expectedID)")
        }
        let result = try await bridge.restorableSessionID(sessionID, workspace: workspace)
        XCTAssertNil(result)
    }

    func testExistingDurableSessionIsPreservedWithoutResumingIt() async throws {
        var methods: [String] = []
        let cwd = workspace.path
        let bridge = makeBridge { method, parameters in
            methods.append(method)
            if method == "thread/read" { return ["thread": ["cwd": cwd, "status": ["type": "notLoaded"]]] }
            XCTAssertEqual(parameters["limit"] as? Int, 1)
            return ["data": [["id": "completed-turn", "status": "completed"]]]
        }
        let result = try await bridge.restorableSessionID(sessionID, workspace: workspace)
        XCTAssertEqual(result, sessionID)
        XCTAssertEqual(methods, ["thread/read", "thread/turns/list"])
    }

    func testUppercaseUUIDUsesTheServersCanonicalMissingResponse() async throws {
        let canonicalID = sessionID
        let bridge = makeBridge { _, parameters in
            XCTAssertEqual(parameters["threadId"] as? String, canonicalID)
            throw TerminalSessionError.rpc(code: -32600, message: "thread not loaded: \(canonicalID)")
        }
        let result = try await bridge.restorableSessionID(sessionID.uppercased(), workspace: workspace)
        XCTAssertNil(result)
    }

    func testHistoryDisappearingAfterMetadataAllowsFreshSession() async throws {
        let cwd = workspace.path
        let id = sessionID
        let bridge = makeBridge { method, _ in
            if method == "thread/read" { return ["thread": ["cwd": cwd]] }
            throw TerminalSessionError.rpc(code: -32600, message: "no rollout found for thread id \(id)")
        }
        let result = try await bridge.restorableSessionID(sessionID, workspace: workspace)
        XCTAssertNil(result)
    }

    func testConfirmedEmptyHistoryStartsFresh() async throws {
        let cwd = workspace.path
        let bridge = makeBridge { method, _ in
            method == "thread/read" ? ["thread": ["cwd": cwd]] : ["data": [[String: Any]]()]
        }
        let result = try await bridge.restorableSessionID(sessionID, workspace: workspace)
        XCTAssertNil(result)
    }

    func testWrongWorkspaceDoesNotSilentlyDiscardSession() async throws {
        let bridge = makeBridge { _, _ in ["thread": ["cwd": "/tmp/different-project"]] }
        do {
            _ = try await bridge.restorableSessionID(sessionID, workspace: workspace)
            XCTFail("A workspace mismatch must remain an explicit error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("另一个工作目录"))
        }
    }

    func testPermissionTransportAndOtherMissingErrorsAreNotTreatedAsEmpty() async throws {
        let errors: [TerminalSessionError] = [
            .message("connection timed out"),
            .rpc(code: -32603, message: "Permission denied reading history"),
            .rpc(code: -32600, message: "thread not loaded: another-session"),
            .rpc(code: -32600, message: "cannot read history: thread not loaded: \(sessionID)"),
            .rpc(code: -32603, message: "thread not loaded: \(sessionID)")
        ]
        for expected in errors {
            let bridge = makeBridge { _, _ in throw expected }
            do {
                _ = try await bridge.restorableSessionID(sessionID, workspace: workspace)
                XCTFail("Restoration should preserve errors: \(expected.localizedDescription)")
            } catch {
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
            }
        }
    }

    func testUnreadableOrMalformedDurableHistoryDoesNotDiscardSession() async throws {
        let cwd = workspace.path
        let failure = TerminalSessionError.rpc(code: -32603, message: "history storage unavailable")
        let unavailable = makeBridge { method, _ in
            if method == "thread/read" { return ["thread": ["cwd": cwd]] }
            throw failure
        }
        do {
            _ = try await unavailable.restorableSessionID(sessionID, workspace: workspace)
            XCTFail("History failures must be reported")
        } catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }

        let malformed = makeBridge { method, _ in
            method == "thread/read" ? ["thread": ["cwd": cwd]] : [:]
        }
        do {
            _ = try await malformed.restorableSessionID(sessionID, workspace: workspace)
            XCTFail("A malformed history response must not create a new session")
        } catch { XCTAssertTrue(error.localizedDescription.contains("会话已保留")) }
    }

    private func makeBridge(_ handler: @escaping (String, [String: Any]) async throws -> [String: Any]) -> TerminalSession {
        TerminalSession(executableURL: URL(fileURLWithPath: "/unused/codex"), requestHandler: handler)
    }
}
