import XCTest
@testable import VoiceCodexCore

final class JevClientTests: XCTestCase {
    private let applications = [MacApplication(id: "com.example.Browser", name: "Test Browser")]

    func testPlanUsesFixedEndpointBearerAndTypedChoices() async throws {
        let fixture = JevHTTPFixture { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.body(request)
            XCTAssertEqual(body["model"] as? String, "jev-1.13.0")
            XCTAssertEqual((body["state"] as? [String: String])?["user_command"], "打开 Test Browser")
            let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
            XCTAssertEqual(questions["action"]?["type"] as? String, "choice")
            XCTAssertEqual(questions["application"]?["type"] as? String, "choice")
            return (200, try Self.answer(request, choices: ["action": "openApp", "application": "app_0"]))
        }
        defer { fixture.close() }
        let command = try await fixture.client.plan(transcript: "打开 Test Browser", applications: applications,
                                                     currentApplicationID: "com.example.Other")
        XCTAssertEqual(command, MacCommand(intent: .openApp, applicationID: "com.example.Browser", confidence: 0.95))
    }

    func testCurrentAppResolvedFromCapturedContext() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "newTab", "application": "current"]))
        }
        defer { fixture.close() }
        let result = try await fixture.client.plan(transcript: "新建标签页", applications: applications,
                                                   currentApplicationID: "com.example.Browser")
        XCTAssertEqual(result.applicationID, "com.example.Browser")
    }

    func testInstalledApplicationAliasesAreSharedWithIndependentActionQuestion() async throws {
        let fixture = JevHTTPFixture { request in
            let state = try XCTUnwrap(Self.body(request)["state"] as? [String: String])
            XCTAssertTrue(state["mentioned_installed_applications"]?.contains("com.apple.Stickies") == true)
            XCTAssertTrue(state["mentioned_installed_applications"]?.contains("便笺") == true)
            XCTAssertFalse(state["mentioned_installed_applications"]?.contains("com.apple.systempreferences") == true)
            return (200, try Self.answer(request, choices: ["action": "openApp", "application": "app_0"]))
        }
        defer { fixture.close() }
        let result = try await fixture.client.plan(transcript: "打开便笺", applications: [
            MacApplication(id: "com.apple.Stickies", name: "Stickies"),
            MacApplication(id: "com.apple.systempreferences", name: "System Settings")
        ], currentApplicationID: nil)
        XCTAssertEqual(result.applicationID, "com.apple.Stickies")
    }

    func testLargeAppListPreservesLateTargetThroughHierarchicalChoice() async throws {
        let apps = (0..<1_000).map { MacApplication(id: "com.example.App\($0)", name: "Application \($0)") }
        let fixture = JevHTTPFixture { request in
            let questions = try XCTUnwrap(Self.body(request)["questions"] as? [String: [String: Any]])
            let candidates = try XCTUnwrap(questions["application"]?["criteria"] as? [String: String])
            XCTAssertLessThanOrEqual(candidates.count, 255)
            if questions["action"] != nil {
                XCTAssertTrue(candidates["group_24"]?.contains("Application 999") == true)
                return (200, try Self.answer(request, choices: ["action": "openApp", "application": "group_24"]))
            }
            XCTAssertTrue(candidates["app_999"]?.contains("com.example.App999") == true)
            XCTAssertEqual(candidates.count, 41)
            return (200, try Self.answer(request, choices: ["application": "app_999"], confidences: ["application": 0.88]))
        }
        defer { fixture.close() }
        let result = try await fixture.client.plan(transcript: "Open Application 999", applications: apps,
                                                   currentApplicationID: nil)
        XCTAssertEqual(result.applicationID, "com.example.App999")
        XCTAssertEqual(result.confidence, 0.88)
    }

    func testLargeAppListRejectsUnknownGroup() async throws {
        let apps = (0..<300).map { MacApplication(id: "com.example.App\($0)", name: "Application \($0)") }
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "openApp", "application": "group_999"]))
        }
        defer { fixture.close() }
        await assertError(.invalidResponse) {
            _ = try await fixture.client.plan(transcript: "Open Application 299", applications: apps,
                                               currentApplicationID: nil)
        }
    }

    func testLargeAppListCurrentTargetNeedsOnlyOneRequestAndIsNotDuplicated() async throws {
        let apps = (0..<300).map { MacApplication(id: "com.example.App\($0)", name: "Application \($0)") }
        let fixture = JevHTTPFixture { request in
            let questions = try XCTUnwrap(Self.body(request)["questions"] as? [String: [String: Any]])
            XCTAssertNotNil(questions["action"], "A current target should not request group narrowing")
            let candidates = try XCTUnwrap(questions["application"]?["criteria"] as? [String: String])
            XCTAssertTrue(candidates["current"]?.contains("Application 299") == true)
            XCTAssertFalse(candidates.filter { $0.key != "current" }.values.contains { $0.contains("Application 299") })
            return (200, try Self.answer(request, choices: ["action": "copy", "application": "current"]))
        }
        defer { fixture.close() }
        let result = try await fixture.client.plan(transcript: "Copy", applications: apps,
                                                   currentApplicationID: "com.example.App299")
        XCTAssertEqual(result.applicationID, "com.example.App299")
    }

    func testLiteralTextIsChosenFromLocalSpanWithoutChanges() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "typeText", "application": "current"],
                                  confidences: ["action": 0.81]))
        }
        defer { fixture.close() }
        let result = try await fixture.client.plan(transcript: "输入「  你好 $HOME  」", applications: applications,
                                                   currentApplicationID: "com.example.Browser")
        XCTAssertEqual(result.text, "  你好 $HOME  ")
        XCTAssertEqual(result.confidence, 0.81)
    }

    func testLiteralPayloadNeverEntersModelRoutingRequest() async throws {
        let fixture = JevHTTPFixture { request in
            let body = try Self.body(request)
            let state = try XCTUnwrap(body["state"] as? [String: String])
            XCTAssertFalse(state.values.joined().contains("打开 Chrome"))
            XCTAssertFalse(state["mentioned_installed_applications"]?.contains("com.google.Chrome") == true)
            XCTAssertTrue(state["user_command"]?.contains("[literal text]") == true)
            let questions = try XCTUnwrap(body["questions"] as? [String: Any])
            XCTAssertNil(questions["text"])
            return (200, try Self.answer(request, choices: ["action": "typeText", "application": "current"]))
        }
        defer { fixture.close() }
        let command = try await fixture.client.plan(transcript: "输入「打开 Chrome」", applications: [
            MacApplication(id: "com.apple.TextEdit", name: "TextEdit"),
            MacApplication(id: "com.google.Chrome", name: "Google Chrome")
        ], currentApplicationID: "com.apple.TextEdit")
        XCTAssertEqual(command.intent, .typeText)
        XCTAssertEqual(command.applicationID, "com.apple.TextEdit")
        XCTAssertEqual(command.text, "打开 Chrome")
    }

    func testModelCannotTurnLiteralEntryIntoAnotherOperation() async throws {
        for intent in ["openApp", "closeAllWindows", "pressReturn"] {
            let fixture = JevHTTPFixture { request in
                (200, try Self.answer(request, choices: ["action": intent, "application": "current"]))
            }
            defer { fixture.close() }
            await assertError(.unsupportedCommand) {
                _ = try await fixture.client.plan(transcript: "输入「关闭所有窗口」", applications: self.applications,
                                                   currentApplicationID: "com.example.Browser")
            }
        }
    }

    func testCompoundTypingEnvelopeIsRejectedBeforeAnyModelVote() async throws {
        let fixture = JevHTTPFixture { request in
            XCTFail("A detected secondary action must be rejected before contacting the model")
            return (200, try Self.answer(request, choices: ["action": "typeText", "application": "current"]))
        }
        defer { fixture.close() }
        for transcript in ["Type \"hello\" then close the window", "type hello and press Return", "输入hello然后按回车"] {
            await assertError(.unsupportedCommand) {
                _ = try await fixture.client.plan(transcript: transcript, applications: self.applications,
                                                   currentApplicationID: "com.example.Browser")
            }
        }
    }

    func testUnquotedInstalledAppDestinationRequiresQuotesBeforeRequest() async throws {
        let fixture = JevHTTPFixture { request in
            XCTFail("Ambiguous destination must not reach the model")
            return (200, try Self.answer(request, choices: ["action": "typeText", "application": "current"]))
        }
        defer { fixture.close() }
        for transcript in ["type hello in TextEdit", "输入你好到文本编辑"] {
            await assertError(.literalTextRequired) {
                _ = try await fixture.client.plan(transcript: transcript, applications: [
                    MacApplication(id: "com.apple.TextEdit", name: "TextEdit"),
                    MacApplication(id: "com.apple.Stickies", name: "Stickies")
                ], currentApplicationID: "com.apple.Stickies")
            }
        }
    }

    func testAppNameAloneAndQuotedDestinationWordsStayLiteral() async throws {
        let fixture = JevHTTPFixture { request in
            let state = try XCTUnwrap(Self.body(request)["state"] as? [String: String])
            XCTAssertFalse(state["user_command"]?.contains("Chrome") == true)
            return (200, try Self.answer(request, choices: ["action": "typeText", "application": "current"]))
        }
        defer { fixture.close() }
        for (transcript, payload) in [("Type Chrome", "Chrome"), ("Type \"hello in Chrome\"", "hello in Chrome")] {
            let command = try await fixture.client.plan(transcript: transcript, applications: [
                MacApplication(id: "com.apple.TextEdit", name: "TextEdit"),
                MacApplication(id: "com.google.Chrome", name: "Google Chrome")
            ], currentApplicationID: "com.apple.TextEdit")
            XCTAssertEqual(command.text, payload)
            XCTAssertEqual(command.applicationID, "com.apple.TextEdit")
        }
    }

    func testTypingWithoutLiteralTextFailsClosed() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "typeText", "application": "current"]))
        }
        defer { fixture.close() }
        await assertError(.literalTextRequired) {
            _ = try await fixture.client.plan(transcript: "替我写封邮件", applications: self.applications,
                                               currentApplicationID: "com.example.Browser")
        }
    }

    func testUnknownApplicationAndActionIDsAreRejected() async throws {
        for choices in [
            ["action": "openApp", "application": "com.attacker.App"],
            ["action": "executeShell", "application": "current"]
        ] {
            let fixture = JevHTTPFixture { request in (200, try Self.answer(request, choices: choices)) }
            defer { fixture.close() }
            await assertError(.invalidResponse) {
                _ = try await fixture.client.plan(transcript: "打开 Test Browser", applications: self.applications,
                                                   currentApplicationID: "com.example.Browser")
            }
        }
    }

    func testLowConfidenceStopsBeforeReturningAnAction() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "openApp", "application": "app_0"],
                                  confidences: ["application": 0.74]))
        }
        defer { fixture.close() }
        await assertError(.lowConfidence(0.74)) {
            _ = try await fixture.client.plan(transcript: "打开 Test Browser", applications: self.applications,
                                               currentApplicationID: nil)
        }
    }

    func testAbsentCurrentApplicationFailsClosed() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "paste", "application": "current"]))
        }
        defer { fixture.close() }
        await assertError(.unsupportedCommand) {
            _ = try await fixture.client.plan(transcript: "粘贴", applications: self.applications,
                                               currentApplicationID: nil)
        }
    }

    func testCurrentApplicationNotInObservedListFailsClosed() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "copy", "application": "current"]))
        }
        defer { fixture.close() }
        await assertError(.unsupportedCommand) {
            _ = try await fixture.client.plan(transcript: "复制", applications: self.applications,
                                               currentApplicationID: "com.example.Unobserved")
        }
    }

    func testUnsupportedResponseDoesNotAcquireAnExecutableTarget() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["action": "unsupported", "application": "none"]))
        }
        defer { fixture.close() }
        let result = try await fixture.client.plan(transcript: "打开浏览器然后搜索天气", applications: applications,
                                                   currentApplicationID: "com.example.Browser")
        XCTAssertEqual(result.intent, .unsupported)
        XCTAssertNil(result.applicationID)
        XCTAssertNil(result.text)
    }

    func testChooseElementReturnsOnlyAnObservedCallerID() async throws {
        let fixture = JevHTTPFixture { request in
            (200, try Self.answer(request, choices: ["element": "element_1"]))
        }
        defer { fixture.close() }
        let selected = try await fixture.client.chooseElement(goal: "点击完成", elements: ["e1": "Cancel", "e2": "Done"])
        XCTAssertEqual(selected, "e2")
    }

    func testChooseElementUnknownIDAndNoMatchFailClosed() async throws {
        for (choice, expected) in [("e1", JevClientError.invalidResponse), ("none", .unsupportedCommand)] {
            let fixture = JevHTTPFixture { request in (200, try Self.answer(request, choices: ["element": choice])) }
            defer { fixture.close() }
            await assertError(expected) {
                _ = try await fixture.client.chooseElement(goal: "点击完成", elements: ["e1": "Done"])
            }
        }
    }

    func testEmptyKeyNeverStartsARequest() async throws {
        let fixture = JevHTTPFixture { _ in
            XCTFail("Missing key must not contact TypeSafe")
            return nil
        }
        defer { fixture.close() }
        let client = JevClient(apiKey: "  \n", session: fixture.session)
        await assertError(.missingKey) {
            _ = try await client.plan(transcript: "打开 Test Browser", applications: self.applications,
                                      currentApplicationID: nil)
        }
    }

    func testErrorBodiesAndMalformedSuccessAreNotExposed() async throws {
        for status in [401, 500, 200] {
            let fixture = JevHTTPFixture { _ in (status, Data("secret-test-key private transcript".utf8)) }
            defer { fixture.close() }
            do {
                _ = try await fixture.client.plan(transcript: "打开 Test Browser", applications: applications,
                                                   currentApplicationID: nil)
                XCTFail("Expected an error")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("secret-test-key"))
                XCTAssertFalse(error.localizedDescription.contains("private transcript"))
                XCTAssertEqual(error as? JevClientError, status == 200 ? .invalidResponse : .requestFailed(statusCode: status))
            }
        }
    }

    func testMalformedProbabilityDistributionIsRejected() async throws {
        let fixture = JevHTTPFixture { request in
            let valid = try Self.answer(request, choices: ["action": "openApp", "application": "app_0"])
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            var answers = try XCTUnwrap(object["answers"] as? [String: [String: Any]])
            answers["action"]?["probabilities"] = ["openApp": 1.0]
            object["answers"] = answers
            return (200, try JSONSerialization.data(withJSONObject: object))
        }
        defer { fixture.close() }
        await assertError(.invalidResponse) {
            _ = try await fixture.client.plan(transcript: "打开 Test Browser", applications: self.applications,
                                               currentApplicationID: nil)
        }
    }

    func testTaskCancellationCancelsURLSessionRequest() async throws {
        let started = expectation(description: "request started")
        let fixture = JevHTTPFixture { _ in
            started.fulfill()
            return nil
        }
        defer { fixture.close() }
        let task = Task {
            try await fixture.client.plan(transcript: "打开 Test Browser", applications: applications,
                                          currentApplicationID: nil)
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    private func assertError(_ expected: JevClientError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? JevClientError, expected, file: file, line: line)
        }
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var contents = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                contents.append(contentsOf: buffer.prefix(count))
            }
            data = contents
        } else {
            throw JevClientError.invalidInput
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func answer(_ request: URLRequest, choices: [String: String],
                               confidences: [String: Double] = [:]) throws -> Data {
        let questions = try XCTUnwrap(body(request)["questions"] as? [String: [String: Any]])
        var answers: [String: Any] = [:]
        for (name, question) in questions {
            let criteria = try XCTUnwrap(question["criteria"] as? [String: String])
            let selected = choices[name] ?? "none"
            let probabilities = criteria.mapValues { _ in 0.0 }.merging([selected: 1.0]) { _, new in new }
            answers[name] = ["type": "choice", "choice": selected, "probabilities": probabilities,
                             "confidence": confidences[name] ?? 0.95]
        }
        return try JSONSerialization.data(withJSONObject: ["model": "jev-1.13.0", "answers": answers,
                                                            "usage": ["input_tokens": 100, "output_tokens": 20]])
    }
}

private final class JevHTTPFixture {
    let identifier = UUID().uuidString
    let session: URLSession
    var client: JevClient { JevClient(apiKey: "test-key", session: session) }

    init(handler: @escaping JevURLProtocol.Handler) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Jev-Test-ID": identifier]
        session = URLSession(configuration: configuration)
        JevURLProtocol.register(identifier, handler: handler)
    }

    func close() {
        session.invalidateAndCancel()
        JevURLProtocol.unregister(identifier)
    }
}

private final class JevURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (Int, Data)?
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(_ id: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
    }

    static func unregister(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.value(forHTTPHeaderField: "X-Jev-Test-ID") ?? ""]
        Self.lock.unlock()
        do {
            guard let handler else { throw JevClientError.invalidInput }
            guard let (status, data) = try handler(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
