import ApplicationServices
import XCTest
import VoiceCodexCore
@testable import VoiceCodex

final class MacControlDriverTests: XCTestCase {
    func testEmptyDisplayNameFallsBackWithoutInvalidatingOtherApplications() {
        let app = MacControlDriver.applicationMetadata(id: "com.example.Notes", names: ["", " \n ", "Notes"])
        XCTAssertEqual(app?.id, "com.example.Notes")
        XCTAssertEqual(app?.name, "Notes")
    }

    func testOverlongLabelsAndMissingMetadataUseBoundedFallback() {
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: "com.example.Notes", names: [String(repeating: "a", count: 201), "Notes"])?.name, "Notes")
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: "com.example.Notes", names: [nil, " "])?.name, "com.example.Notes")
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: String(repeating: "a", count: 256), names: [])?.name.count, 200)
    }

    func testMalformedApplicationIDsAreExcludedWithoutRewritingIdentity() {
        for id in ["", " com.example.Notes", "com.example.Notes\n", "com.example/Notes", String(repeating: "a", count: 257)] {
            XCTAssertNil(MacControlDriver.applicationMetadata(id: id, names: ["Notes"]))
        }
        XCTAssertEqual(MacControlDriver.applicationMetadata(id: "com.example.App_2-beta", names: ["Notes"])?.id, "com.example.App_2-beta")
    }

    func testInsertionPreservesDocumentAndLiteralCommandCharacters() {
        let literal = "$(touch /tmp/example); `whoami`\nhello"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: "before AFTER", range: CFRange(location: 7, length: 5), with: literal),
                       "before " + literal)
    }

    func testUnicodeSelectionUsesUTF16OffsetsWithoutSplittingEmoji() {
        XCTAssertEqual(MacControlDriver.replacingSelection(in: "A👩🏽‍💻B", range: CFRange(location: 1, length: 7), with: "你好"), "A你好B")
        XCTAssertNil(MacControlDriver.replacingSelection(in: "A😀B", range: CFRange(location: 2, length: 1), with: "x"))
    }

    func testMultilineChineseAndEmojiInsertAtCursorWithoutChangingSurroundingDocument() {
        let before = "已有内容 🧑🏽‍🚀\n"
        let after = "\n保留后面的内容"
        let text = "第一行：你好，世界 👋\n第二行：🚀 ready\n"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: before + after,
            range: CFRange(location: before.utf16.count, length: 0), with: text), before + text + after)
    }

    func testEmptyDocumentAndEndOfDocumentAcceptLiteralMultilineText() {
        let text = "你好\n👩🏽‍💻\n"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: "", range: CFRange(location: 0, length: 0), with: text), text)
        let existing = "文档😀"
        XCTAssertEqual(MacControlDriver.replacingSelection(in: existing,
            range: CFRange(location: existing.utf16.count, length: 0), with: text), existing + text)
    }

    func testInsertionPreservesUnicodeScalarSpellingInsteadOfNormalizingIt() {
        let text = "e\u{301}\r\n\t café 😀"
        let result = MacControlDriver.replacingSelection(in: "prefixsuffix", range: CFRange(location: 6, length: 0), with: text)
        XCTAssertEqual(result.map { Array($0.utf16) }, Array(("prefix" + text + "suffix").utf16))
    }

    func testSelectionEndingInsideASurrogatePairIsRejected() {
        XCTAssertNil(MacControlDriver.replacingSelection(in: "A😀B", range: CFRange(location: 0, length: 2), with: "x"))
        XCTAssertNil(MacControlDriver.replacingSelection(in: "😀", range: CFRange(location: 1, length: 0), with: "x"))
        XCTAssertNil(MacControlDriver.replacingSelection(in: "abc", range: CFRange(location: Int.max, length: 0), with: "x"))
    }

    func testLocalizedApplicationNamesAreRetainedAndControlCharactersRemoved() {
        let application = MacControlDriver.applicationMetadata(id: "com.example.Notes", names: ["  便笺\nNotes\t "])
        XCTAssertEqual(application?.name, "便笺 Notes")
    }

    func testOutOfBoundsSelectionCannotReplaceWholeField() {
        for range in [CFRange(location: -1, length: 0), CFRange(location: 0, length: -1),
                      CFRange(location: 4, length: 0), CFRange(location: 1, length: Int.max)] {
            XCTAssertNil(MacControlDriver.replacingSelection(in: "abc", range: range, with: "replacement"))
        }
    }

    func testCommonTerminalAppsAreBlockedFromInput() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                   "com.cmuxterm.app", "org.alacritty", "net.kovidgoyal.kitty"] {
            XCTAssertTrue(MacControlDriver.isTerminalApplication(id))
        }
        XCTAssertFalse(MacControlDriver.isTerminalApplication("com.apple.Stickies"))
        XCTAssertFalse(MacControlDriver.isTerminalApplication("com.google.Chrome"))
    }

    func testDocumentMetadataCannotTurnAnOrdinaryEditorIntoATerminal() {
        XCTAssertFalse(MacControlDriver.isTerminalElement(role: kAXWindowRole,
            identifier: "Terminal notes.txt", roleDescription: "终端使用说明"))
        XCTAssertFalse(MacControlDriver.isTerminalElement(role: kAXApplicationRole,
            identifier: "com.example.terminal-tutorial", roleDescription: "Terminal documentation"))
        XCTAssertFalse(MacControlDriver.isTerminalElement(role: kAXTextAreaRole,
            identifier: "document-editor", roleDescription: "text area"))
    }

    func testEmbeddedTerminalWidgetMetadataIsStillRejected() {
        XCTAssertTrue(MacControlDriver.isTerminalElement(role: kAXTextAreaRole,
            identifier: "terminal-input", roleDescription: "text area"))
        XCTAssertTrue(MacControlDriver.isTerminalElement(role: kAXTextAreaRole,
            identifier: "xterm-helper-textarea", roleDescription: "text area"))
        XCTAssertTrue(MacControlDriver.isTerminalElement(role: "AXTerminal",
            identifier: nil, roleDescription: "终端"))
    }

    func testControlRolesWithoutActualLabelsDoNotBlockVisualFallback() {
        XCTAssertNil(MacControlDriver.controlLabel(role: kAXButtonRole, title: nil, description: nil))
        XCTAssertNil(MacControlDriver.controlLabel(role: kAXButtonRole, title: " \n ", description: "\t"))
    }

    func testControlLabelsRetainLocalizedTitleOrAccessibilityDescription() {
        XCTAssertEqual(MacControlDriver.controlLabel(role: kAXButtonRole, title: " 快速会议 ", description: nil),
                       "AXButton · 快速会议")
        XCTAssertEqual(MacControlDriver.controlLabel(role: kAXButtonRole, title: "", description: " Create meeting "),
                       "AXButton · Create meeting")
    }

    func testWindowOwnershipFallbackDoesNotLookThroughAnotherAppsOverlay() {
        let bounds = CGRect(x: -800, y: 50, width: 700, height: 500)
        let target = MacControlDriver.HitWindow(processID: 42, windowID: 10, bounds: bounds, alpha: 1)
        let overlay = MacControlDriver.HitWindow(processID: 99, windowID: 20, bounds: bounds, alpha: 1)
        let point = CGPoint(x: -450, y: 300)
        XCTAssertEqual(MacControlDriver.frontmostWindow(at: point, in: [overlay, target])?.windowID, 20)
        XCTAssertEqual(MacControlDriver.frontmostWindow(at: point, in: [target, overlay])?.windowID, 10)
    }

    func testWindowOwnershipFallbackDoesNotConfuseTwoWindowsInTheSameApp() {
        let bounds = CGRect(x: 100, y: 50, width: 700, height: 500)
        let target = MacControlDriver.HitWindow(processID: 42, windowID: 10, bounds: bounds, alpha: 1)
        let secondWindow = MacControlDriver.HitWindow(processID: 42, windowID: 11, bounds: bounds, alpha: 1)
        XCTAssertEqual(MacControlDriver.frontmostWindow(at: CGPoint(x: 400, y: 300), in: [secondWindow, target])?.windowID, 11)
    }

    func testWindowOwnershipFallbackSkipsInvisibleAndNonOverlappingWindowsOnly() {
        let target = MacControlDriver.HitWindow(processID: 42, windowID: 10,
            bounds: CGRect(x: 100, y: 50, width: 700, height: 500), alpha: 1)
        let invisible = MacControlDriver.HitWindow(processID: 99, windowID: 20, bounds: target.bounds, alpha: 0)
        let elsewhere = MacControlDriver.HitWindow(processID: 99, windowID: 21,
            bounds: target.bounds.offsetBy(dx: 900, dy: 0), alpha: 1)
        XCTAssertEqual(MacControlDriver.frontmostWindow(at: CGPoint(x: 400, y: 300), in: [invisible, elsewhere, target])?.windowID, 10)
        XCTAssertNil(MacControlDriver.frontmostWindow(at: CGPoint(x: -500, y: -500), in: [target]))
        XCTAssertNil(MacControlDriver.frontmostWindow(at: CGPoint(x: CGFloat.nan, y: 300), in: [target]))
    }

    @MainActor
    func testStopQueuedDuringSynchronousInspectionPreventsThePendingWrite() async throws {
        var stopDelivered = false
        var writes = 0
        var operation: Task<Void, Error>?
        operation = Task { @MainActor in
            // Models an Escape callback queued on the same actor while an AX
            // read blocks. This fixture performs no accessibility or UI action.
            Task { @MainActor in
                stopDelivered = true
                operation?.cancel()
            }
            Self.delayedReadFixture()
            XCTAssertFalse(stopDelivered)
            try await MacControlDriver.withNativeActionCheckpoint { writes += 1 }
        }
        do {
            try await operation?.value
            XCTFail("The queued stop should cancel the native-action checkpoint")
        } catch is CancellationError {
            XCTAssertTrue(stopDelivered)
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testNativeActionCheckpointDeliversAnUncancelledActionExactlyOnce() async throws {
        var writes = 0
        let result = try await MacControlDriver.withNativeActionCheckpoint {
            writes += 1
            return "delivered"
        }
        XCTAssertEqual(result, "delivered")
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testNewWindowObservationWaitsThroughUnreadableAndUnchangedSnapshots() async throws {
        var reads: [[Int]?] = [nil, [1], [1], [1, 2]]
        var waits = 0
        let result = try await MacControlDriver.observeWindowTransition(attempts: 4,
            read: { reads.removeFirst() }, until: { $0.contains(2) }, wait: { waits += 1 })
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.windows, [1, 2])
        XCTAssertEqual(waits, 3)
        XCTAssertTrue(reads.isEmpty)
    }

    @MainActor
    func testCloseWindowObservationWaitsUntilTheSpecificWindowDisappears() async throws {
        var reads: [[Int]?] = [[1, 2], nil, [1, 2], [2]]
        var waits = 0
        let result = try await MacControlDriver.observeWindowTransition(attempts: 5,
            read: { reads.removeFirst() }, until: { !$0.contains(1) }, wait: { waits += 1 })
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.windows, [2])
        XCTAssertEqual(waits, 3)
        XCTAssertTrue(reads.isEmpty)
    }

    @MainActor
    func testInitialSnapshotRetriesFailuresAndAcceptsAnActuallyReadableEmptyList() async throws {
        var attempts = 0
        let result: MacControlDriver.WindowObservation<Int> = try await MacControlDriver.observeWindowTransition(attempts: 3,
            read: {
                attempts += 1
                if attempts == 1 { throw MacControlError.windowStateUnreadable(AXError.cannotComplete.rawValue) }
                if attempts == 2 { return nil }
                return []
            }, until: { _ in true }, wait: {})
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.windows, [])
        XCTAssertNil(result.readError)
        XCTAssertEqual(attempts, 3)
    }

    @MainActor
    func testUnchangedWindowListTimesOutInsteadOfReportingSuccess() async throws {
        var reads = 0
        var waits = 0
        let result = try await MacControlDriver.observeWindowTransition(attempts: 4,
            read: { reads += 1; return [1] }, until: { !$0.contains(1) }, wait: { waits += 1 })
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.windows, [1])
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(waits, 3)
    }

    @MainActor
    func testNoValueDoesNotMeanNoWindowsAndPreservesTheLatestAXFailure() async throws {
        var attempts = 0
        let result = try await MacControlDriver.observeWindowTransition(attempts: 3,
            read: { () throws -> [Int]? in
                attempts += 1
                if attempts == 1 { return [1] }
                throw MacControlError.windowStateUnreadable(AXError.noValue.rawValue)
            }, until: { !$0.contains(1) }, wait: {})
        XCTAssertFalse(result.completed)
        XCTAssertNil(result.windows)
        guard case .windowStateUnreadable(let code) = result.readError else {
            return XCTFail("Keep the failed AX read distinct from a readable empty list")
        }
        XCTAssertEqual(code, AXError.noValue.rawValue)
        XCTAssertTrue(result.readError?.localizedDescription.contains(String(code)) == true)
        XCTAssertEqual(attempts, 3)
    }

    @MainActor
    func testDialogStopsWindowObservationWithoutConsumingLaterSnapshots() async throws {
        var reads = 0
        var waits = 0
        do {
            _ = try await MacControlDriver.observeWindowTransition(attempts: 5,
                read: { () throws -> [Int]? in
                    reads += 1
                    if reads == 2 { throw MacControlError.blockedByDialog }
                    return [1]
                }, until: { !$0.contains(1) }, wait: { waits += 1 })
            XCTFail("A dialog must stop subsequent close actions")
        } catch MacControlError.blockedByDialog {
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(waits, 1)
        }
    }

    @MainActor
    func testCancellationDuringObservationWaitPropagatesBeforeAnotherRead() async throws {
        var reads = 0
        do {
            _ = try await MacControlDriver.observeWindowTransition(attempts: 5,
                read: { reads += 1; return [1] }, until: { !$0.contains(1) },
                wait: { throw CancellationError() })
            XCTFail("Cancellation must not be converted into an uncertain receipt")
        } catch is CancellationError {
            XCTAssertEqual(reads, 1)
        }
    }

    @MainActor
    func testCancellationDuringSuccessfulReadCannotReturnACompletedReceipt() async throws {
        let operation = Task { @MainActor in
            try await MacControlDriver.observeWindowTransition(attempts: 3,
                read: { () -> [Int]? in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return []
                }, until: { $0.isEmpty }, wait: {})
        }
        do {
            _ = try await operation.value
            XCTFail("Cancellation wins even when the final read sees the requested state")
        } catch is CancellationError {}
    }

    @MainActor
    func testVisualNoMatchReplansOnceWhenLoadingContentChanges() async throws {
        let initial = visualSnapshot(text: "正在加载")
        let loaded = visualSnapshot(text: "预定会议")
        var observations = 0, choices = 0
        let (snapshot, choice) = try await MacControlDriver.chooseVisualTarget(from: initial,
            observe: { observations += 1; return loaded }, validate: {}, choose: { snapshot in
                choices += 1
                if choices == 1 { throw JevClientError.unsupportedCommand }
                XCTAssertEqual(snapshot.candidates.first?.text, "预定会议")
                return "visual_1"
            })
        XCTAssertEqual(observations, 1)
        XCTAssertEqual(choices, 2)
        XCTAssertEqual(snapshot.candidates.first?.text, "预定会议")
        XCTAssertEqual(choice, "visual_1")
    }

    @MainActor
    func testVisualNoMatchDoesNotReplanForIDChangesChevronNoiseOrSmallJitter() async throws {
        let initial = visualSnapshot(text: "预定会议丶")
        let equivalent = visualSnapshot(text: "预定会议～", id: "visual_9", x: 0.204)
        var choices = 0, observations = 0
        do {
            _ = try await MacControlDriver.chooseVisualTarget(from: initial,
                observe: { observations += 1; return equivalent }, validate: {}, choose: { _ in
                    choices += 1
                    throw JevClientError.unsupportedCommand
                })
            XCTFail("Unchanged evidence must not trigger another model request")
        } catch JevClientError.unsupportedCommand {
            XCTAssertEqual(observations, 1)
            XCTAssertEqual(choices, 1)
        }
    }

    @MainActor
    func testVisualNoMatchStopsAfterTheOneChangedSnapshotRetry() async throws {
        var observations = 0, choices = 0
        do {
            _ = try await MacControlDriver.chooseVisualTarget(from: visualSnapshot(text: "正在加载"),
                observe: { observations += 1; return self.visualSnapshot(text: "预定会议") }, validate: {}, choose: { _ in
                    choices += 1
                    throw JevClientError.unsupportedCommand
                })
            XCTFail("No recursive model retries")
        } catch JevClientError.unsupportedCommand {
            XCTAssertEqual(observations, 1)
            XCTAssertEqual(choices, 2)
        }
    }

    @MainActor
    func testVisualPlanningDoesNotRetryLowConfidenceNetworkOrInvalidInput() async throws {
        for failure in [JevClientError.lowConfidence(0.4), .networkUnavailable, .invalidInput, .requestFailed(statusCode: 429)] {
            var observations = 0, choices = 0
            do {
                _ = try await MacControlDriver.chooseVisualTarget(from: visualSnapshot(text: "预定会议"),
                    observe: { observations += 1; return self.visualSnapshot(text: "创建会议") }, validate: {}, choose: { _ in
                        choices += 1
                        throw failure
                    })
                XCTFail("Only unsupportedCommand can refresh evidence")
            } catch let error as JevClientError {
                XCTAssertEqual(error, failure)
                XCTAssertEqual(observations, 0)
                XCTAssertEqual(choices, 1)
            }
        }
    }

    @MainActor
    func testVisualRefreshRejectsChangedWindowBeforeAnotherModelChoice() async throws {
        let initial = visualSnapshot(text: "正在加载")
        for changed in [visualSnapshot(text: "预定会议", processID: 43),
                        visualSnapshot(text: "预定会议", windowID: 8),
                        visualSnapshot(text: "预定会议", bounds: CGRect(x: 120, y: 50, width: 700, height: 500))] {
            var choices = 0
            do {
                _ = try await MacControlDriver.chooseVisualTarget(from: initial, observe: { changed }, validate: {}, choose: { _ in
                    choices += 1
                    throw JevClientError.unsupportedCommand
                })
                XCTFail("Changed window identities cannot be replanned")
            } catch MacControlError.visualTargetChanged {
                XCTAssertEqual(choices, 1)
            }
        }
    }

    @MainActor
    func testVisualRefreshPropagatesCancellationAndFocusChangesBeforeReplanning() async throws {
        for cancelled in [false, true] {
            var choices = 0, validations = 0
            do {
                _ = try await MacControlDriver.chooseVisualTarget(from: visualSnapshot(text: "正在加载"),
                    observe: {
                        if cancelled { throw CancellationError() }
                        return self.visualSnapshot(text: "预定会议")
                    }, validate: {
                        validations += 1
                        if !cancelled, validations == 3 { throw MacControlError.focusChanged }
                    }, choose: { _ in choices += 1; throw JevClientError.unsupportedCommand })
                XCTFail("Cancelled or changed-focus planning must stop")
            } catch is CancellationError { XCTAssertTrue(cancelled) }
            catch MacControlError.focusChanged { XCTAssertFalse(cancelled) }
            XCTAssertEqual(choices, 1)
        }
    }

    @MainActor
    private func visualSnapshot(text: String, id: String = "visual_1", x: CGFloat = 0.2,
                                processID: pid_t = 42, windowID: CGWindowID = 7,
                                bounds: CGRect = CGRect(x: 100, y: 50, width: 700, height: 500)) -> VisualControlObserver.Snapshot {
        VisualControlObserver.Snapshot(processID: processID, windowID: windowID, bounds: bounds, candidates: [
            .init(id: id, text: text, normalizedBox: CGRect(x: x, y: 0.2, width: 0.2, height: 0.05))
        ])
    }

    private static func delayedReadFixture() {
        Thread.sleep(forTimeInterval: 0.02)
    }
}
