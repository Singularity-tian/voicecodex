import Foundation
import VoiceCodexCore

/// One serial consumer for both typed sequences and confirmed speech segments.
/// Planning happens just before each action, with the last successful target.
@MainActor
final class MacSequenceExecutor {
    struct Step: Equatable {
        let text: String
        let index: Int
        let total: Int
    }

    enum QueueError: LocalizedError {
        case full, alreadyRunning
        var errorDescription: String? {
            switch self {
            case .full: return "待执行动作太多，已停止。请等当前动作完成后再继续。"
            case .alreadyRunning: return "动作队列正在执行。"
            }
        }
    }

    private var pending: [Step] = []
    private(set) var isRunning = false
    private(set) var currentApplicationID: String?
    var pendingCount: Int { pending.count }

    @discardableResult
    func enqueue(_ text: String, target: String?) throws -> Int {
        // Validate the entire utterance before allowing its first side effect.
        let steps = try MacCommandSequence.parse(text)
        guard pending.count + steps.count <= 12 else { throw QueueError.full }
        if !isRunning && pending.isEmpty { currentApplicationID = target }
        pending += steps.enumerated().map { Step(text: $0.element, index: $0.offset + 1, total: steps.count) }
        return steps.count
    }

    func clear() { pending.removeAll() }

    func run(plan: (String, String?) async throws -> MacCommand,
             perform: (MacCommand, Step) async throws -> String,
             onStep: (Step) -> Void = { _ in },
             onReceipt: (MacCommand, String) -> Void = { _, _ in }) async throws {
        guard !isRunning else { throw QueueError.alreadyRunning }
        isRunning = true
        defer { isRunning = false; pending.removeAll() }
        while !pending.isEmpty {
            try Task.checkCancellation()
            let step = pending.removeFirst()
            onStep(step)
            let command = try await plan(step.text, currentApplicationID)
            try Task.checkCancellation()
            guard command.intent != .unsupported else { throw JevClientError.unsupportedCommand }
            let receipt = try await perform(command, step)
            try Task.checkCancellation()
            if let target = command.applicationID { currentApplicationID = target }
            onReceipt(command, receipt)
        }
    }
}
