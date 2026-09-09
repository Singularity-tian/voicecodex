import Foundation

struct LocalConfig: Codable {
    var sonioxAPIKey: String = ""
    var codexPath: String = ""
    var projectPath: String?
    var workspacePath: String?
    var sessionID: String?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceCodex", isDirectory: true)
    static var file: URL { directory.appendingPathComponent("config.json") }

    static func load() -> LocalConfig {
        var config = LocalConfig()
        if let data = try? Data(contentsOf: file),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            config.sonioxAPIKey = json["sonioxAPIKey"] as? String ?? ""
            config.codexPath = json["codexPath"] as? String ?? ""
            config.projectPath = json["projectPath"] as? String
            config.workspacePath = json["workspacePath"] as? String
            config.sessionID = json["sessionID"] as? String
        }
        if let value = ProcessInfo.processInfo.environment["SONIOX_API_KEY"], !value.isEmpty {
            config.sonioxAPIKey = value
        }
        if config.codexPath.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            config.codexPath = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
                .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        }
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}
