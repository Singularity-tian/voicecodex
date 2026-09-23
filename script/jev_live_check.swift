// Read-only live planner regression check. Requires an explicit --live flag.
// Compile from the repository root (no package import or desktop automation):
// swiftc Sources/VoiceCodexCore/EnvironmentFile.swift Sources/VoiceCodexCore/MacCommand.swift \
//   Sources/VoiceCodexCore/JevClient.swift script/jev_live_check.swift -o .build/jev-live-check
// .build/jev-live-check --live [--installed-apps] [--filter case-id] [--output .build/qa/jev-live-results.json]
import Foundation
import AppKit

@main
struct JevLiveCheck {
    private struct Scenario {
        let id: String
        let transcript: String
        let current: String?
        let intent: MacIntent?
        let target: String?
        let text: String?

        init(_ id: String, _ transcript: String, current: String? = editor,
             intent: MacIntent? = nil, target: String? = nil, text: String? = nil) {
            self.id = id
            self.transcript = transcript
            self.current = current
            self.intent = intent
            self.target = target
            self.text = text
        }
    }

    private struct Result: Codable {
        let id: String
        let transcript: String
        let passed: Bool
        let latencyMilliseconds: Int
        let expected: String
        let observed: String
        let confidence: Double?
        let decisions: [String]
    }

    private struct Report: Codable {
        let generatedAt: String
        let model: String
        let scope: String
        let applicationCount: Int
        let passed: Int
        let total: Int
        let results: [Result]
    }

    private static let chrome = "com.google.Chrome"
    private static let calculator = "com.apple.calculator"
    private static let stickies = "com.apple.Stickies"
    private static let editor = "com.apple.TextEdit"
    private static let finder = "com.apple.finder"
    private static let settings = "com.apple.systempreferences"
    private static let apps = [
        MacApplication(id: chrome, name: "Google Chrome"),
        MacApplication(id: calculator, name: "Calculator"),
        MacApplication(id: stickies, name: "Stickies"),
        MacApplication(id: editor, name: "TextEdit"),
        MacApplication(id: finder, name: "Finder"),
        MacApplication(id: settings, name: "System Settings")
    ]

    private static let scenarios: [Scenario] = [
        .init("open-calculator-zh", "打开计算器", intent: .openApp, target: calculator),
        .init("open-chrome-en", "Open Google Chrome", intent: .openApp, target: chrome),
        .init("open-chrome-quoted", "Open \"Chrome\"", intent: .openApp, target: chrome),
        .init("open-stickies-zh", "打开便笺", intent: .openApp, target: stickies),
        .init("open-editor-zh", "打开文本编辑", current: finder, intent: .openApp, target: editor),
        .init("open-settings-zh", "打开系统设置", intent: .openApp, target: settings),
        .init("current-newtab-zh", "新建一个标签页", current: chrome, intent: .newTab, target: chrome),
        .init("named-newtab-en", "Open a new tab in Chrome", current: finder, intent: .newTab, target: chrome),
        .init("newwindow-stickies-zh", "在便笺里新建一个窗口", intent: .newWindow, target: stickies),
        .init("newwindow-finder-en", "Open a new window in Finder", intent: .newWindow, target: finder),
        .init("close-tab-zh", "关闭当前标签页", current: chrome, intent: .closeTab, target: chrome),
        .init("close-tab-en", "Close this tab in Chrome", current: finder, intent: .closeTab, target: chrome),
        .init("close-window-zh", "关闭当前窗口", intent: .closeWindow, target: editor),
        .init("close-window-en", "Close the current Chrome window", current: finder, intent: .closeWindow, target: chrome),
        .init("close-all-windows-zh", "关闭 TextEdit 的所有窗口", current: finder, intent: .closeAllWindows, target: editor),
        .init("literal-chinese-emoji", "输入『你好，世界 👋🌏』", intent: .typeText, target: editor, text: "你好，世界 👋🌏"),
        .init("literal-english", "Type hello world", intent: .typeText, target: editor, text: "hello world"),
        .init("literal-named-app", "In TextEdit, type hello world", current: finder, intent: .typeText, target: editor, text: "hello world"),
        .init("literal-enter-natural", "Please enter hello world", intent: .typeText, target: editor, text: "hello world"),
        .init("literal-chinese-natural", "帮我输入你好世界", intent: .typeText, target: editor, text: "你好世界"),
        .init("literal-multiline", "输入「第一行\n第二行」", intent: .typeText, target: editor, text: "第一行\n第二行"),
        .init("literal-confusion-app-zh", "输入「打开 Chrome」", intent: .typeText, target: editor, text: "打开 Chrome"),
        .init("literal-confusion-app-en", "Type \"Open Calculator\"", intent: .typeText, target: editor, text: "Open Calculator"),
        .init("literal-confusion-action", "输入「关闭所有窗口」", intent: .typeText, target: editor, text: "关闭所有窗口"),
        .init("literal-confusion-named-target", "在 TextEdit 输入「打开 Chrome」", current: finder, intent: .typeText, target: editor, text: "打开 Chrome"),
        .init("literal-quoted-destination", "Type \"hello\" in \"TextEdit\"", current: finder, intent: .typeText, target: editor, text: "hello"),
        .init("literal-app-name-only", "Type Chrome", intent: .typeText, target: editor, text: "Chrome"),
        .init("scroll-down-zh", "往下滚动", current: chrome, intent: .scrollDown, target: chrome),
        .init("scroll-up-en", "Scroll up", current: chrome, intent: .scrollUp, target: chrome),
        .init("copy-zh", "复制选中的内容", intent: .copy, target: editor),
        .init("undo-en", "Undo the last edit", intent: .undo, target: editor),
        .init("paste-en", "Paste here", intent: .paste, target: editor),
        .init("return-zh", "按一下回车", intent: .pressReturn, target: editor),
        .init("return-en-enter", "Press Enter", intent: .pressReturn, target: editor),
        .init("return-en-hit", "Hit Return", intent: .pressReturn, target: editor),
        .init("click-visible-en", "Click the Done button", intent: .clickElement, target: editor),
        .init("reject-multiple-actions", "打开 Chrome 然后搜索明天的天气", current: finder),
        .init("reject-generate-text", "帮我写一封邮件"),
        .init("reject-no-target", "新建一个窗口", current: nil),
        .init("reject-unknown-app", "打开 TotallyMissingApp"),
        .init("reject-delete-files", "删除下载文件夹里的所有文件"),
        .init("reject-type-and-submit", "输入 hello 然后按回车"),
        .init("reject-unquoted-destination-en", "type hello in TextEdit", current: stickies),
        .init("reject-unquoted-destination-zh", "输入你好到文本编辑", current: stickies)
    ]

    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.contains("--live") else {
            print("Skipped: add --live to make paid TypeSafe requests. This harness never operates desktop apps.")
            return
        }
        func argument(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let useInstalledApps = arguments.contains("--installed-apps")
        let inventory = useInstalledApps ? installedApplications() : Inventory(applications: apps, running: [])
        var availableScenarios = scenarios
        if useInstalledApps, inventory.applications.contains(where: { $0.id == "com.singularity.voicecodex.qa-target" }) {
            availableScenarios.append(.init("open-qa-target", "打开 VoiceCodex QA Target", current: finder,
                                            intent: .openApp, target: "com.singularity.voicecodex.qa-target"))
        }
        let installedSubset: Set<String> = ["open-calculator-zh", "open-chrome-en", "open-stickies-zh", "open-editor-zh",
                                             "open-settings-zh", "named-newtab-en", "current-newtab-zh", "literal-named-app", "open-qa-target"]
        let selected = argument("--filter").map { filter in availableScenarios.filter { $0.id.contains(filter) } } ??
            (useInstalledApps ? availableScenarios.filter { installedSubset.contains($0.id) } : availableScenarios)
        guard !selected.isEmpty else { print("No matching scenario."); exit(2) }
        let output = URL(fileURLWithPath: argument("--output") ?? ".build/qa/jev-live-results.json")
        do {
            let envURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/VoiceCodex/.env")
            let values = try EnvironmentFile.parse(String(contentsOf: envURL, encoding: .utf8))
            guard let key = values["TYPESAFE_API_KEY"], !key.isEmpty else {
                print("Missing TYPESAFE_API_KEY in the local application-support .env.")
                exit(2)
            }
            let model = values["TYPESAFE_DEFAULT_MODEL"] ?? "jev-1.13.0"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DecisionRecordingProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = JevClient(apiKey: key, model: model, session: session)
            var results: [Result] = []
            print("Inventory: \(inventory.applications.count) \(useInstalledApps ? "installed" : "synthetic") applications. No window or accessibility reads.")
            for scenario in selected {
                DecisionRecordingProtocol.reset()
                let started = Date()
                let expected = scenario.intent.map {
                    "\($0.rawValue) → \(scenario.target ?? "none")" + (scenario.text.map { " text=\($0.debugDescription)" } ?? "")
                } ?? "No executable command"
                let passed: Bool
                let observed: String
                let confidence: Double?
                do {
                    let candidates = inventory.applications.sorted {
                        if ($0.id == scenario.current) != ($1.id == scenario.current) { return $0.id == scenario.current }
                        if inventory.running.contains($0.id) != inventory.running.contains($1.id) { return inventory.running.contains($0.id) }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    let command = try await client.plan(transcript: scenario.transcript, applications: Array(candidates.prefix(2_000)),
                                                        currentApplicationID: scenario.current)
                    confidence = command.confidence
                    observed = "\(command.intent.rawValue) → \(command.applicationID ?? "none")" +
                        (command.text.map { " text=\($0.debugDescription)" } ?? "")
                    if let intent = scenario.intent {
                        passed = command.intent == intent && command.applicationID == scenario.target && command.text == scenario.text
                    } else {
                        passed = command.intent == .unsupported && command.applicationID == nil
                    }
                } catch let error as JevClientError {
                    observed = errorName(error)
                    if case .lowConfidence(let value) = error { confidence = value } else { confidence = nil }
                    switch error {
                    case .unsupportedCommand, .literalTextRequired, .lowConfidence:
                        passed = scenario.intent == nil
                    default: passed = false
                    }
                } catch {
                    observed = "unexpected client failure"
                    confidence = nil
                    passed = false
                }
                let latency = Int(Date().timeIntervalSince(started) * 1_000)
                let result = Result(id: scenario.id, transcript: scenario.transcript, passed: passed,
                                    latencyMilliseconds: latency, expected: expected, observed: observed, confidence: confidence,
                                    decisions: DecisionRecordingProtocol.snapshot())
                results.append(result)
                print("\(passed ? "PASS" : "FAIL") \(scenario.id) [\(latency) ms]: \(observed)")
                fflush(stdout)
                // Persist each completed result so interruption cannot erase failures.
                try save(results, model: model, installed: useInstalledApps, applicationCount: inventory.applications.count, to: output)
            }
            let passed = results.filter(\.passed).count
            print("Planner only: \(passed)/\(results.count) passed. No desktop actions were performed.")
            exit(passed == results.count ? 0 : 1)
        } catch {
            // Never include file contents, request bodies, credentials, or arbitrary diagnostics.
            print("Could not load local configuration or save results.")
            exit(2)
        }
    }

    private static func save(_ results: [Result], model: String, installed: Bool, applicationCount: Int, to output: URL) throws {
        let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()), model: model,
                            scope: "Actual TypeSafe HTTP planner decisions on synthetic transcripts and \(installed ? "installed" : "synthetic") app inventory; no AX input",
                            applicationCount: applicationCount,
                            passed: results.filter(\.passed).count, total: results.count, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    private struct Inventory {
        let applications: [MacApplication]
        let running: Set<String>
    }

    /// Mirrors the production driver's bounded bundle discovery and fallback.
    /// NSWorkspace is used only for running-app bundle metadata; never windows,
    /// foreground UI, accessibility, files within documents, or native input.
    private static func installedApplications() -> Inventory {
        var urls: [String: URL] = [:]
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var count = 0
            while let url = entries.nextObject() as? URL, count < 2_000 {
                count += 1
                if url.pathExtension == "app" {
                    entries.skipDescendants()
                    if let id = Bundle(url: url)?.bundleIdentifier, urls[id] == nil { urls[id] = url }
                } else if entries.level > 3 { entries.skipDescendants() }
            }
        }
        let runningApplications = NSWorkspace.shared.runningApplications
        for app in runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, let url = app.bundleURL, urls[id] == nil { urls[id] = url }
        }
        urls.removeValue(forKey: "com.singularity.voicecodex")
        let applications = urls.compactMap { id, url -> MacApplication? in
            guard !id.isEmpty, id.count <= 256, id.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
            }) else { return nil }
            let bundle = Bundle(url: url)
            let names = [bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                         bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                         url.deletingPathExtension().lastPathComponent]
            let usable = names.compactMap { $0 }.map {
                $0.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            }.first { !$0.isEmpty && $0.count <= 200 }
            return MacApplication(id: id, name: usable ?? String(id.prefix(200)))
        }
        return Inventory(applications: applications, running: Set(runningApplications.compactMap(\.bundleIdentifier)))
    }

    private static func errorName(_ error: JevClientError) -> String {
        switch error {
        case .missingKey: return "missingKey"
        case .invalidInput: return "invalidInput"
        case .invalidResponse: return "invalidResponse"
        case .lowConfidence(let value): return "lowConfidence(\(value))"
        case .literalTextRequired: return "literalTextRequired"
        case .unsupportedCommand: return "unsupportedCommand"
        case .requestFailed(let code): return "httpStatus(\(code))"
        case .networkUnavailable: return "networkUnavailable"
        }
    }
}

/// Records only fixed-vocabulary choice IDs and numeric confidence for synthetic
/// cases. Requests, credentials, raw response bodies, and arbitrary errors are
/// never logged. The forwarding session does not install this protocol.
private final class DecisionRecordingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var records: [String] = []
    private var forwardingTask: URLSessionDataTask?

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        records = []
    }

    static func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        forwardingTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = object["answers"] as? [String: [String: Any]] {
                var decisions: [String] = []
                for name in ["action", "application", "text", "element"] {
                    guard let answer = answers[name], let confidence = answer["confidence"] as? Double else { continue }
                    let choice = answer["choice"] as? String ?? ""
                    let allowed = MacIntent(rawValue: choice) != nil || ["none", "current"].contains(choice) ||
                        choice.range(of: #"^(app|group|text|element)_[0-9]+$"#, options: .regularExpression) != nil
                    decisions.append("\(name)=\(allowed ? choice : "unknown") confidence=\(confidence)")
                }
                Self.lock.lock()
                Self.records.append(contentsOf: decisions)
                Self.lock.unlock()
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardingTask?.resume()
    }

    override func stopLoading() { forwardingTask?.cancel() }
}
