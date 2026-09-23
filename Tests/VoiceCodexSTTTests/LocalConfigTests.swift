import Foundation
import XCTest
@testable import VoiceCodex

final class LocalConfigTests: XCTestCase {
    func testLiveExecutionDefaultAndSavedOptOutSurviveCredentialReload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertTrue(fixture.load().liveMacExecution)
        var saved = LocalConfig()
        saved.liveMacExecution = false
        try saved.save(directory: fixture.support)
        var loaded = fixture.load()
        XCTAssertFalse(loaded.liveMacExecution)
        loaded.liveMacExecution = true
        loaded.reloadCredentials(environment: [:], directory: fixture.support, currentDirectory: fixture.cwd)
        XCTAssertTrue(loaded.liveMacExecution)
    }

    func testCredentialPrecedenceAndSavedSessionPreservation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var saved = LocalConfig()
        saved.jevAPIKey = "saved-jev"
        saved.sonioxAPIKey = "saved-soniox"
        saved.executionMode = "codex"
        saved.sessionID = "existing-session"
        saved.workspacePath = "/fixture/workspace"
        try saved.save(directory: fixture.support)
        try fixture.write("TYPESAFE_API_KEY=support-jev\nSONIOX_API_KEY=support-soniox\n", in: fixture.support)
        try fixture.write("TYPESAFE_API_KEY=cwd-jev\nSONIOX_API_KEY=\n", in: fixture.cwd)

        var loaded = fixture.load()
        XCTAssertEqual(loaded.jevAPIKey, "cwd-jev")
        XCTAssertEqual(loaded.sonioxAPIKey, "support-soniox")
        XCTAssertEqual(loaded.sessionID, "existing-session")
        XCTAssertEqual(loaded.workspacePath, "/fixture/workspace")
        XCTAssertEqual(loaded.executionMode, "codex")
        XCTAssertEqual(loaded.envFile, fixture.cwd.appendingPathComponent(".env"))

        loaded = fixture.load(environment: ["TYPESAFE_API_KEY": "process-jev", "SONIOX_API_KEY": "   "])
        XCTAssertEqual(loaded.jevAPIKey, "process-jev")
        XCTAssertEqual(loaded.sonioxAPIKey, "support-soniox")
        XCTAssertNil(loaded.environmentError)
    }

    func testExplicitFileReplacesCWDAndBlankValuesPreserveSavedCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var saved = LocalConfig()
        saved.sonioxAPIKey = "existing-soniox"
        try saved.save(directory: fixture.support)
        try fixture.write("SONIOX_API_KEY=cwd-soniox\n", in: fixture.cwd)
        let selected = fixture.cwd.appendingPathComponent("selected.env")
        try "SONIOX_API_KEY=\nTYPESAFE_API_KEY=selected-jev\nTYPESAFE_DEFAULT_MODEL=custom-model\n"
            .write(to: selected, atomically: true, encoding: .utf8)
        let loaded = fixture.load(environment: ["VOICECODEX_ENV_FILE": "selected.env"])
        XCTAssertEqual(loaded.sonioxAPIKey, "existing-soniox")
        XCTAssertEqual(loaded.jevAPIKey, "selected-jev")
        XCTAssertEqual(loaded.jevModel, "custom-model")
        XCTAssertEqual(loaded.envFile, selected)
        XCTAssertEqual(loaded.executionMode, "mac")
    }

    func testReloadRefreshesCredentialsAndPreservesActiveState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("TYPESAFE_API_KEY=first\n", in: fixture.support)
        var config = fixture.load()
        config.sessionID = "in-memory-session"
        config.projectPath = "/fixture/project"
        config.workspacePath = "/fixture/active-worktree"
        config.executionMode = "codex"
        try fixture.write("TYPESAFE_API_KEY=second\nTYPESAFE_DEFAULT_MODEL=next-model\n", in: fixture.support)
        config.reloadCredentials(environment: [:], directory: fixture.support, currentDirectory: fixture.cwd)
        XCTAssertEqual(config.jevAPIKey, "second")
        XCTAssertEqual(config.jevModel, "next-model")
        XCTAssertEqual(config.sessionID, "in-memory-session")
        XCTAssertEqual(config.projectPath, "/fixture/project")
        XCTAssertEqual(config.workspacePath, "/fixture/active-worktree")
        XCTAssertEqual(config.executionMode, "codex")
    }

    func testInvalidFileIsVisibleAndDoesNotPartiallyApplyOrEchoSecrets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var saved = LocalConfig()
        saved.jevAPIKey = "saved-jev"
        try saved.save(directory: fixture.support)
        try fixture.write("TYPESAFE_API_KEY=must-not-partially-apply\nprivate-secret\n", in: fixture.cwd)
        let loaded = fixture.load()
        XCTAssertEqual(loaded.jevAPIKey, "saved-jev")
        XCTAssertTrue(loaded.environmentError?.contains("line 2") == true)
        XCTAssertFalse(loaded.environmentError?.contains("private-secret") == true)
        let missing = fixture.load(environment: ["VOICECODEX_ENV_FILE": "missing.env"])
        XCTAssertTrue(missing.environmentError?.contains("could not be found") == true)
    }

    func testSaveProtectsCredentialsAndDoesNotPersistDiagnostics() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var config = LocalConfig()
        config.environmentError = "transient diagnostic"
        config.envFile = fixture.cwd.appendingPathComponent(".env")
        try config.save(directory: fixture.support)
        let file = fixture.support.appendingPathComponent("config.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(json["environmentError"])
        XCTAssertNil(json["envFile"])
        XCTAssertEqual(fixture.load().jevModel, "jev-1.13.0")
    }

    private struct Fixture {
        let root: URL
        let support: URL
        let cwd: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConfigTests-\(UUID().uuidString)")
            support = root.appendingPathComponent("support", isDirectory: true)
            cwd = root.appendingPathComponent("working", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        }

        func write(_ contents: String, in directory: URL) throws {
            try contents.write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        }

        func load(environment: [String: String] = [:]) -> LocalConfig {
            LocalConfig.load(environment: environment, directory: support, currentDirectory: cwd)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
