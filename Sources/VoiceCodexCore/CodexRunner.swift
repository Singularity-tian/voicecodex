import Foundation
import Darwin

public enum CodexEvent: Sendable {
    case sessionID(String)
    case activity(String)
    case answer(String)
}

public struct CodexRunResult: Sendable {
    public let sessionID: String?
    public let answer: String
    public let exitCode: Int32
}

public enum CodexRunnerError: LocalizedError {
    case alreadyRunning
    case failed(exitCode: Int32, message: String)
    case pipe(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Codex is already executing a command."
        case let .failed(code, message):
            return code == 0 ? "Codex could not complete this turn: \(message)"
                : "Codex exited with status \(code): \(message)"
        case let .pipe(message):
            return "Could not communicate with Codex: \(message)"
        }
    }
}

/// Starts the CLI directly. Prompts never become shell commands or arguments.
public final class CodexRunner: @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let lock = NSLock()
    private var active: Execution?

    public convenience init(executableURL: URL) {
        self.init(executableURL: executableURL, environment: ProcessInfo.processInfo.environment)
    }

    init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        var childEnvironment = environment
        childEnvironment.removeValue(forKey: "SONIOX_API_KEY")
        self.environment = childEnvironment
    }

    public func run(
        prompt: String,
        directory: URL,
        sessionID: String?,
        onEvent: @escaping @Sendable (CodexEvent) -> Void
    ) async throws -> CodexRunResult {
        let execution = Execution(
            executableURL: executableURL, prompt: prompt, directory: directory,
            sessionID: sessionID, environment: environment, onEvent: onEvent
        )
        try reserve(execution)
        defer { release(execution) }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execution.perform() })
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    public func cancel() {
        lock.lock()
        let execution = active
        lock.unlock()
        execution?.cancel()
    }

    private func reserve(_ execution: Execution) throws {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { throw CodexRunnerError.alreadyRunning }
        active = execution
    }

    private func release(_ execution: Execution) {
        lock.lock()
        defer { lock.unlock() }
        if active === execution { active = nil }
    }
}

private final class Execution: @unchecked Sendable {
    private let executableURL: URL
    private let prompt: String
    private let directory: URL
    private let resumedSessionID: String?
    private let environment: [String: String]
    private let onEvent: @Sendable (CodexEvent) -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(
        executableURL: URL, prompt: String, directory: URL, sessionID: String?, environment: [String: String],
        onEvent: @escaping @Sendable (CodexEvent) -> Void
    ) {
        self.executableURL = executableURL
        self.prompt = prompt
        self.directory = directory
        self.resumedSessionID = sessionID
        self.environment = environment
        self.onEvent = onEvent
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // One background queue owns Process and all descriptors. Nonblocking I/O
    // drains both output pipes while delivering stdin, including long prompts.
    func perform() throws -> CodexRunResult {
        if isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        // Speech credentials are private to the app; retain the CLI's remaining
        // inherited configuration and authentication environment unchanged.
        process.environment = environment
        var arguments = ["-a", "never", "exec", "-C", directory.path,
                         "--sandbox", "workspace-write", "--json"]
        if let sessionID = resumedSessionID {
            arguments += ["resume", sessionID, "-"]
        } else {
            arguments += ["-"]
        }
        process.arguments = arguments

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        defer {
            for handle in [input.fileHandleForWriting, input.fileHandleForReading,
                           output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting] {
                try? handle.close()
            }
        }
        try process.run()
        // Parent copies of the child endpoints must not keep pipes alive.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        for descriptor in [inputFD, outputFD, errorFD] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                process.terminate()
                throw CodexRunnerError.pipe(String(cString: strerror(errno)))
            }
        }
        // A CLI that exits before reading stdin must not deliver SIGPIPE to the app.
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)

        let inputData = Data(prompt.utf8)
        var inputOffset = 0
        var inputOpen = true
        var outputOpen = true
        var errorOpen = true
        var outputBuffer = Data()
        var errorTail = Data()
        var sessionID = resumedSessionID
        var answer = ""
        var failure: String?
        var turnFailed = false
        var cancellationStarted: Date?
        var exitedAt: Date?
        var streamError: Error?

        func consumeLine(_ line: Data) {
            guard !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String else { return }
            switch type {
            case "thread.started":
                if let id = json["thread_id"] as? String {
                    sessionID = id
                    onEvent(.sessionID(id))
                }
            case "item.started", "item.completed", "item.updated":
                guard let item = json["item"] as? [String: Any] else { return }
                switch item["type"] as? String {
                case "command_execution":
                    if type != "item.updated", let command = item["command"] as? String {
                        let prefix = type == "item.started" ? "Running: " : "Finished: "
                        onEvent(.activity(prefix + String(command.prefix(800))))
                    }
                case "agent_message":
                    if type == "item.completed", let text = item["text"] as? String {
                        answer = text
                        onEvent(.answer(text))
                    }
                case "file_change":
                    onEvent(.activity(type == "item.completed" ? "Updated files" : "Editing files"))
                default:
                    break
                }
            case "turn.failed", "error":
                let nested = json["error"] as? [String: Any]
                let message = nested?["message"] as? String ?? json["message"] as? String
                failure = String((message ?? "The Codex turn failed.").suffix(4_000))
                if type == "turn.failed" { turnFailed = true }
                onEvent(.activity(failure!))
            default:
                break
            }
        }

        func consumeOutput(_ data: Data) {
            outputBuffer.append(data)
            while let newline = outputBuffer.firstIndex(of: 10) {
                consumeLine(Data(outputBuffer[..<newline]))
                outputBuffer.removeSubrange(...newline)
            }
            // A malformed or extremely large JSONL record cannot grow forever.
            if outputBuffer.count > 8 * 1_024 * 1_024 {
                outputBuffer.removeAll(keepingCapacity: false)
            }
        }

        while true {
            let now = Date()
            if isCancelled, cancellationStarted == nil {
                cancellationStarted = now
                if process.isRunning { process.terminate() }
            }
            if let started = cancellationStarted, process.isRunning,
               now.timeIntervalSince(started) > 1.5 {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            if !process.isRunning, exitedAt == nil { exitedAt = now }
            if let exitTime = exitedAt {
                // Grandchildren may inherit stdout. Drain pending output, but do
                // not wait indefinitely for a descriptor they forgot to close.
                if (!outputOpen && !errorOpen) || now.timeIntervalSince(exitTime) > 1 {
                    break
                }
            }
            if inputOpen, inputOffset == inputData.count || exitedAt != nil || cancellationStarted != nil {
                try? input.fileHandleForWriting.close()
                inputOpen = false
            }

            var descriptors: [pollfd] = []
            if inputOpen { descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)) }
            if outputOpen { descriptors.append(pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)) }
            if errorOpen { descriptors.append(pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)) }
            let pollResult = poll(&descriptors, nfds_t(descriptors.count), 100)
            if pollResult < 0 {
                if errno == EINTR { continue }
                streamError = CodexRunnerError.pipe(String(cString: strerror(errno)))
                cancel()
                continue
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                if descriptor.fd == inputFD {
                    let written = inputData.withUnsafeBytes { bytes -> Int in
                        Darwin.write(inputFD, bytes.baseAddress!.advanced(by: inputOffset),
                                     min(inputData.count - inputOffset, 16_384))
                    }
                    if written > 0 {
                        inputOffset += written
                    } else if written < 0, errno != EAGAIN, errno != EINTR {
                        try? input.fileHandleForWriting.close()
                        inputOpen = false
                    }
                    continue
                }
                // Read a bounded amount per iteration so a noisy pipe cannot
                // starve stderr, prompt delivery, or cancellation checks.
                for _ in 0..<16 {
                    var bytes = [UInt8](repeating: 0, count: 16_384)
                    let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                    if count > 0 {
                        let data = Data(bytes.prefix(count))
                        if descriptor.fd == outputFD {
                            consumeOutput(data)
                        } else {
                            errorTail.append(data)
                            if errorTail.count > 6_000 { errorTail = Data(errorTail.suffix(6_000)) }
                        }
                    } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                        if descriptor.fd == outputFD { outputOpen = false } else { errorOpen = false }
                        break
                    } else {
                        break
                    }
                }
            }
        }
        process.waitUntilExit()
        if !outputBuffer.isEmpty { consumeLine(outputBuffer) }
        if let streamError { throw streamError }
        if isCancelled { throw CancellationError() }
        let exitCode = process.terminationStatus
        if exitCode != 0 || turnFailed {
            let stderr = String(decoding: errorTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnosticTail = stderr.isEmpty ? nil : String(stderr.suffix(failure == nil ? 6_000 : 3_900))
            let details = [failure.map { String($0.prefix(2_000)) }, diagnosticTail]
                .compactMap { $0 }.joined(separator: "\n")
            throw CodexRunnerError.failed(
                exitCode: exitCode,
                message: details.isEmpty ? "No error details were returned." : details
            )
        }
        return CodexRunResult(sessionID: sessionID, answer: answer, exitCode: exitCode)
    }
}
