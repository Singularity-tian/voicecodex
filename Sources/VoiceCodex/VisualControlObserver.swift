import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

enum VisualControlError: LocalizedError {
    case screenRecordingRequired, unavailableWindow, ambiguousWindow, captureFailed, recognitionFailed, noText

    var errorDescription: String? {
        switch self {
        case .screenRecordingRequired:
            return "这个窗口需要在本机识别按钮文字。请在系统设置 → 隐私与安全性 → 屏幕录制中允许 VoiceCodex，然后重试。"
        case .unavailableWindow: return "目标窗口已变化或无法单独截取，请重新说一次指令。"
        case .ambiguousWindow: return "无法唯一确定要识别的目标窗口，这次操作已停止。"
        case .captureFailed: return "无法读取目标窗口的画面，这次操作已停止。"
        case .recognitionFailed: return "目标窗口的本地文字识别失败，请手动操作后重试。"
        case .noText: return "目标窗口没有识别出足够清晰的文字，请手动点击。"
        }
    }
}

/// Reads one explicitly matched window. Images remain in memory, and only
/// bounded OCR labels leave this class. Text is not proof of an enabled control;
/// the caller must confirm, reobserve, and validate the target before clicking.
@MainActor
final class VisualControlObserver {
    struct Candidate: Equatable, Sendable {
        let id: String
        let text: String
        /// Top-left origin, normalized to the window without its drop shadow.
        let normalizedBox: CGRect
    }

    struct Snapshot: Sendable {
        let processID: pid_t
        let windowID: CGWindowID
        /// Screen points in the same top-left coordinate system as AX/CGEvent.
        let bounds: CGRect
        let candidates: [Candidate]
    }

    struct WindowDescriptor: Sendable {
        let processID: pid_t
        let windowID: CGWindowID
        let bounds: CGRect
        let isOnScreen: Bool
        let layer: Int
    }

    struct TextObservation: Sendable {
        let text: String
        let confidence: Float
        /// Vision coordinates have their origin at the bottom left.
        let visionBox: CGRect
    }

    func observe(processID: pid_t, expectedWindowFrame: CGRect) async throws -> Snapshot {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw VisualControlError.screenRecordingRequired }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch is CancellationError { throw CancellationError() }
        catch { throw VisualControlError.captureFailed }
        try Task.checkCancellation()
        let descriptors = content.windows.compactMap { window -> WindowDescriptor? in
            guard let owner = window.owningApplication else { return nil }
            return WindowDescriptor(processID: owner.processID, windowID: window.windowID, bounds: window.frame,
                                    isOnScreen: window.isOnScreen, layer: window.windowLayer)
        }
        let windowID = try Self.matchingWindowID(in: descriptors, processID: processID,
                                               expectedWindowFrame: expectedWindowFrame)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw VisualControlError.unavailableWindow
        }
        let bounds = window.frame
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        // Keep the image bounded and retain enough resolution for small labels.
        let scale = min(2, 4_096 / max(bounds.width, bounds.height))
        configuration.width = max(1, Int((bounds.width * scale).rounded()))
        configuration.height = max(1, Int((bounds.height * scale).rounded()))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        let screenshot: CGImage
        do {
            screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch is CancellationError { throw CancellationError() }
        catch { throw VisualControlError.captureFailed }
        try Task.checkCancellation()
        // Refuse an unexpected padded/cropped output rather than map its OCR
        // coordinates onto a differently sized AX window.
        guard screenshot.width == configuration.width, screenshot.height == configuration.height else {
            throw VisualControlError.captureFailed
        }

        // Vision work runs away from the main actor so Escape/Stop stays usable.
        // A cancelled result is discarded; no native input exists in this class.
        let recognition = Task.detached(priority: .userInitiated) { () throws -> [TextObservation] in
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.003
            do {
                try VNImageRequestHandler(cgImage: screenshot, options: [:]).perform([request])
            } catch { throw VisualControlError.recognitionFailed }
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first else { return nil }
                return TextObservation(text: text.string, confidence: text.confidence, visionBox: observation.boundingBox)
            }
        }
        let observations = try await withTaskCancellationHandler {
            try await recognition.value
        } onCancel: { recognition.cancel() }
        try Task.checkCancellation()
        let candidates = Self.candidates(from: observations, bounds: bounds)
        guard !candidates.isEmpty else { throw VisualControlError.noText }
        return Snapshot(processID: processID, windowID: windowID, bounds: bounds, candidates: candidates)
    }

    nonisolated static func matchingWindowID(in windows: [WindowDescriptor], processID: pid_t,
                                             expectedWindowFrame: CGRect) throws -> CGWindowID {
        guard processID > 0, validBounds(expectedWindowFrame) else { throw VisualControlError.unavailableWindow }
        let matches = windows.filter {
            $0.processID == processID && $0.windowID != 0 && $0.isOnScreen && $0.layer == 0 && validBounds($0.bounds)
                && abs($0.bounds.minX - expectedWindowFrame.minX) <= 2
                && abs($0.bounds.minY - expectedWindowFrame.minY) <= 2
                && abs($0.bounds.width - expectedWindowFrame.width) <= 2
                && abs($0.bounds.height - expectedWindowFrame.height) <= 2
        }
        guard !matches.isEmpty else { throw VisualControlError.unavailableWindow }
        guard matches.count == 1 else { throw VisualControlError.ambiguousWindow }
        return matches[0].windowID
    }

    nonisolated static func candidates(from observations: [TextObservation], bounds: CGRect) -> [Candidate] {
        guard validBounds(bounds) else { return [] }
        let usable: [(String, CGRect)] = observations.compactMap { observation in
            // Vision assigns 0.3 to readable meeting labels when an adjacent
            // chevron becomes part of the line. OCR proposes text only; exact
            // user confirmation and fresh unique/geometry checks remain required.
            guard observation.confidence.isFinite, observation.confidence >= 0.3, observation.confidence <= 1,
                  validNormalizedBox(observation.visionBox) else { return nil }
            let text = observation.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty, text.count <= 160, text.utf8.count <= 640,
                  text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 2,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            let box = CGRect(x: observation.visionBox.minX, y: 1 - observation.visionBox.maxY,
                             width: observation.visionBox.width, height: observation.visionBox.height)
            guard box.width * bounds.width >= 6, box.height * bounds.height >= 6 else { return nil }
            return (text, box)
        }.sorted {
            if $0.1.minY != $1.1.minY { return $0.1.minY < $1.1.minY }
            if $0.1.minX != $1.1.minX { return $0.1.minX < $1.1.minX }
            return $0.0 < $1.0
        }
        // Check every recognized label before applying the candidate cap. A
        // duplicate below the first 60 rows must not make an earlier one appear
        // unique merely because the duplicate was truncated.
        let counts = Dictionary(grouping: usable, by: { $0.0 }).mapValues(\.count)
        return usable.filter { counts[$0.0] == 1 }.prefix(60).enumerated().map {
            Candidate(id: "visual_\($0.offset + 1)", text: $0.element.0, normalizedBox: $0.element.1)
        }
    }

    nonisolated static func screenPoint(for candidate: Candidate, in snapshot: Snapshot) -> CGPoint? {
        guard snapshot.candidates.contains(candidate), validBounds(snapshot.bounds), validNormalizedBox(candidate.normalizedBox),
              candidate.normalizedBox.width * snapshot.bounds.width >= 6,
              candidate.normalizedBox.height * snapshot.bounds.height >= 6 else { return nil }
        return CGPoint(x: snapshot.bounds.minX + candidate.normalizedBox.midX * snapshot.bounds.width,
                       y: snapshot.bounds.minY + candidate.normalizedBox.midY * snapshot.bounds.height)
    }

    /// Exact window identity/frame and a unique label are mandatory. The same
    /// label elsewhere is ambiguous even if one occurrence is close to the old
    /// position. OCR-box jitter is allowed only within eight screen points.
    nonisolated static func revalidatedCandidate(_ selected: Candidate, from previous: Snapshot,
                                                 in current: Snapshot) -> Candidate? {
        guard previous.processID == current.processID, previous.windowID == current.windowID,
              previous.bounds == current.bounds, validBounds(current.bounds),
              previous.candidates.contains(selected),
              previous.candidates.filter({ $0.text == selected.text }).count == 1 else { return nil }
        let matches = current.candidates.filter { $0.text == selected.text }
        guard matches.count == 1, let fresh = matches.first,
              screenPoint(for: selected, in: previous) != nil, screenPoint(for: fresh, in: current) != nil else { return nil }
        let a = selected.normalizedBox, b = fresh.normalizedBox
        guard abs(a.minX - b.minX) * current.bounds.width <= 8,
              abs(a.maxX - b.maxX) * current.bounds.width <= 8,
              abs(a.minY - b.minY) * current.bounds.height <= 8,
              abs(a.maxY - b.maxY) * current.bounds.height <= 8 else { return nil }
        return fresh
    }

    nonisolated private static func validNormalizedBox(_ box: CGRect) -> Bool {
        box.origin.x.isFinite && box.origin.y.isFinite && box.width.isFinite && box.height.isFinite
            && box.width > 0 && box.height > 0 && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
    }

    nonisolated private static func validBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width >= 40 && bounds.height >= 40 && bounds.width <= 16_384 && bounds.height <= 16_384
    }
}
