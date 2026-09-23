// Opt-in live integration check. Receives only fixed synthetic audio fixtures.
// Run with script/test_speech_live.sh --live; no microphone or desktop input.
// Add --vocabulary-ab for paired app-name context checks, or --filter FIXTURE_ID.
// --endpoints checks two utterances in one Soniox stream without Jev requests.
// Offline configuration check: .build/qa/speech-live-check --check-config
// A nonexistent VOICECODEX_ENV_FILE must make this check exit 2 before any request.
import AVFoundation
import CryptoKit
import Foundation
import VoiceCodexCore

@main
struct SpeechLiveCheck {
    private struct Scenario {
        let id: String
        let phrase: String
        let target: String
        let intent: MacIntent
        let current: String
        let acceptedText: [String]
        let acceptedAppMentions: [String]

        init(id: String, phrase: String, target: String, intent: MacIntent = .openApp,
             current: String = "com.apple.finder", acceptedText: [String] = [], acceptedAppMentions: [String] = []) {
            self.id = id
            self.phrase = phrase
            self.target = target
            self.intent = intent
            self.current = current
            self.acceptedText = acceptedText
            self.acceptedAppMentions = acceptedAppMentions
        }

        var expected: String {
            "\(intent.rawValue) → \(target)" +
                (acceptedText.isEmpty ? "" : " text∈\(acceptedText.map(\.debugDescription).joined(separator: " | "))")
        }
    }

    private struct Result: Codable {
        let id: String
        let arm: String
        let phrase: String
        let transcript: String?
        let confirmedFinalCallback: Bool
        let appNameRecognized: Bool?
        let planMatched: Bool
        let passed: Bool
        let audioSHA256: String
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
        let applicationCount: Int
        let vocabularyIncludedApplications: Int?
        let vocabularyOmittedApplications: Int?
        let arms: [ArmSummary]
        let skippedScenarioIDs: [String]
        let passed: Int
        let total: Int
        let results: [Result]
    }

    private struct Arm {
        let id: String
        let context: [String: Any]?

        var termCount: Int { (context?["terms"] as? [String])?.count ?? legacyTerms.count }
        var contextBytes: Int {
            let value = context ?? ["terms": legacyTerms]
            return (try? JSONSerialization.data(withJSONObject: value).count) ?? 0
        }
    }

    private struct ArmSummary: Codable {
        let id: String
        let termCount: Int
        let contextUTF8Bytes: Int
        let finalTranscripts: Int
        let recognizedAppNames: Int
        let correctPlans: Int
        let passed: Int
        let total: Int
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
        var sha256: String {
            var digest = SHA256()
            for chunk in chunks { digest.update(data: chunk) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct UtteranceObservation: Codable {
        let text: String
        let milliseconds: Int
        let beforeEOF: Bool
    }

    private struct EndpointReport: Codable {
        let generatedAt: String
        let scope: String
        let sonioxModel: String
        let expectedUtterances: [String]
        let utterances: [UtteranceObservation]
        let finalTranscript: String?
        let finalCallbacks: [String]
        let firstUtteranceBeforeEOF: Bool
        let utterancesDeliveredExactlyOnce: Bool
        let fullTranscriptHasNoDuplicates: Bool
        let repeatedFinishPreservedResult: Bool
        let passed: Bool
        let error: String?
    }

    private enum HarnessFailure: Error {
        case setup, invalidAudio, queueOverflow, speechTimeout
    }

    // Freeze the historical baseline independently of future production defaults.
    private static let legacyTerms = ["Codex", "GitHub", "README", "worktree", "Swift", "Persom"]

    private static let scenarios: [Scenario] = [
        .init(id: "en-calculator", phrase: "Open Calculator", target: "com.apple.calculator"),
        .init(id: "en-chrome", phrase: "Open Google Chrome", target: "com.google.Chrome"),
        .init(id: "zh-calculator", phrase: "打开计算器", target: "com.apple.calculator"),
        // Expected literals are independent of the production parser. Speech does
        // not specify letter case: Soniox has formatted this fixed English clip
        // as "Hello World.". Allow only these explicit casing/terminal-punctuation
        // variants; do not normalize the returned text or promise lowercase output.
        .init(id: "en-type", phrase: "Type hello world", target: "com.apple.TextEdit", intent: .typeText,
              current: "com.apple.TextEdit", acceptedText: ["hello world", "hello world.", "Hello World", "Hello World."]),
        .init(id: "zh-type", phrase: "输入你好世界", target: "com.apple.TextEdit", intent: .typeText,
              current: "com.apple.TextEdit", acceptedText: ["你好世界", "你好世界。", "你好世界."])
    ]
    private static let applications = [
        MacApplication(id: "com.apple.calculator", name: "Calculator"),
        MacApplication(id: "com.google.Chrome", name: "Google Chrome"),
        MacApplication(id: "com.apple.TextEdit", name: "TextEdit"),
        MacApplication(id: "com.apple.finder", name: "Finder")
    ]

    // Only common public application names are synthesized. Missing applications
    // are skipped; the user's full inventory is never written into the report.
    private static let vocabularyScenarios: [Scenario] = [
        .init(id: "vocab-chrome-en", phrase: "Open Google Chrome", target: "com.google.Chrome", acceptedAppMentions: ["Chrome", "谷歌浏览器"]),
        .init(id: "vocab-chrome-mixed", phrase: "打开 Chrome", target: "com.google.Chrome", acceptedAppMentions: ["Chrome", "谷歌浏览器"]),
        .init(id: "vocab-notes-en", phrase: "Open Apple Notes", target: "com.apple.Notes", acceptedAppMentions: ["Apple Notes", "Notes", "备忘录"]),
        .init(id: "vocab-notes-zh", phrase: "打开备忘录", target: "com.apple.Notes", acceptedAppMentions: ["Apple Notes", "Notes", "备忘录"]),
        .init(id: "vocab-stickies-en", phrase: "Open Stickies", target: "com.apple.Stickies", acceptedAppMentions: ["Stickies", "便笺", "便签"]),
        .init(id: "vocab-stickies-zh", phrase: "打开便笺", target: "com.apple.Stickies", acceptedAppMentions: ["Stickies", "便笺", "便签"]),
        .init(id: "vocab-vscode-en", phrase: "Open Visual Studio Code", target: "com.microsoft.VSCode", acceptedAppMentions: ["Visual Studio Code", "VS Code"]),
        .init(id: "vocab-vscode-mixed", phrase: "打开 Visual Studio Code", target: "com.microsoft.VSCode", acceptedAppMentions: ["Visual Studio Code", "VS Code"]),
        .init(id: "vocab-feishu-zh", phrase: "打开飞书", target: "com.electron.lark", acceptedAppMentions: ["飞书", "Feishu", "Lark"]),
        .init(id: "vocab-wechat-zh", phrase: "打开微信", target: "com.tencent.xinWeChat", acceptedAppMentions: ["微信", "WeChat"])
    ]

    @MainActor
    static func main() async {
        let checkConfiguration = CommandLine.arguments.contains("--check-config")
        guard CommandLine.arguments.contains("--live") || checkConfiguration else {
            print("Skipped: add --live to send synthetic audio to Soniox and make paid TypeSafe requests.")
            return
        }
        let vocabularyAB = CommandLine.arguments.contains("--vocabulary-ab")
        let endpoints = CommandLine.arguments.contains("--endpoints")
        guard !endpoints || (!vocabularyAB && !CommandLine.arguments.contains("--filter")) else {
            print("--endpoints cannot be combined with --vocabulary-ab or --filter. No requests made.")
            exit(2)
        }
        let filter: String?
        if let index = CommandLine.arguments.firstIndex(of: "--filter") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  (scenarios + vocabularyScenarios).contains(where: { $0.id == CommandLine.arguments[index + 1] }) else {
                print("Unknown synthetic scenario filter. No requests made."); exit(2)
            }
            filter = CommandLine.arguments[index + 1]
        } else { filter = nil }
        let outputName = vocabularyAB ? "speech-vocabulary-ab" : "speech-live"
        let output = URL(fileURLWithPath: ".build/qa/\(outputName)\(filter.map { "-" + $0 } ?? "")-results.json")
        do {
            let credentials = try loadCredentials()
            guard !credentials.soniox.isEmpty, endpoints || !credentials.jev.isEmpty else {
                print(endpoints ? "Missing local SONIOX_API_KEY. No requests made." :
                    "Missing local SONIOX_API_KEY or TYPESAFE_API_KEY. No requests made.")
                exit(2)
            }
            if checkConfiguration {
                print("Local credentials loaded. No requests made.")
                return
            }
            if endpoints {
                let passed = try await runEndpointCheck(credentials: credentials)
                exit(passed ? 0 : 1)
            }
            let inventory = vocabularyAB ? MacControlDriver().applications().filter { $0.id != "com.singularity.voicecodex" } : applications
            let vocabulary = vocabularyAB ? SpeechVocabulary.build(applications: inventory, currentApplicationID: "com.apple.finder") : nil
            let available = vocabularyAB ? vocabularyScenarios.filter { scenario in inventory.contains { $0.id == scenario.target } } : scenarios
            let selected = filter.map { id in available.filter { $0.id == id } } ?? available
            let skipped = vocabularyAB ? vocabularyScenarios.filter { scenario in !inventory.contains { $0.id == scenario.target } }.map(\.id) : []
            guard !selected.isEmpty else { print("No installed application matches the public-name fixtures."); exit(2) }
            let arms: [Arm]
            if let vocabulary {
                var baseline = vocabulary.context
                baseline["terms"] = legacyTerms
                arms = [Arm(id: "legacy-six", context: baseline), Arm(id: "application-vocabulary", context: vocabulary.context)]
                print("A/B: \(selected.count) identical synthetic clips × 2 term sets; \(inventory.count) installed apps; no desktop actions.")
                for arm in arms { print("\(arm.id): \(arm.termCount) terms, \(arm.contextBytes) context bytes") }
            } else { arms = [Arm(id: "default", context: nil)] }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let jev = JevClient(apiKey: credentials.jev, model: credentials.model, session: session)
            var results: [Result] = []
            for (index, scenario) in selected.enumerated() {
                // Decode and convert exactly once, then reuse the same PCM bytes
                // for both arms. Alternate order to reduce sequential order bias.
                let audio = try loadAudio(URL(fileURLWithPath: ".build/qa/speech-live-audio/\(scenario.id).aiff"))
                let orderedArms = index.isMultiple(of: 2) ? arms : Array(arms.reversed())
                for arm in orderedArms {
                    let result = await run(scenario, audio: audio, arm: arm, applications: inventory, credentials: credentials, jev: jev)
                    results.append(result)
                    print("\(result.passed ? "PASS" : "FAIL") \(result.id) [\(result.arm)]: \(result.observed)")
                    fflush(stdout)
                    try save(results, model: credentials.model, applications: inventory.count, vocabulary: vocabulary,
                             arms: arms, skipped: skipped, to: output)
                }
            }
            let passed = results.filter(\.passed).count
            print("Synthetic speech → live Soniox → live Jev: \(passed)/\(results.count) passed.")
            print("Not exercised: microphone hardware, hotkey capture, accessibility or desktop actions.")
            exit(passed == results.count ? 0 : 1)
        } catch {
            // Do not print arbitrary errors, credentials, config contents, or private paths.
            print("Could not read local credentials or synthetic fixtures, or save the test report.")
            exit(2)
        }
    }

    @MainActor
    private static func runEndpointCheck(credentials: Credentials) async throws -> Bool {
        let expected = ["Open Google Chrome", "Open Calculator"]
        let fixtures = try ["en-chrome", "en-calculator"].map {
            try loadAudio(URL(fileURLWithPath: ".build/qa/speech-live-audio/\($0).aiff"))
        }
        let connection = SonioxConnection()
        defer { connection.cancel() }
        let started = Date()
        var eofRequested = false
        var observations: [UtteranceObservation] = []
        var finalCallbacks: [String] = []
        var finalTranscript: String?
        var repeatedFinishPreservedResult = false
        var failure: String?
        connection.onUtterance = { text in
            observations.append(UtteranceObservation(text: text,
                milliseconds: Int(Date().timeIntervalSince(started) * 1_000), beforeEOF: !eofRequested))
        }
        connection.onTranscript = { text, final in if final { finalCallbacks.append(text) } }
        var timedOut = false
        let deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 35_000_000_000) }
            catch { return }
            timedOut = true
            connection.cancel()
        }
        defer { deadline.cancel() }
        do {
            try await connection.start(apiKey: credentials.soniox)
            for (index, audio) in fixtures.enumerated() {
                for chunk in audio.chunks {
                    if timedOut { throw HarnessFailure.speechTimeout }
                    try yield(chunk, into: connection)
                    try await Task.sleep(nanoseconds: UInt64(audio.durationPerChunk * 1_000_000_000))
                }
                // Stream actual zero PCM, rather than merely waiting without
                // audio. The first pause must produce an endpoint before EOF;
                // the short final pause also exercises any successful EOF tail.
                let silenceChunks = index == 0 ? 150 : 8
                for _ in 0..<silenceChunks {
                    if timedOut { throw HarnessFailure.speechTimeout }
                    try yield(Data(repeating: 0, count: 640), into: connection)
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            eofRequested = true
            finalTranscript = try await connection.finish()
            let countBeforeRepeatedFinish = observations.count
            let repeated = try await connection.finish()
            repeatedFinishPreservedResult = repeated == finalTranscript && observations.count == countBeforeRepeatedFinish
        } catch { failure = safeError(error) }
        deadline.cancel()
        let normalizedExpected = expected.map(normalizeAppName)
        let deliveredOnce = observations.map { normalizeAppName($0.text) } == normalizedExpected
        let noDuplicates = finalTranscript.map(normalizeAppName) == normalizedExpected.joined()
        let firstBeforeEOF = observations.first?.beforeEOF == true
        let passed = failure == nil && firstBeforeEOF && deliveredOnce && noDuplicates &&
            repeatedFinishPreservedResult && finalCallbacks.count == 1 && finalCallbacks.first == finalTranscript
        let report = EndpointReport(generatedAt: ISO8601DateFormatter().string(from: Date()),
            scope: "Two fixed synthetic clips separated by three seconds of streamed silence; production PCM encoding and Soniox connection. No microphone, Jev request, hotkey, accessibility or desktop action.",
            sonioxModel: SonioxConnection.model, expectedUtterances: expected, utterances: observations,
            finalTranscript: finalTranscript, finalCallbacks: finalCallbacks, firstUtteranceBeforeEOF: firstBeforeEOF,
            utterancesDeliveredExactlyOnce: deliveredOnce, fullTranscriptHasNoDuplicates: noDuplicates,
            repeatedFinishPreservedResult: repeatedFinishPreservedResult, passed: passed, error: failure)
        let output = URL(fileURLWithPath: ".build/qa/speech-endpoints-results.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("\(passed ? "PASS" : "FAIL") live Soniox endpoints: first before EOF=\(firstBeforeEOF), ordered once=\(deliveredOnce), full transcript once=\(noDuplicates), final callbacks=\(finalCallbacks.count).")
        for observation in observations {
            print("\(observation.milliseconds)ms [\(observation.beforeEOF ? "before EOF" : "finishing")]: \(observation.text)")
        }
        if let failure { print("Endpoint check failed: \(failure)") }
        print("Report: .build/qa/speech-endpoints-results.json. No microphone or desktop actions exercised.")
        return passed
    }

    @MainActor
    private static func run(_ scenario: Scenario, audio: AudioFixture, arm: Arm, applications: [MacApplication],
                            credentials: Credentials, jev: JevClient) async -> Result {
        var transcript: String?
        var finalCallback = false
        var sourceRate: Double?
        var pcmBytes: Int?
        var sttMilliseconds: Int?
        var planMilliseconds: Int?
        var stage = "audio"
        var recognized: Bool?
        let connection = SonioxConnection()
        defer { connection.cancel() }
        do {
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
            try await connection.start(apiKey: credentials.soniox, context: arm.context)
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
            if !scenario.acceptedAppMentions.isEmpty {
                let normalized = normalizeAppName(transcript)
                recognized = scenario.acceptedAppMentions.contains { normalized.contains(normalizeAppName($0)) }
            }
            stage = "planning"
            let planStarted = Date()
            let command = try await jev.plan(transcript: transcript, applications: applications,
                                             currentApplicationID: scenario.current)
            planMilliseconds = Int(Date().timeIntervalSince(planStarted) * 1_000)
            let textMatches = scenario.acceptedText.isEmpty ? command.text == nil :
                command.text.map { scenario.acceptedText.contains($0) } == true
            let planMatched = command.intent == scenario.intent && command.applicationID == scenario.target && textMatches
            let passed = planMatched && recognized != false
            let publicIDs = Set((scenarios + vocabularyScenarios).map(\.target))
            let observedTarget = command.applicationID.map { publicIDs.contains($0) ? $0 : "other installed application" } ?? "none"
            return Result(id: scenario.id, arm: arm.id, phrase: scenario.phrase, transcript: transcript,
                          confirmedFinalCallback: finalCallback, appNameRecognized: recognized, planMatched: planMatched,
                          passed: passed, audioSHA256: audio.sha256, sourceSampleRate: sourceRate,
                          pcmBytes: pcmBytes, transcriptionMilliseconds: sttMilliseconds,
                          planningMilliseconds: planMilliseconds, expected: scenario.expected,
                          observed: "\(command.intent.rawValue) → \(observedTarget)" +
                            (command.text.map { " text=\($0.debugDescription)" } ?? ""),
                          confidence: command.confidence)
        } catch {
            return Result(id: scenario.id, arm: arm.id, phrase: scenario.phrase, transcript: transcript,
                          confirmedFinalCallback: finalCallback, appNameRecognized: recognized, planMatched: false,
                          passed: false, audioSHA256: audio.sha256, sourceSampleRate: sourceRate,
                          pcmBytes: pcmBytes, transcriptionMilliseconds: sttMilliseconds,
                          planningMilliseconds: planMilliseconds, expected: scenario.expected,
                          observed: "\(stage): \(safeError(error))", confidence: nil)
        }
    }

    private static func normalizeAppName(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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
        let explicitPath = environment["VOICECODEX_ENV_FILE"].flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let selectedFile = URL(fileURLWithPath: ((explicitPath ?? ".env") as NSString).expandingTildeInPath)
        // Match LocalConfig: an explicit missing file is a configuration error,
        // never permission to make paid requests using a fallback account.
        if explicitPath != nil, !FileManager.default.fileExists(atPath: selectedFile.path) {
            throw HarnessFailure.setup
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceCodex", isDirectory: true)
        var credentials = Credentials()
        if let data = try? Data(contentsOf: support.appendingPathComponent("config.json")),
           let saved = try? JSONDecoder().decode(SavedCredentials.self, from: data) {
            credentials.apply(["SONIOX_API_KEY": saved.sonioxAPIKey ?? "",
                               "TYPESAFE_API_KEY": saved.jevAPIKey ?? "",
                               "TYPESAFE_DEFAULT_MODEL": saved.jevModel ?? ""])
        }
        let files = [support.appendingPathComponent(".env"), selectedFile]
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
    private static func save(_ results: [Result], model: String, applications: Int, vocabulary: SpeechVocabulary?,
                             arms: [Arm], skipped: [String], to output: URL) throws {
        let summaries = arms.map { arm in
            let rows = results.filter { $0.arm == arm.id }
            return ArmSummary(id: arm.id, termCount: arm.termCount, contextUTF8Bytes: arm.contextBytes,
                              finalTranscripts: rows.filter(\.confirmedFinalCallback).count,
                              recognizedAppNames: rows.filter { $0.appNameRecognized == true }.count,
                              correctPlans: rows.filter(\.planMatched).count,
                              passed: rows.filter(\.passed).count, total: rows.count)
        }
        let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()),
                            scope: "Synthetic macOS say audio; production PCM encoding and Soniox finalization; live Jev planning. " +
                                (vocabulary == nil ? "" : "Vocabulary A/B uses identical PCM and the same general context, changing only legacy-six versus application terms. ") +
                                "No microphone, hotkey, AX or desktop execution; no claim of real microphone accuracy.",
                            sonioxModel: SonioxConnection.model, jevModel: model,
                            applicationCount: applications, vocabularyIncludedApplications: vocabulary?.includedApplicationCount,
                            vocabularyOmittedApplications: vocabulary?.omittedApplicationCount, arms: summaries, skippedScenarioIDs: skipped,
                            passed: results.filter(\.passed).count, total: results.count, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try encoder.encode(report).write(to: output, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}
