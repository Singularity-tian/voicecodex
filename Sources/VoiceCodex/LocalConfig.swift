import Foundation
import VoiceCodexCore

struct LocalConfig: Codable {
    var sonioxAPIKey: String = ""
    var jevAPIKey: String = ""
    var jevModel: String = "jev-1.13.0"
    var executionMode: String = "mac"
    var liveMacExecution = true
    var codexPath: String = ""
    var projectPath: String?
    var workspacePath: String?
    var sessionID: String?
    var environmentError: String?
    var envFile: URL = LocalConfig.directory.appendingPathComponent(".env")

    private enum CodingKeys: String, CodingKey {
        case sonioxAPIKey, jevAPIKey, jevModel, executionMode, liveMacExecution, codexPath, projectPath, workspacePath, sessionID
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceCodex", isDirectory: true)
    static var file: URL { directory.appendingPathComponent("config.json") }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     directory: URL = LocalConfig.directory,
                     currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> LocalConfig {
        var config = LocalConfig()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            config.sonioxAPIKey = json["sonioxAPIKey"] as? String ?? ""
            config.jevAPIKey = json["jevAPIKey"] as? String ?? ""
            config.jevModel = nonblank(json["jevModel"] as? String) ?? config.jevModel
            config.executionMode = nonblank(json["executionMode"] as? String) ?? config.executionMode
            config.liveMacExecution = json["liveMacExecution"] as? Bool ?? true
            config.codexPath = json["codexPath"] as? String ?? ""
            config.projectPath = json["projectPath"] as? String
            config.workspacePath = json["workspacePath"] as? String
            config.sessionID = json["sessionID"] as? String
        }

        let supportFile = directory.appendingPathComponent(".env")
        let explicitPath = nonblank(environment["VOICECODEX_ENV_FILE"])
        let candidateFile = explicitPath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: currentDirectory).standardizedFileURL
        } ?? currentDirectory.appendingPathComponent(".env")
        config.envFile = (explicitPath != nil || FileManager.default.fileExists(atPath: candidateFile.path))
            ? candidateFile : supportFile

        var errors: [String] = []
        func applyFile(_ url: URL, label: String, required: Bool = false) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                if required { errors.append("\(label) could not be found.") }
                return
            }
            do {
                config.apply(try EnvironmentFile.parse(String(contentsOf: url, encoding: .utf8)))
            } catch let error as EnvironmentFile.ParseError {
                errors.append("\(label): \(error.localizedDescription)")
            } catch {
                // Do not surface raw file errors, which may include sensitive paths.
                errors.append("\(label) could not be read as UTF-8 text.")
            }
        }
        let sameFile = candidateFile.resolvingSymlinksInPath() == supportFile.resolvingSymlinksInPath()
        applyFile(supportFile, label: "Application Support .env", required: explicitPath != nil && sameFile)
        if !sameFile {
            applyFile(candidateFile, label: "Selected .env", required: explicitPath != nil)
        }
        config.apply(environment)
        config.environmentError = errors.isEmpty ? nil : errors.joined(separator: "\n")

        if config.codexPath.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            config.codexPath = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        }
        return config
    }

    /// Reloads edited credentials without replacing the in-memory workspace or active session.
    mutating func reloadCredentials(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    directory: URL = LocalConfig.directory,
                                    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        let latest = Self.load(environment: environment, directory: directory, currentDirectory: currentDirectory)
        sonioxAPIKey = latest.sonioxAPIKey
        jevAPIKey = latest.jevAPIKey
        jevModel = latest.jevModel
        environmentError = latest.environmentError
        envFile = latest.envFile
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private mutating func apply(_ values: [String: String]) {
        if let value = Self.nonblank(values["SONIOX_API_KEY"]) { sonioxAPIKey = value }
        if let value = Self.nonblank(values["TYPESAFE_API_KEY"]) { jevAPIKey = value }
        if let value = Self.nonblank(values["TYPESAFE_DEFAULT_MODEL"]) { jevModel = value }
    }

    func save(directory: URL = LocalConfig.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("config.json")
        let data = try JSONEncoder().encode(self)
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
