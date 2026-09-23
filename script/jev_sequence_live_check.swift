// Opt-in real TypeSafe sequence planning; never performs desktop actions.
// swiftc Sources/VoiceCodexCore/EnvironmentFile.swift Sources/VoiceCodexCore/MacCommand.swift \
//   Sources/VoiceCodexCore/MacCommandSequence.swift Sources/VoiceCodexCore/SpeechVocabulary.swift \
//   Sources/VoiceCodexCore/JevClient.swift script/jev_sequence_live_check.swift -o .build/jev-sequence-live-check
// .build/jev-sequence-live-check --live [--filter case-id] [--output .build/qa/jev-sequence-results.json]
import Foundation

@main
struct JevSequenceLiveCheck {
    private struct Expected {
        let intent: MacIntent
        let app: String
        var text: String? = nil
    }
    private struct SequenceCase {
        let id: String
        let transcript: String
        let current: String
        let expected: [Expected]
    }
    private struct ControlCase {
        let id: String
        let goal: String
        let controls: [String: String]
        let expected: String?
        var labelPrefix = "AXButton · "
    }
    private struct Result: Codable {
        let id: String
        let kind: String
        let transcript: String
        let steps: [String]
        let expected: [String]
        let observed: [String]
        let confidence: [Double]
        let decisions: [String]
        let passed: Bool
        let latencyMilliseconds: Int
    }
    private struct Report: Codable {
        let generatedAt: String
        let model: String
        let scope: String
        let passed: Int
        let total: Int
        let results: [Result]
    }

    private static let meeting = "com.tencent.meeting"
    private static let chrome = "com.google.Chrome"
    private static let editor = "com.apple.TextEdit"
    // Public fixed descriptors. Tencent Meeting's installed bundle ID was
    // verified from its Info.plist; no windows or desktop state are inspected.
    private static let apps = [
        MacApplication(id: meeting, name: "TencentMeeting"),
        MacApplication(id: chrome, name: "Google Chrome"),
        MacApplication(id: editor, name: "TextEdit"),
        MacApplication(id: "com.apple.Stickies", name: "Stickies"),
        MacApplication(id: "com.apple.calculator", name: "Calculator"),
        MacApplication(id: "com.apple.finder", name: "Finder"),
        MacApplication(id: "com.apple.systempreferences", name: "System Settings")
    ]
    private static let sequences: [SequenceCase] = [
        .init(id: "tencent-user-zh", transcript: "你可以打开腾讯会议，然后创建一个新的会议吗？", current: editor,
              expected: [.init(intent: .openApp, app: meeting), .init(intent: .clickElement, app: meeting)]),
        .init(id: "tencent-en", transcript: "Can you open Tencent Meeting and then create a new meeting?", current: editor,
              expected: [.init(intent: .openApp, app: meeting), .init(intent: .clickElement, app: meeting)]),
        .init(id: "chrome-tab-zh", transcript: "打开 Chrome，然后新建一个标签页", current: editor,
              expected: [.init(intent: .openApp, app: chrome), .init(intent: .newTab, app: chrome)]),
        .init(id: "chrome-tab-en", transcript: "Open Google Chrome then open a new tab", current: editor,
              expected: [.init(intent: .openApp, app: chrome), .init(intent: .newTab, app: chrome)]),
        .init(id: "literal-return-zh", transcript: "输入「hello 然后回车」然后按回车", current: editor,
              expected: [.init(intent: .typeText, app: editor, text: "hello 然后回车"), .init(intent: .pressReturn, app: editor)]),
        .init(id: "literal-return-en", transcript: "Type \"then open Chrome\" then press Return", current: editor,
              expected: [.init(intent: .typeText, app: editor, text: "then open Chrome"), .init(intent: .pressReturn, app: editor)]),
        .init(id: "streamed-continuation-zh", transcript: "然后创建一个新的会议。", current: meeting,
              expected: [.init(intent: .clickElement, app: meeting)])
    ]
    private static let controls: [ControlCase] = [
        .init(id: "control-new-zh", goal: "创建一个新的会议", controls: ["quick": "快速会议", "join": "加入会议", "schedule": "预定会议"], expected: "quick"),
        .init(id: "control-new-en", goal: "Create a new meeting", controls: ["new": "New Meeting", "join": "Join Meeting", "schedule": "Schedule Meeting"], expected: "new"),
        .init(id: "control-join-zh", goal: "加入会议", controls: ["quick": "快速会议", "join": "加入会议", "schedule": "预定会议"], expected: "join"),
        .init(id: "control-schedule-en", goal: "Schedule a meeting for later", controls: ["new": "New Meeting", "join": "Join Meeting", "schedule": "Schedule Meeting"], expected: "schedule"),
        .init(id: "control-new-absent", goal: "Create a new meeting now", controls: ["join": "Join Meeting", "schedule": "Schedule Meeting for Later"], expected: nil),
        .init(id: "control-new-ocr-zh", goal: "创建一个新的会议", controls: [
            "quick": "快速会议丶", "schedule": "预定会议丶", "join": "加入会议", "recorder": "录音笔",
            "date": "9月23日", "share": "共享屏幕", "none-scheduled": "暂无会议", "all-meetings": "全部会议〉",
            "meetings": "会议", "contacts": "通讯承", "recording": "决制", "device": "iPhone 已登录•未入会"
        ], expected: "quick", labelPrefix: "屏幕文字 · ")
    ]

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--live") else {
            print("Usage: jev-sequence-live-check --live [--filter case-id] [--output path]")
            print("Uses real TypeSafe requests with synthetic commands and controls; no desktop actions.")
            exit(2)
        }
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let filter = argument("--filter")
        let selectedSequences = sequences.filter { filter == nil || $0.id.contains(filter!) }
        let selectedControls = controls.filter { filter == nil || $0.id.contains(filter!) }
        guard !selectedSequences.isEmpty || !selectedControls.isEmpty else { print("No matching fixture."); exit(2) }
        let output = URL(fileURLWithPath: argument("--output") ?? ".build/qa/jev-sequence-results.json")
        do {
            let envURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceCodex/.env")
            let values = try EnvironmentFile.parse(String(contentsOf: envURL, encoding: .utf8))
            guard let key = values["TYPESAFE_API_KEY"], !key.isEmpty else { print("Missing local TypeSafe key."); exit(2) }
            let model = values["TYPESAFE_DEFAULT_MODEL"] ?? "jev-1.13.0"
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SequenceDecisionRecorder.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let client = JevClient(apiKey: key, model: model, session: session)
            var results: [Result] = []
            for scenario in selectedSequences {
                let started = Date()
                SequenceDecisionRecorder.reset()
                var steps: [String] = []
                var observed: [String] = []
                var confidences: [Double] = []
                var passed = true
                do {
                    steps = try MacCommandSequence.parse(scenario.transcript)
                    passed = steps.count == scenario.expected.count
                    var target = scenario.current
                    for (index, step) in steps.enumerated() where passed {
                        let command = try await client.plan(transcript: step, applications: apps, currentApplicationID: target)
                        observed.append(describe(command.intent, app: command.applicationID, text: command.text))
                        confidences.append(command.confidence)
                        let expected = scenario.expected[index]
                        passed = command.intent == expected.intent && command.applicationID == expected.app && command.text == expected.text
                        // This is planned target propagation only, not evidence
                        // that an application was opened or activated.
                        if let next = command.applicationID { target = next }
                    }
                } catch {
                    observed.append(safeError(error))
                    passed = false
                }
                let result = Result(id: scenario.id, kind: "sequence-planner", transcript: scenario.transcript,
                                    steps: steps, expected: scenario.expected.map { describe($0.intent, app: $0.app, text: $0.text) },
                                    observed: observed, confidence: confidences, decisions: SequenceDecisionRecorder.snapshot(),
                                    passed: passed, latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000))
                results.append(result)
                printResult(result)
                try save(results, model: model, to: output)
            }
            for scenario in selectedControls {
                let started = Date()
                SequenceDecisionRecorder.reset()
                let observed: String
                let passed: Bool
                do {
                    // Match MacControlDriver.controlLabel: observed AX role,
                    // then title (these fixtures have no extra description).
                    let labels = scenario.controls.mapValues { scenario.labelPrefix + $0 }
                    let control = try await client.chooseElement(goal: scenario.goal, elements: labels)
                    observed = control
                    passed = control == scenario.expected
                } catch {
                    observed = safeError(error)
                    if let error = error as? JevClientError {
                        switch error {
                        case .unsupportedCommand, .lowConfidence: passed = scenario.expected == nil
                        default: passed = false
                        }
                    } else { passed = false }
                }
                let result = Result(id: scenario.id, kind: "synthetic-control-choice", transcript: scenario.goal,
                                    steps: [], expected: [scenario.expected ?? "No control"], observed: [observed], confidence: [],
                                    decisions: SequenceDecisionRecorder.snapshot(), passed: passed,
                                    latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000))
                results.append(result)
                printResult(result)
                try save(results, model: model, to: output)
            }
            let passed = results.filter(\.passed).count
            print("\(passed)/\(results.count) planner/fixture cases passed. No apps, tabs, or meetings were created.")
            exit(passed == results.count ? 0 : 1)
        } catch {
            print("Could not load local configuration or save results.")
            exit(2)
        }
    }

    private static func describe(_ intent: MacIntent, app: String?, text: String?) -> String {
        intent.rawValue + " → " + (app ?? "none") + (text.map { " text=\($0.debugDescription)" } ?? "")
    }
    private static func printResult(_ result: Result) {
        print("\(result.passed ? "PASS" : "FAIL") \(result.id) [\(result.latencyMilliseconds) ms]: \(result.observed.joined(separator: "; "))")
        print("  " + result.decisions.joined(separator: "; "))
        fflush(stdout)
    }
    private static func save(_ results: [Result], model: String, to output: URL) throws {
        let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()), model: model,
                            scope: "Actual TypeSafe HTTP on fixed public app descriptors and synthetic controls; target propagation is simulated; no OS actions or evidence of meeting creation",
                            passed: results.filter(\.passed).count, total: results.count, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
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
        if error is MacCommandSequenceError { return "invalidSequence" }
        return "unexpectedFailure"
    }
}

/// Only numeric confidence and fixed choice IDs are retained. No keys, request
/// bodies, full responses, or arbitrary transport diagnostics enter the report.
private final class SequenceDecisionRecorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var records: [String] = []
    private var forwardingTask: URLSessionDataTask?
    static func reset() { lock.lock(); defer { lock.unlock() }; records = [] }
    static func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return records }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        forwardingTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = object["answers"] as? [String: [String: Any]] {
                var decisions: [String] = []
                for name in ["action", "application", "element"] {
                    guard let answer = answers[name], let confidence = answer["confidence"] as? Double else { continue }
                    let choice = answer["choice"] as? String ?? ""
                    let allowed = MacIntent(rawValue: choice) != nil || ["none", "current"].contains(choice) ||
                        choice.range(of: #"^(app|group|element)_[0-9]+$"#, options: .regularExpression) != nil
                    decisions.append("\(name)=\(allowed ? choice : "unknown") confidence=\(confidence)")
                }
                Self.lock.lock()
                Self.records.append(contentsOf: decisions)
                Self.lock.unlock()
            }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardingTask?.resume()
    }
    override func stopLoading() { forwardingTask?.cancel() }
}
