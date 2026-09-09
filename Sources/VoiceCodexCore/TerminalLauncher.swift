import Foundation
import Darwin

public struct TerminalLaunchFiles: Sendable {
    public let directoryURL: URL
    public let commandURL: URL
    public let promptURL: URL
    /// Written when the launch shell starts: its decimal PID and a newline.
    public let startedURL: URL
    /// Written on shell exit: the decimal exit status and a newline.
    public let exitedURL: URL
}

public enum TerminalLauncher {
    public enum LaunchError: LocalizedError {
        case invalidPath
        case invalidRemoteAddress
        case invalidSessionID
        case invalidPrompt

        public var errorDescription: String? {
            switch self {
            case .invalidPath: return "终端启动需要有效的本地文件路径。"
            case .invalidRemoteAddress: return "终端只能连接本机 Codex 服务。"
            case .invalidSessionID: return "Codex 会话 ID 必须是有效 UUID。"
            case .invalidPrompt: return "语音文字包含终端无法传递的空字符。"
            }
        }
    }

    /// Prepares an executable .command file for opening in Terminal. This method
    /// never opens Terminal or changes its existing windows. Prompt text remains
    /// in a private file until the shell reads it into one literal CLI argument.
    public static func prepare(
        executableURL: URL,
        workspaceURL: URL,
        remoteAddress: String,
        authTokenFileURL: URL? = nil,
        prompt: String? = nil,
        sessionID: String? = nil,
        storageURL: URL
    ) throws -> TerminalLaunchFiles {
        for url in [executableURL, workspaceURL, storageURL] + [authTokenFileURL].compactMap({ $0 }) {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
                throw LaunchError.invalidPath
            }
        }
        guard validRemoteAddress(remoteAddress) else { throw LaunchError.invalidRemoteAddress }
        if let sessionID, UUID(uuidString: sessionID) == nil { throw LaunchError.invalidSessionID }
        if let prompt, prompt.contains("\0") { throw LaunchError.invalidPrompt }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let directory = storageURL.appendingPathComponent("terminal-\(UUID().uuidString.lowercased())", isDirectory: true)
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let files = TerminalLaunchFiles(
            directoryURL: directory,
            commandURL: directory.appendingPathComponent("VoiceCodex.command"),
            promptURL: directory.appendingPathComponent("prompt.txt"),
            startedURL: directory.appendingPathComponent("started"),
            exitedURL: directory.appendingPathComponent("exited")
        )
        do {
            try writePrivate(Data((prompt ?? "").utf8), to: files.promptURL, mode: 0o600)
            let command = script(executableURL: executableURL, workspaceURL: workspaceURL,
                                 remoteAddress: remoteAddress, authTokenFileURL: authTokenFileURL,
                                 hasPrompt: prompt != nil, sessionID: sessionID, files: files)
            try writePrivate(Data(command.utf8), to: files.commandURL, mode: 0o700)
            return files
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func validRemoteAddress(_ address: String) -> Bool {
        guard !address.contains("\0"), !address.contains("\n"), !address.contains("\r") else { return false }
        if address.hasPrefix("unix:///") {
            return address.count > "unix:///".count
        }
        guard let components = URLComponents(string: address),
              components.scheme == "ws", components.host == "127.0.0.1",
              let port = components.port, (1...65535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return false }
        return true
    }

    private static func script(
        executableURL: URL, workspaceURL: URL, remoteAddress: String,
        authTokenFileURL: URL?, hasPrompt: Bool, sessionID: String?, files: TerminalLaunchFiles
    ) -> String {
        var arguments = [quote(executableURL.path), "--remote", quote(remoteAddress),
                         "-C", quote(workspaceURL.path), "--no-alt-screen",
                         "-a", "on-request", "--sandbox", "workspace-write"]
        if authTokenFileURL != nil {
            arguments += ["--remote-auth-token-env", "VOICECODEX_REMOTE_TOKEN"]
        }
        if let sessionID { arguments += ["resume", quote(sessionID)] }
        if hasPrompt { arguments += ["--", "\"$voicecodex_prompt\""] }

        var script = """
        #!/bin/bash
        set -eu
        umask 077
        voicecodex_prompt_file=\(quote(files.promptURL.path))
        voicecodex_started_file=\(quote(files.startedURL.path))
        voicecodex_exited_file=\(quote(files.exitedURL.path))
        voicecodex_finish() {
          voicecodex_status=$?
          trap - EXIT HUP INT TERM
          /bin/rm -f -- "$voicecodex_prompt_file"
          printf '%s\\n' "$voicecodex_status" > "$voicecodex_exited_file"
          exit "$voicecodex_status"
        }
        trap voicecodex_finish EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        printf '%s\\n' "$$" > "$voicecodex_started_file"
        unset SONIOX_API_KEY
        """
        if let authTokenFileURL {
            script += """

            voicecodex_token_file=\(quote(authTokenFileURL.path))
            voicecodex_token="$(/bin/cat -- "$voicecodex_token_file" && printf '.')"
            export VOICECODEX_REMOTE_TOKEN="${voicecodex_token%.}"
            unset voicecodex_token
            """
        }
        if hasPrompt {
            // A trailing sentinel prevents command substitution from discarding
            // any final newlines. The file contents are data, never shell source.
            script += """

            voicecodex_prompt="$(/bin/cat -- "$voicecodex_prompt_file" && printf '.')"
            voicecodex_prompt="${voicecodex_prompt%.}"
            """
        }
        script += """

        /bin/rm -f -- "$voicecodex_prompt_file"
        cd -- \(quote(workspaceURL.path))
        \(arguments.joined(separator: " "))

        """
        return script
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func writePrivate(_ data: Data, to url: URL, mode: mode_t) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fchmod(descriptor, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try handle.write(contentsOf: data)
    }
}
