import Foundation

public enum WorkspaceManager {
    public enum WorkspaceError: LocalizedError {
        case invalidProject
        case notGitRepository
        case noCommit
        case storageInsideProject
        case gitFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidProject:
                return "请选择一个存在的项目文件夹。"
            case .notGitRepository:
                return "这个文件夹不在 Git 仓库中。请先选择已有 Git 仓库的项目。"
            case .noCommit:
                return "这个 Git 仓库还没有提交。请先创建首次提交，再创建语音任务工作区。"
            case .storageInsideProject:
                return "工作区存储目录必须在原项目之外，以保留原项目的文件状态。"
            case .gitFailed(let detail):
                return "创建独立 Git 工作区失败：\(detail)"
            }
        }
    }

    /// Starts from the selected checkout's committed HEAD. Uncommitted files stay
    /// in that checkout; this method never checks out, resets, or cleans it.
    public static func prepare(project: URL, storage: URL) throws -> URL {
        let fileManager = FileManager.default
        let selected = project.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard selected.isFileURL,
              fileManager.fileExists(atPath: selected.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceError.invalidProject
        }

        let topLevel = try git(["rev-parse", "--show-toplevel"], in: selected)
        guard topLevel.status == 0, !topLevel.output.isEmpty else {
            throw WorkspaceError.notGitRepository
        }
        let source = URL(fileURLWithPath: topLevel.output, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let commit = try git(["rev-parse", "--verify", "HEAD^{commit}"], in: source)
        guard commit.status == 0 else { throw WorkspaceError.noCommit }

        let destinationRoot = storage.standardizedFileURL.resolvingSymlinksInPath()
        guard destinationRoot.isFileURL,
              destinationRoot.path != source.path,
              !destinationRoot.path.hasPrefix(source.path + "/") else {
            throw WorkspaceError.storageInsideProject
        }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let identity = "voice-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8).lowercased())"
        let branch = "codex/\(identity)"
        let destination = destinationRoot.appendingPathComponent(
            "\(source.lastPathComponent)-\(identity)", isDirectory: true
        )
        let result = try git(
            ["worktree", "add", "--quiet", "-b", branch, destination.path, commit.output],
            in: source
        )
        guard result.status == 0 else { throw WorkspaceError.gitFailed(result.output) }
        return destination
    }

    private static func git(_ arguments: [String], in directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        // A GUI launch or a caller's shell must not redirect these operations to
        // an unrelated repository, index, or object database.
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
