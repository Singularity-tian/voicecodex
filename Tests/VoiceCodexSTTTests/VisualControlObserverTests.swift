import CoreGraphics
import XCTest
@testable import VoiceCodex

final class VisualControlObserverTests: XCTestCase {
    typealias Observer = VisualControlObserver
    private let bounds = CGRect(x: -1_000, y: 100, width: 800, height: 600)

    func testVisionBottomLeftBecomesScreenTopLeftIncludingNegativeScreenOrigin() throws {
        let candidates = Observer.candidates(from: [.init(text: "  快速会议  ", confidence: 0.95,
                                                         visionBox: CGRect(x: 0.25, y: 0.7, width: 0.2, height: 0.1))], bounds: bounds)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.text, "快速会议")
        XCTAssertEqual(candidate.normalizedBox.minY, 0.2, accuracy: 0.0001)
        let point = try XCTUnwrap(Observer.screenPoint(for: candidate, in: snapshot(candidates)))
        XCTAssertEqual(point.x, -720, accuracy: 0.0001)
        XCTAssertEqual(point.y, 250, accuracy: 0.0001)
    }

    func testLowConfidenceTinyInvalidAndOversizedLabelsAreExcluded() {
        let normal = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
        let observations: [Observer.TextObservation] = [
            .init(text: "included", confidence: 0.3, visionBox: normal),
            .init(text: "uncertain", confidence: 0.299, visionBox: normal),
            .init(text: "invalid confidence", confidence: .nan, visionBox: normal),
            .init(text: "out of range confidence", confidence: 1.01, visionBox: normal),
            .init(text: "丶", confidence: 0.9, visionBox: normal),
            .init(text: "v", confidence: 0.9, visionBox: normal),
            .init(text: "✓", confidence: 1, visionBox: normal),
            .init(text: "tiny", confidence: 1, visionBox: CGRect(x: 0, y: 0, width: 0.001, height: 0.001)),
            .init(text: "outside", confidence: 1, visionBox: CGRect(x: 0.9, y: 0.5, width: 0.2, height: 0.1)),
            .init(text: "negative", confidence: 1, visionBox: CGRect(x: -0.01, y: 0.5, width: 0.2, height: 0.1)),
            .init(text: String(repeating: "x", count: 161), confidence: 1, visionBox: normal),
            .init(text: "control\u{0}character", confidence: 1, visionBox: normal),
        ]
        XCTAssertEqual(Observer.candidates(from: observations, bounds: bounds).map(\.text), ["included"])
    }

    func testReadableMeetingLabelsWithChevronRemainExactConfirmationCandidates() throws {
        // Local Vision recognized these public UI labels at 0.3 with language
        // correction both enabled and disabled. Keep the recognized suffix so
        // selection, confirmation, and reobservation compare the same text.
        let observations: [Observer.TextObservation] = [
            .init(text: "快速会议丶", confidence: 0.3, visionBox: CGRect(x: 0.3, y: 0.67, width: 0.1, height: 0.04)),
            .init(text: "预定会议丶", confidence: 0.3, visionBox: CGRect(x: 0.15, y: 0.4, width: 0.1, height: 0.04)),
        ]
        let candidates = Observer.candidates(from: observations, bounds: bounds)
        XCTAssertEqual(candidates.map(\.text), ["快速会议丶", "预定会议丶"])
        let selected = try XCTUnwrap(candidates.first)
        let original = snapshot(candidates)
        XCTAssertEqual(Observer.revalidatedCandidate(selected, from: original, in: original), selected)
        // A later recognition that changes the exact label cannot reuse consent.
        let changed = Observer.Candidate(id: selected.id, text: "快速会议", normalizedBox: selected.normalizedBox)
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: original, in: snapshot([changed])))
    }

    func testCandidatesAreBoundedAndOrderedByScreenPosition() {
        let observations = (0..<80).reversed().map { index in
            Observer.TextObservation(text: "Label \(index)", confidence: 1,
                                     visionBox: CGRect(x: 0.1, y: 0.98 - Double(index) * 0.01, width: 0.15, height: 0.01))
        }
        let candidates = Observer.candidates(from: observations, bounds: bounds)
        XCTAssertEqual(candidates.count, 60)
        XCTAssertEqual(candidates.first?.text, "Label 0")
        XCTAssertEqual(candidates.last?.id, "visual_60")
    }

    func testDuplicatePastCandidateLimitCannotMakeAnEarlierLabelLookUnique() {
        var observations = (0..<70).map { index in
            Observer.TextObservation(text: "Label \(index)", confidence: 1,
                                     visionBox: CGRect(x: 0.1, y: 0.98 - Double(index) * 0.01, width: 0.15, height: 0.01))
        }
        observations.append(.init(text: "Label 0", confidence: 1,
                                  visionBox: CGRect(x: 0.5, y: 0.05, width: 0.15, height: 0.02)))
        let candidates = Observer.candidates(from: observations, bounds: bounds)
        XCTAssertEqual(candidates.count, 60)
        XCTAssertFalse(candidates.contains { $0.text == "Label 0" })
    }

    func testWindowSelectionRequiresProcessFrameVisibilityAndLayer() throws {
        let windows: [Observer.WindowDescriptor] = [
            .init(processID: 42, windowID: 1, bounds: bounds, isOnScreen: false, layer: 0),
            .init(processID: 42, windowID: 2, bounds: bounds, isOnScreen: true, layer: 3),
            .init(processID: 99, windowID: 3, bounds: bounds, isOnScreen: true, layer: 0),
            .init(processID: 42, windowID: 4, bounds: bounds.offsetBy(dx: 30, dy: 0), isOnScreen: true, layer: 0),
            .init(processID: 42, windowID: 5, bounds: bounds, isOnScreen: true, layer: 0),
        ]
        XCTAssertEqual(try Observer.matchingWindowID(in: windows, processID: 42, expectedWindowFrame: bounds), 5)
        XCTAssertThrowsError(try Observer.matchingWindowID(in: Array(windows.dropLast()), processID: 42, expectedWindowFrame: bounds))
        XCTAssertThrowsError(try Observer.matchingWindowID(in: windows + [windows[4]], processID: 42, expectedWindowFrame: bounds))
    }

    func testUniqueSameTextWithSmallBoxJitterCanBeRevalidated() throws {
        let selected = candidate()
        let fresh = candidate(id: "visual_9", dx: 0.005)
        let match = Observer.revalidatedCandidate(selected, from: snapshot([selected]), in: snapshot([fresh]))
        XCTAssertEqual(try XCTUnwrap(match), fresh)
    }

    func testDuplicateLabelAnywhereRejectsAnOtherwiseNearbyMatch() {
        let selected = candidate()
        let duplicate = candidate(id: "visual_2", dx: 0.4)
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: snapshot([selected]), in: snapshot([selected, duplicate])))
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: snapshot([selected, duplicate]), in: snapshot([selected])))
    }

    func testWindowChangeFrameChangeTextChangeAndMovementBeyondEightPointsReject() {
        let selected = candidate()
        let old = snapshot([selected])
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: old, in: snapshot([selected], processID: 43)))
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: old, in: snapshot([selected], windowID: 11)))
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: old, in: snapshot([selected], frame: bounds.offsetBy(dx: 1, dy: 0))))
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: old, in: snapshot([candidate(text: "加入会议")])))
        XCTAssertNil(Observer.revalidatedCandidate(selected, from: old, in: snapshot([candidate(dx: 0.011)])))
    }

    func testForgedOrOutOfBoundsCandidatesCannotProduceAValidatedPoint() {
        let selected = candidate()
        let forged = candidate(id: "not observed")
        XCTAssertNil(Observer.revalidatedCandidate(forged, from: snapshot([selected]), in: snapshot([selected])))
        XCTAssertNil(Observer.screenPoint(for: forged, in: snapshot([selected])))
        let outside = Observer.Candidate(id: "bad", text: "bad", normalizedBox: CGRect(x: 1, y: 0, width: 0.1, height: 0.1))
        XCTAssertNil(Observer.screenPoint(for: outside, in: snapshot([outside])))
    }

    private func candidate(id: String = "visual_1", text: String = "快速会议", dx: CGFloat = 0) -> Observer.Candidate {
        .init(id: id, text: text, normalizedBox: CGRect(x: 0.2 + dx, y: 0.3, width: 0.15, height: 0.05))
    }

    private func snapshot(_ candidates: [Observer.Candidate], processID: pid_t = 42, windowID: CGWindowID = 10,
                          frame: CGRect? = nil) -> Observer.Snapshot {
        .init(processID: processID, windowID: windowID, bounds: frame ?? bounds, candidates: candidates)
    }
}
