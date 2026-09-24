import XCTest
import VoiceCodexCore
@testable import VoiceCodex

@MainActor
final class MacSequenceExecutorTests: XCTestCase {
    func testPlansEachStepAfterReceiptWithLastSuccessfulTarget() async throws {
        let queue = MacSequenceExecutor()
        try queue.enqueue("打开腾讯会议，然后创建一个新的会议", target: "initial.app")
        var events: [String] = []
        try await queue.run(plan: { text, target in
            events.append("plan:\(target ?? "nil")")
            return MacCommand(intent: text.contains("打开") ? .openApp : .clickElement,
                              applicationID: "com.tencent.meeting", confidence: 0.99)
        }, perform: { command, step in
            events.append("execute:\(step.index)")
            await Task.yield()
            return command.intent.rawValue
        }, onReceipt: { _, _ in events.append("receipt") })
        XCTAssertEqual(events, ["plan:initial.app", "execute:1", "receipt", "plan:com.tencent.meeting", "execute:2", "receipt"])
        XCTAssertFalse(queue.isRunning)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testSpeechArrivingDuringExecutionIsQueuedNotDroppedOrConcurrent() async throws {
        let queue = MacSequenceExecutor()
        try queue.enqueue("打开计算器", target: "initial.app")
        var performed: [String] = []
        var targets: [String?] = []
        try await queue.run(plan: { _, target in
            targets.append(target)
            return MacCommand(intent: .openApp, applicationID: "com.apple.calculator", confidence: 1)
        }, perform: { _, step in
            performed.append(step.text)
            if performed.count == 1 {
                try queue.enqueue("然后打开日历", target: "must.not.replace.target")
            }
            return "ok"
        })
        XCTAssertEqual(performed, ["打开计算器", "打开日历"])
        XCTAssertEqual(targets, ["initial.app", "com.apple.calculator"])
    }

    func testFailureDropsRemainingStepsAndQueuedSpeechWithoutRetry() async throws {
        let queue = MacSequenceExecutor()
        try queue.enqueue("打开计算器，然后打开日历，然后打开提醒事项", target: nil)
        var attempts = 0
        do {
            try await queue.run(plan: { _, _ in
                MacCommand(intent: .openApp, applicationID: "fixture.app", confidence: 1)
            }, perform: { _, _ in
                attempts += 1
                if attempts == 2 { throw MacControlError.incomplete("fixture failure") }
                try queue.enqueue("打开便笺", target: nil)
                return "ok"
            })
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error.localizedDescription, "fixture failure") }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertFalse(queue.isRunning)
        XCTAssertEqual(queue.currentApplicationID, "fixture.app")
    }

    func testCancellationDuringPlanningNeverPerformsActionAndClearsQueue() async throws {
        let queue = MacSequenceExecutor()
        try queue.enqueue("打开计算器，然后打开日历", target: nil)
        let entered = expectation(description: "planner started")
        var performed = 0
        let task = Task {
            try await queue.run(plan: { _, _ in
                entered.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return MacCommand(intent: .openApp, confidence: 1)
            }, perform: { _, _ in performed += 1; return "wrong" })
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(performed, 0)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testCancellationAfterDeliveredActionDoesNotRunNextStep() async throws {
        let queue = MacSequenceExecutor()
        try queue.enqueue("打开计算器，然后打开日历", target: nil)
        let entered = expectation(description: "first action delivered")
        var performed = 0
        let task = Task {
            try await queue.run(plan: { _, _ in MacCommand(intent: .openApp, confidence: 1) }, perform: { _, _ in
                performed += 1
                entered.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return "delivered"
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(performed, 1)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testUnsupportedPlannerResultStopsBeforeExecution() async throws {
        let queue = MacSequenceExecutor()
        try queue.enqueue("打开计算器，然后打开日历", target: nil)
        var performed = false
        do {
            try await queue.run(plan: { _, _ in MacCommand(intent: .unsupported, confidence: 1) },
                                perform: { _, _ in performed = true; return "wrong" })
            XCTFail("Expected unsupported")
        } catch { XCTAssertTrue(error is JevClientError) }
        XCTAssertFalse(performed)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testMalformedWholeSequenceCannotPartiallyEnqueue() throws {
        let queue = MacSequenceExecutor()
        XCTAssertThrowsError(try queue.enqueue("打开计算器，然后输入「未结束", target: nil))
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testQueueIsBoundedAndNextIndependentRequestReseedsTarget() async throws {
        let queue = MacSequenceExecutor()
        for _ in 0..<12 { try queue.enqueue("打开计算器", target: "first") }
        XCTAssertThrowsError(try queue.enqueue("打开日历", target: "other"))
        XCTAssertEqual(queue.pendingCount, 12)
        queue.clear()
        try queue.enqueue("打开日历", target: "new.target")
        try await queue.run(plan: { _, target in
            XCTAssertEqual(target, "new.target")
            return MacCommand(intent: .openApp, confidence: 1)
        }, perform: { _, _ in "ok" })
    }
}
