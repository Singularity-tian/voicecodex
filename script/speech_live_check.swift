// Opt-in live integration check. Receives only fixed synthetic audio fixtures.
// Run with script/test_speech_live.sh --live; no microphone or desktop input.
import AVFoundation
import Foundation

@main
struct SpeechLiveCheck {
    private struct Scenario {
        let id: String
        let phrase: String
        let target: String
    }

    private struct Result: Codable {
        let id: String
        let phrase: String
        let transcript: String?
        let confirmedFinalCallback: Bool
        let passed: Bool
        let sourceSampleRate: Double?
        let pcmBytes: Int?
        let transcriptionMilliseconds: Int?
        let planningMilliseconds: Int?
        let expected: String
        let observed: String
        let confidence: Double?
    }

    private struct Report: Codable {
        let generatedAt: String
        let scope: String
        let sonioxModel: String
        let jevModel: String
        let passed: Int
        let total: Int
        let results: [Result]
    }

    private struct Credentials {
        var soniox: String = ""
        var jev: String = ""
        var model: String = "jev-1.13.0"

        mutating func apply(_ values: [String: String]) {
            func nonblank(_ value: String?) -> String? {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            if let value = nonblank(values["SONIOX_API_KEY"]) { soniox = value }
            if let value = nonblank(values["TYPESAFE_API_KEY"]) { jev = value }
            if let value = nonblank(values["TYPESAFE_DEFAULT_MODEL"]) { model = value }
        }
    }

    private struct AudioFixture {
        let sampleRate: Double
        let chunks: [Data]
        let durationPerChunk: Double
        var byteCount: Int { chunks.reduce(0) { $0 + $1.count } }
    }

    private enum HarnessFailure: Error {
        case setup, invalidAudio, queueOverflow, speechTimeout
    }

    private static let scenarios: [Scenario] = [
        .init(id: "en-calculator", phrase: "Open Calculator", target: "com.apple.calculator"),
        .init(id: "en-chrome", phrase: "Open Google Chrome", target: "com.google.Chrome"),
        .init(id: "zh-calculator", phrase: "打开计算器", target: "com.apple.calculator")
    ]
    private static let applications = [
        MacApplication(id: "com.apple.calculator", name: "Calculator"),
        MacApplication(id: "com.google.Chrome", name: "Google Chrome"),
        MacApplication(id: "com.apple.TextEdit", name: "TextEdit"),
        MacApplication(id: "com.apple.finder", name: "Finder")
    ]

    @MainActor
    static func main() async {
        guard CommandLine.arguments.contains("--live") else {
            print("Skipped: add --live to send synthetic audio to Soniox and make paid TypeSafe requests.")
            return
        }
        let output = URL(fileURLWithPath: ".build/qa/speech-live-results.json")
        do {
            let credentials = try loadCredentials()
            guard !credentials.soniox.isEmpty, !credentials.jev.isEmpty else {
                print("Missing local SONIOX_API_KEY or TYPESAFE_API_KEY. No requests made.")
                exit(2)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let jev = JevClient(apiKey: credentials.jev, model: credentials.model, session: session)
            var results: [Result] = []
            for scenario in scenarios {
                let result = await run(scenario, credentials: credentials, jev: jev)
                results.append(result)
                print("\(result.passed ? "PASS" : "FAIL") \(result.id): \(result.observed)")
                fflush(stdout)
                try save(results, model: credentials.model, to: output)
            }
            let passed = results.filter(\.passed).count
            print("Synthetic speech → live Soniox → live Jev: \(passed)/\(results.count) passed.")
            print("Not exercised: microphone hardware, hotkey capture, accessibility or desktop actions.")
            exit(passed == results.count ? 0 : 1)
        } catch {
            // Do not print arbitrary errors, credentials, config contents, or private paths.
            print("Could not read the local credentials or save the synthetic test report.")
            exit(2)
        }
    }

    @MainActor
    private static func run(_ scenario: Scenario, credentials: Credentials, jev: JevClient) async -> Result {
        var transcript: String?
        var finalCallback = false
        var sourceRate: Double?
        var pcmBytes: Int?
        var sttMilliseconds: Int?
        var planMilliseconds: Int?
        var stage = "audio"
        let connection = SonioxConnection()
        defer { connection.cancel() }
        do {
            let audioURL = URL(fileURLWithPath: ".build/qa/speech-live-audio/\(scenario.id).aiff")
            let audio = try loadAudio(audioURL)
            sourceRate = audio.sampleRate
            pcmBytes = audio.byteCount
            connection.onTranscript = { _, final in if final { finalCallback = true } }
            stage = "transcription"
            let started = Date()
            var timedOut = false
            let deadline = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 35_000_000_000) }
                catch { return }
                timedOut = true
                connection.cancel()
            }
            defer { deadline.cancel() }
            // Exercise buffers captured while the production WebSocket is connecting.
            let prebuffered = min(3, audio.chunks.count)
            for chunk in audio.chunks.prefix(prebuffered) { try yield(chunk, into: connection) }
            try await connection.start(apiKey: credentials.soniox)
            for chunk in audio.chunks.dropFirst(prebuffered) {
                if timedOut { throw HarnessFailure.speechTimeout }
                try Task.checkCancellation()
                try yield(chunk, into: connection)
                try await Task.sleep(nanoseconds: UInt64(audio.durationPerChunk * 1_000_000_000))
            }
            // Production finish drains queued chunks, sends the real EOF marker,
            // and waits for final tokens plus Soniox's finished=true response.
            transcript = try await connection.finish()
            deadline.cancel()
            sttMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            guard let transcript, !transcript.isEmpty, finalCallback else { throw HarnessFailure.invalidAudio }
            stage = "planning"
            let planStarted = Date()
            let command = try await jev.plan(transcript: transcript, applications: applications,
                                             currentApplicationID: "com.apple.finder")
            planMilliseconds = Int(Date().timeIntervalSince(planStarted) * 1_000)
            let passed = command.intent == .openApp && command.applicationID == scenario.target && command.text == nil
            return Result(id: scenario.id, phrase: scenario.phrase, transcript: transcript,
                          confirmedFinalCallback: finalCallback, passed: passed, sourceSampleRate: sourceRate,
                          pcmBytes: pcmBytes, transcriptionMilliseconds: sttMilliseconds,
                          planningMilliseconds: planMilliseconds, expected: "openApp → \(scenario.target)",
                          observed: "\(command.intent.rawValue) → \(command.applicationID ?? "none")",
                          confidence: command.confidence)
        } catch {
            return Result(id: scenario.id, phrase: scenario.phrase, transcript: transcript,
                          confirmedFinalCallback: finalCallback, passed: false, sourceSampleRate: sourceRate,
                          pcmBytes: pcmBytes, transcriptionMilliseconds: sttMilliseconds,
                          planningMilliseconds: planMilliseconds, expected: "openApp → \(scenario.target)",
                          observed: "\(stage): \(safeError(error))", confidence: nil)
        }
    }

    @MainActor
    private static func yield(_ data: Data, into connection: SonioxConnection) throws {
        switch connection.audioSink.yield(data) {
        case .enqueued: return
        case .dropped: throw HarnessFailure.queueOverflow
        case .terminated: throw CancellationError()
        @unknown default: throw HarnessFailure.queueOverflow
        }
    }

    private static func loadAudio(_ url: URL) throws -> AudioFixture {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0, Double(file.length) / rate <= 20,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 960) else {
            throw HarnessFailure.invalidAudio
        }
        var chunks: [Data] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 960)
            guard let (pcm, _) = SpeechMicrophone.encode(buffer), !pcm.isEmpty else {
                throw HarnessFailure.invalidAudio
            }
            chunks.append(pcm)
        }
        return AudioFixture(sampleRate: rate, chunks: chunks, durationPerChunk: 960 / rate)
    }

    private static func loadCredentials() throws -> Credentials {
        struct SavedCredentials: Decodable {
            let sonioxAPIKey: String?
            let jevAPIKey: String?
            let jevModel: String?
        }
        let environment = ProcessInfo.processInfo.environment
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceCodex", isDirectory: true)
        var credentials = Credentials()
        if let data = try? Data(contentsOf: support.appendingPathComponent("config.json")),
           let saved = try? JSONDecoder().decode(SavedCredentials.self, from: data) {
            credentials.apply(["SONIOX_API_KEY": saved.sonioxAPIKey ?? "",
                               "TYPESAFE_API_KEY": saved.jevAPIKey ?? "",
                               "TYPESAFE_DEFAULT_MODEL": saved.jevModel ?? ""])
        }
        let selected = environment["VOICECODEX_ENV_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? ".env"
        let files = [support.appendingPathComponent(".env"),
                     URL(fileURLWithPath: (selected as NSString).expandingTildeInPath)]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            credentials.apply(try EnvironmentFile.parse(String(contentsOf: file, encoding: .utf8)))
        }
        credentials.apply(environment)
        return credentials
    }

    private static func safeError(_ error: Error) -> String {
        if let error = error as? JevClientError {
            switch error {
            case .missingKey: return "missingKey"
            case .invalidInput: return "invalidInput"
            case .invalidResponse: return "invalidResponse"
            case .lowConfidence(let confidence): return "lowConfidence(\(confidence))"
            case .literalTextRequired: return "literalTextRequired"
            case .unsupportedCommand: return "unsupportedCommand"
            case .requestFailed(let code): return "httpStatus(\(code))"
            case .networkUnavailable: return "networkUnavailable"
            }
        }
        if let error = error as? SpeechFailure { return error.localizedDescription }
        if error is CancellationError { return "cancelled or timed out" }
        if error is HarnessFailure { return "fixture, stream queue, or timeout failure" }
        return "audio or network failure"
    }

    @MainActor
    private static func save(_ results: [Result], model: String, to output: URL) throws {
        let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()),
                            scope: "Synthetic macOS say audio; production PCM encoding and Soniox WebSocket finalization; live Jev planning. No microphone, hotkey, AX or desktop execution.",
                            sonioxModel: SonioxConnection.model, jevModel: model,
                            passed: results.filter(\.passed).count, total: results.count, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try encoder.encode(report).write(to: output, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}
