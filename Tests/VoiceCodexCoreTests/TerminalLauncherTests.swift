import Foundation
import XCTest
@testable import VoiceCodexCore

final class TerminalLauncherTests: XCTestCase {
    func testPromptRemainsLiteralIncludingShellSyntaxAndTrailingNewlines() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let injectedFile = fixture.root.appendingPathComponent("must-not-exist")
        let prompt = "--dangerous-flag $(touch '\(injectedFile.path)') `echo injected` '\" ; 中文\nsecond line\n\n"
        let files = try TerminalLauncher.prepare(
            executableURL: fixture.executable, workspaceURL: fixture.workspace,
            remoteAddress: "unix:///tmp/VoiceCodex ' socket", prompt: prompt, storageURL: fixture.storage
        )
        let script = try String(contentsOf: files.commandURL, encoding: .utf8)
        XCTAssertFalse(script.contains(prompt))
        XCTAssertEqual(try mode(files.directoryURL), 0o700)
        XCTAssertEqual(try mode(files.commandURL), 0o700)
        XCTAssertEqual(try mode(files.promptURL), 0o600)

        XCTAssertEqual(try run(files.commandURL), 0)
        let arguments = try readArguments(fixture.arguments)
        XCTAssertEqual(arguments, ["--remote", "unix:///tmp/VoiceCodex ' socket", "-C", fixture.workspace.path,
                                   "--no-alt-screen", "-a", "on-request", "--sandbox", "workspace-write", "--", prompt])
        XCTAssertFalse(FileManager.default.fileExists(atPath: injectedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.promptURL.path))
        XCTAssertNotNil(Int(try marker(files.startedURL)))
        XCTAssertEqual(try marker(files.exitedURL), "0")
        XCTAssertEqual(try mode(files.startedURL), 0o600)
        XCTAssertEqual(try mode(files.exitedURL), 0o600)
    }

    func testResumeWithNoPromptAndTokenFromFileRecordsFailureExit() throws {
        let fixture = try makeFixture(exitCode: 17)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tokenURL = fixture.root.appendingPathComponent("token secret.txt")
        let token = "private-token-$()-not-source"
        try Data(token.utf8).write(to: tokenURL)
        let sessionID = UUID().uuidString.lowercased()
        let files = try TerminalLauncher.prepare(
            executableURL: fixture.executable, workspaceURL: fixture.workspace,
            remoteAddress: "ws://127.0.0.1:45678", authTokenFileURL: tokenURL,
            sessionID: sessionID, storageURL: fixture.storage
        )
        XCTAssertFalse(try String(contentsOf: files.commandURL, encoding: .utf8).contains(token))
        XCTAssertEqual(try run(files.commandURL), 17)
        XCTAssertEqual(try readArguments(fixture.arguments), [
            "--remote", "ws://127.0.0.1:45678", "-C", fixture.workspace.path,
            "--no-alt-screen", "-a", "on-request", "--sandbox", "workspace-write",
            "--remote-auth-token-env", "VOICECODEX_REMOTE_TOKEN", "resume", sessionID
        ])
        XCTAssertEqual(try String(contentsOf: fixture.tokenCapture, encoding: .utf8), token)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenURL.path), "Shared server token remains available")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.promptURL.path))
        XCTAssertEqual(try marker(files.exitedURL), "17")
    }

    func testResumePlacesPromptSeparatorAfterSessionID() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionID = UUID().uuidString
        let files = try TerminalLauncher.prepare(
            executableURL: fixture.executable, workspaceURL: fixture.workspace,
            remoteAddress: "ws://127.0.0.1:45678", prompt: "-literal prompt",
            sessionID: sessionID, storageURL: fixture.storage
        )
        XCTAssertEqual(try run(files.commandURL), 0)
        XCTAssertEqual(Array(try readArguments(fixture.arguments).suffix(4)), ["resume", sessionID, "--", "-literal prompt"])
    }

    func testRejectsExternalServerInvalidSessionAndNULPromptBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for address in ["wss://example.com:1234", "ws://127.0.0.2:1234", "ws://127.0.0.1:1234@evil.com", "ws://127.0.0.1:0", "unix://relative"] {
            XCTAssertThrowsError(try TerminalLauncher.prepare(
                executableURL: fixture.executable, workspaceURL: fixture.workspace,
                remoteAddress: address, storageURL: fixture.storage
            ))
        }
        XCTAssertThrowsError(try TerminalLauncher.prepare(
            executableURL: fixture.executable, workspaceURL: fixture.workspace,
            remoteAddress: "ws://127.0.0.1:1234", sessionID: "$(bad)", storageURL: fixture.storage
        ))
        XCTAssertThrowsError(try TerminalLauncher.prepare(
            executableURL: fixture.executable, workspaceURL: fixture.workspace,
            remoteAddress: "ws://127.0.0.1:1234", prompt: "a\0b", storageURL: fixture.storage
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.path))
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let workspace: URL
        let storage: URL
        let arguments: URL
        let tokenCapture: URL
    }

    private func makeFixture(exitCode: Int = 0) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLauncherTests-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace ' with spaces")
        let executable = root.appendingPathComponent("fake ' codex")
        let arguments = root.appendingPathComponent("arguments.bin")
        let tokenCapture = root.appendingPathComponent("token.bin")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let script = "#!/bin/bash\nprintf '%s\\0' \"$@\" > \(quote(arguments.path))\nprintf '%s' \"${VOICECODEX_REMOTE_TOKEN-}\" > \(quote(tokenCapture.path))\nexit \(exitCode)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return Fixture(root: root, executable: executable, workspace: workspace,
                       storage: root.appendingPathComponent("private launch ' files"),
                       arguments: arguments, tokenCapture: tokenCapture)
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func marker(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readArguments(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private func run(_ command: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [command.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
