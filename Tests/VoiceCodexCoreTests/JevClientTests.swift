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
            (200, try Self.answer(request, choices: ["action": "typeText", "application": "current", "text": "text_0"],
                                  confidences: ["text": 0.81]))
        }
        defer { fixture.close() }
        let result = try await fixture.client.plan(transcript: "输入「  你好 $HOME  」", applications: applications,
                                                   currentApplicationID: "com.example.Browser")
        XCTAssertEqual(result.text, "  你好 $HOME  ")
        XCTAssertEqual(result.confidence, 0.81)
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
