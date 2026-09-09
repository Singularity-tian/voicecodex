import Foundation
import Darwin

public struct TerminalSnapshot: Sendable {
    public let isActive: Bool
    public let waitingForApproval: Bool
    public let waitingForUserInput: Bool
    public let isLoaded: Bool
}

public enum TerminalSessionError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

/// Owns a private, authenticated app-server. The real Terminal TUI owns the
/// interactive thread and its approvals; this connection only observes and queues.
@MainActor
public final class TerminalSession {
    public private(set) var tokenFileURL: URL?
    public private(set) var remoteAddress: String?
    private let executableURL: URL
    private var server: Process?
    private var runtimeDirectory: URL?
    private var logHandle: FileHandle?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var connectionID = UUID()
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var activeTurns: [String: String] = [:]

    public init(executableURL: URL) { self.executableURL = executableURL }

    public func start() async throws -> String {
        if let remoteAddress, server?.isRunning == true, socket != nil { return remoteAddress }
        shutdown()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicecodex-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        runtimeDirectory = directory
        let token = UUID().uuidString + UUID().uuidString
        let tokenFile = directory.appendingPathComponent("remote-token")
        guard FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            shutdown()
            throw TerminalSessionError.message("无法创建本机终端连接凭证。")
        }
        tokenFileURL = tokenFile
        do {
            let port = try Self.unusedLoopbackPort()
            let address = "ws://127.0.0.1:\(port)"
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["app-server", "--listen", address, "--ws-auth", "capability-token",
                                 "--ws-token-file", tokenFile.path]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "SONIOX_API_KEY")
            environment.removeValue(forKey: "VOICECODEX_REMOTE_TOKEN")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let log = directory.appendingPathComponent("server.log")
            FileManager.default.createFile(atPath: log.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            logHandle = handle
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            server = process
            remoteAddress = address

            var lastError: Error?
            for _ in 0..<50 {
                try Task.checkCancellation()
                guard process.isRunning else {
                    throw TerminalSessionError.message("Codex app-server 启动失败，请检查 CLI 安装和配置。")
                }
                do {
                    try await connect(address: address, token: token)
                    return address
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    disconnect()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            throw lastError ?? TerminalSessionError.message("无法连接本机 Codex app-server。")
        } catch {
            shutdown()
            throw error
        }
    }

    /// Returns only a loaded thread belonging to this exact worktree. Starting
    /// an empty TUI is sufficient; no hidden seed prompt or rollout-file scan.
    public func discover(workspace: URL, expectedSessionID: String?) async throws -> String? {
        var cursor: String?
        var candidates: [String] = []
        repeat {
            var parameters: [String: Any] = ["limit": 100]
            if let cursor { parameters["cursor"] = cursor }
            let page = try await request("thread/loaded/list", parameters)
            for id in page["data"] as? [String] ?? [] {
                if let expectedSessionID, id != expectedSessionID { continue }
                let metadata = try await thread(id)
                guard let cwd = metadata["cwd"] as? String,
                      Self.sameDirectory(URL(fileURLWithPath: cwd), workspace) else { continue }
                candidates.append(id)
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        guard candidates.count <= 1 else {
            throw TerminalSessionError.message("这个工作目录打开了多个 Codex 会话，请保留一个终端会话后重试。")
        }
        return candidates.first
    }

    /// clientMessageID correlates the resulting user message. The current server
    /// does not deduplicate it: never automatically retry an uncertain submission.
    @discardableResult
    public func enqueue(prompt: String, sessionID: String,
                        clientMessageID: String = UUID().uuidString) async throws -> String {
        let result = try await request("thread/queue/add", [
            "threadId": sessionID, "clientUserMessageId": clientMessageID,
            "input": [["type": "text", "text": prompt]]
        ])
        guard let submission = result["queuedSubmission"] as? [String: Any],
              let id = submission["id"] as? String else {
            throw TerminalSessionError.message("Codex 没有确认接收这条指令。")
        }
        return id
    }

    public func snapshot(sessionID: String) async throws -> TerminalSnapshot {
        // Read the queue first: a submission can move into an active turn
        // between requests, so reading idle status first would miss that work.
        let queue = try await request("thread/queue/list", ["threadId": sessionID, "limit": 1])
        let metadata = try await thread(sessionID)
        let status = metadata["status"] as? [String: Any] ?? [:]
        let flags = status["activeFlags"] as? [String] ?? []
        let isActive = status["type"] as? String == "active"
            || !(queue["data"] as? [[String: Any]] ?? []).isEmpty
        return TerminalSnapshot(isActive: isActive,
                                waitingForApproval: flags.contains("waitingOnApproval"),
                                waitingForUserInput: flags.contains("waitingOnUserInput"),
                                isLoaded: status["type"] as? String != "notLoaded")
    }

    public func interrupt(sessionID: String) async throws {
        // Clear the server queue before interrupting, so completing this turn
        // cannot automatically start the next queued voice command.
        var cursor: String?
        var queuedIDs: [String] = []
        repeat {
            var parameters: [String: Any] = ["threadId": sessionID, "limit": 100]
            if let cursor { parameters["cursor"] = cursor }
            let page = try await request("thread/queue/list", parameters)
            queuedIDs += (page["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        for id in queuedIDs {
            _ = try await request("thread/queue/delete", ["threadId": sessionID, "queuedSubmissionId": id])
        }
        let page = try await request("thread/turns/list", ["threadId": sessionID, "limit": 1, "itemsView": "summary"])
        let latest = (page["data"] as? [[String: Any]])?.first
        let turnID = latest?["status"] as? String == "inProgress" ? latest?["id"] as? String : activeTurns[sessionID]
        if let turnID {
            _ = try await request("turn/interrupt", ["threadId": sessionID, "turnId": turnID])
        }
    }

    /// Signals only the process created by this instance. Existing Codex daemons
    /// and Terminal windows are never terminated by process name.
    public func shutdown() {
        disconnect()
        if let process = server, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).async {
                let end = Date().addingTimeInterval(2)
                while process.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }
        server = nil
        try? logHandle?.close()
        logHandle = nil
        if let runtimeDirectory { try? FileManager.default.removeItem(at: runtimeDirectory) }
        runtimeDirectory = nil
        tokenFileURL = nil
        remoteAddress = nil
        activeTurns.removeAll()
    }

    private func thread(_ id: String) async throws -> [String: Any] {
        let result = try await request("thread/read", ["threadId": id, "includeTurns": false])
        guard let thread = result["thread"] as? [String: Any] else {
            throw TerminalSessionError.message("无法读取 Codex 终端会话。")
        }
        return thread
    }

    private func connect(address: String, token: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration)
        self.session = session
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        let generation = UUID()
        connectionID = generation
        socket.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.connectionID == generation else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: continue
                    }
                    self.receive(data)
                }
            } catch {
                guard let self, self.connectionID == generation, !Task.isCancelled else { return }
                self.failPending(TerminalSessionError.message("与 Codex 终端的连接已断开。"))
            }
        }
        _ = try await self.request("initialize", [
            "clientInfo": ["name": "voicecodex", "title": "VoiceCodex", "version": "0.2"],
            "capabilities": ["experimentalApi": true]
        ], timeout: 2)
        try await send(["method": "initialized", "params": [:]])
    }

    private func request(_ method: String, _ parameters: [String: Any], timeout: Double = 15) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard socket != nil else { throw TerminalSessionError.message("Codex 终端尚未连接。") }
        nextRequestID += 1
        let id = nextRequestID
        let generation = connectionID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    self?.finish(id, .failure(TerminalSessionError.message("Codex 终端响应超时；请查看终端状态。")))
                }
                Task { [weak self] in
                    guard let self, self.pending[id] != nil, self.connectionID == generation else { return }
                    do { try await self.send(["id": id, "method": method, "params": parameters]) }
                    catch { self.finish(id, .failure(TerminalSessionError.message("无法发送指令到 Codex 终端。"))) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    private func send(_ message: [String: Any]) async throws {
        guard let socket else { throw TerminalSessionError.message("Codex 终端尚未连接。") }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = message["id"] as? Int, message["method"] == nil {
            if let error = message["error"] as? [String: Any] {
                let detail = String((error["message"] as? String ?? "请求失败").prefix(1_200))
                finish(id, .failure(TerminalSessionError.message("Codex: " + detail)))
            } else {
                finish(id, .success(message["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        guard let parameters = message["params"] as? [String: Any],
              let threadID = parameters["threadId"] as? String else { return }
        if message["method"] as? String == "turn/started",
           let turn = parameters["turn"] as? [String: Any], let id = turn["id"] as? String {
            activeTurns[threadID] = id
        } else if message["method"] as? String == "turn/completed" {
            activeTurns.removeValue(forKey: threadID)
        }
        // Do not answer approval or input requests: the attached native TUI is
        // the interactive client and presents these controls to the user.
    }

    private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPending(_ error: Error) {
        for id in Array(pending.keys) { finish(id, .failure(error)) }
    }

    private func disconnect() {
        connectionID = UUID()
        reader?.cancel()
        reader = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        failPending(CancellationError())
    }

    private static func sameDirectory(_ left: URL, _ right: URL) -> Bool {
        if left.resolvingSymlinksInPath().standardizedFileURL == right.resolvingSymlinksInPath().standardizedFileURL { return true }
        guard let lhs = try? FileManager.default.attributesOfItem(atPath: left.path),
              let rhs = try? FileManager.default.attributesOfItem(atPath: right.path),
              let lhsFile = lhs[.systemFileNumber] as? NSNumber,
              let rhsFile = rhs[.systemFileNumber] as? NSNumber,
              let lhsDevice = lhs[.systemNumber] as? NSNumber,
              let rhsDevice = rhs[.systemNumber] as? NSNumber else { return false }
        return lhsFile == rhsFile && lhsDevice == rhsDevice
    }

    private static func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TerminalSessionError.message("无法创建本机终端连接。") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw TerminalSessionError.message("无法分配本机 Codex 端口。") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard result == 0 else { throw TerminalSessionError.message("无法读取本机 Codex 端口。") }
        return UInt16(bigEndian: address.sin_port)
    }
}
