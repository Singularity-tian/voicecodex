import Foundation
import XCTest
import Darwin
@testable import VoiceCodexCore

final class WorkspaceManagerTests: XCTestCase {
    func testWorktreeStartsAtCommittedHeadAndPreservesDirtyProject() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("Project with spaces")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--initial-branch=main"], in: project)
        try git(["config", "user.name", "VoiceCodex Test"], in: project)
        try git(["config", "user.email", "voicecodex-test@example.invalid"], in: project)
        let tracked = project.appendingPathComponent("note.txt")
        try "committed\n".write(to: tracked, atomically: true, encoding: .utf8)
        try git(["add", "note.txt"], in: project)
        try git(["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Initial fixture"], in: project)
        let originalHead = try git(["rev-parse", "HEAD"], in: project)
        try "user's pending edit\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "untracked\n".write(to: project.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        let originalStatus = try git(["status", "--porcelain=v1"], in: project)

        let workspace = try WorkspaceManager.prepare(
            project: project,
            storage: temporary.appendingPathComponent("worktrees")
        )

        XCTAssertNotEqual(workspace, project)
        XCTAssertEqual(try String(contentsOf: tracked, encoding: .utf8), "user's pending edit\n")
        XCTAssertEqual(try git(["status", "--porcelain=v1"], in: project), originalStatus)
        XCTAssertEqual(try git(["branch", "--show-current"], in: project), "main")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: workspace), originalHead)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("note.txt"), encoding: .utf8), "committed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("draft.txt").path))
        XCTAssertTrue(try git(["branch", "--show-current"], in: workspace).hasPrefix("codex/voice-"))
        XCTAssertEqual(try git(["status", "--porcelain=v1"], in: workspace), "")
    }

    func testNonRepositoryProducesUsefulErrorWithoutCreatingStorage() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = temporary.appendingPathComponent("worktrees")
        XCTAssertThrowsError(try WorkspaceManager.prepare(project: temporary, storage: storage)) { error in
            guard case WorkspaceManager.WorkspaceError.notGitRepository = error else {
                return XCTFail("Expected non-repository error, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Git"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
    }

    func testStalledGitTimesOutAndKillsProcessThatIgnoresTermination() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (executable, pidFile) = try blockingGit(in: temporary)
        let started = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try WorkspaceManager.git(
            ["rev-parse", "--show-toplevel"], in: temporary,
            executable: executable, timeout: 1
        )) { error in
            guard case WorkspaceManager.WorkspaceError.gitTimedOut = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("系统弹窗"))
        }

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        try assertProcessStopped(pidFile: pidFile)
    }

    func testCancellingStalledGitStopsPromptlyWithoutWaitingForDeadline() async throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (executable, pidFile) = try blockingGit(in: temporary)
        let task = Task.detached {
            try WorkspaceManager.git(
                ["rev-parse", "--show-toplevel"], in: temporary,
                executable: executable, timeout: 30
            )
        }
        defer { task.cancel() }
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !FileManager.default.fileExists(atPath: pidFile.path)
                && ProcessInfo.processInfo.systemUptime < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "Fake Git must be running before cancellation")
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 2)
        try assertProcessStopped(pidFile: pidFile)
    }

    func testGitDrainsOutputLargerThanThePipeBuffer() throws {
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("verbose-git")
        try "#!/bin/sh\n/usr/bin/head -c 262144 /dev/zero\n".write(
            to: executable, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let result = try WorkspaceManager.git([], in: temporary, executable: executable, timeout: 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 262_144)
    }

    private func blockingGit(in directory: URL) throws -> (executable: URL, pidFile: URL) {
        let executable = directory.appendingPathComponent("stalled-git")
        let pidFile = directory.appendingPathComponent("child.pid")
        let quotedPIDPath = "'" + pidFile.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Ignore TERM, then replace the shell so the test has exactly one child
        // process and proves the bounded KILL escalation rather than orphaning it.
        let script = "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > \(quotedPIDPath)\nprintf 'partial output\\n'\nexec /bin/sleep 30\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, pidFile)
    }

    private func assertProcessStopped(pidFile: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText), file: file, line: line)
        let status = Darwin.kill(pid, 0)
        let error = errno
        XCTAssertEqual(status, -1, "Child process must not survive", file: file, line: line)
        XCTAssertEqual(error, ESRCH, file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCodexWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WorkspaceManagerTests.Git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}
