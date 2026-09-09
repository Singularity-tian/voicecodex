import Foundation
import XCTest
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
