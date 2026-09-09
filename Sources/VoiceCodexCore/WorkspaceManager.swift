import Foundation
import Darwin

public enum WorkspaceManager {
    public enum WorkspaceError: LocalizedError {
        case invalidProject
        case notGitRepository
        case noCommit
        case storageInsideProject
        case gitFailed(String)
        case gitTimedOut

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
            case .gitTimedOut:
                return "Git 操作等待超时。系统可能正在等待文件夹授权，请在系统弹窗允许访问后重试。如果选的是 worktree，也可以改选包含 .git 的原始仓库。"
            }
        }
    }

    /// Starts from the selected checkout's committed HEAD. Uncommitted files stay
    /// in that checkout; this method never checks out, resets, or cleans it.
    public static func prepare(project: URL, storage: URL) throws -> URL {
        try checkCancellation()
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
        try checkCancellation()
        let source = URL(fileURLWithPath: topLevel.output, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let commit = try git(["rev-parse", "--verify", "HEAD^{commit}"], in: source)
        guard commit.status == 0 else { throw WorkspaceError.noCommit }
        try checkCancellation()

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
            in: source,
            timeout: 60
        )
        guard result.status == 0 else { throw WorkspaceError.gitFailed(result.output) }
        return destination
    }

    // The executable and deadline are injectable so cancellation can be checked
    // against an actual stalled child process without waiting on macOS dialogs.
    static func git(
        _ arguments: [String],
        in directory: URL,
        executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: TimeInterval = 15
    ) throws -> (status: Int32, output: String) {
        try checkCancellation()
        let process = Process()
        process.executableURL = executable
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
        let reader = try GitOutputReader(output.fileHandleForReading)
        defer { reader.cancel() }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if Task<Never, Never>.isCancelled {
                stop(process)
                throw CancellationError()
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop(process)
                throw WorkspaceError.gitTimedOut
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        try checkCancellation()
        let data = reader.finish()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func checkCancellation() throws {
        if Task<Never, Never>.isCancelled { throw CancellationError() }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let processID = process.processIdentifier
        Darwin.kill(processID, SIGTERM)
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(processID, SIGKILL)
            let killDeadline = ProcessInfo.processInfo.systemUptime + 0.3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        // Do not call waitUntilExit: an OS permission dialog or stalled file
        // system must not make cancellation itself wait indefinitely.
    }
}

/// Drains stdout/stderr independently of the preparation task. Every read is
/// nonblocking, including the final drain, even if a child inherited the pipe.
private final class GitOutputReader {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "com.singularity.voicecodex.git-output")
    private let source: DispatchSourceRead
    private var data = Data()

    init(_ handle: FileHandle) throws {
        let duplicate = Darwin.dup(handle.fileDescriptor)
        guard duplicate >= 0 else { throw POSIXError(.EBADF) }
        let flags = fcntl(duplicate, F_GETFL)
        guard flags >= 0, fcntl(duplicate, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            Darwin.close(duplicate)
            throw POSIXError(.EIO)
        }
        descriptor = duplicate
        source = DispatchSource.makeReadSource(fileDescriptor: duplicate, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(duplicate) }
        source.resume()
    }

    func finish() -> Data {
        queue.sync {
            drain()
            source.cancel()
            return data
        }
    }

    func cancel() { source.cancel() }

    private func drain() {
        guard !source.isCancelled else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each callback so even a continuously writing inherited pipe
        // cannot starve the final snapshot or cancellation.
        for _ in 0..<8 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                source.cancel()
                return
            }
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    deinit { source.cancel() }
}
