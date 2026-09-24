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
/// the caller must reobserve and validate the target before clicking.
@MainActor
final class VisualControlObserver {
    struct Candidate: Equatable, Sendable {
        let id: String
        let text: String
        /// Top-left origin, normalized to the window without its drop shadow.
        let normalizedBox: CGRect
        /// A locally observed colored tile associated one-to-one with the label.
        /// The OCR box remains separate for label identity and revalidation.
        let activationBox: CGRect?

        init(id: String, text: String, normalizedBox: CGRect, activationBox: CGRect? = nil) {
            self.id = id
            self.text = text
            self.normalizedBox = normalizedBox
            self.activationBox = activationBox
        }
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
        let recognition = Task.detached(priority: .userInitiated) { () throws -> ([TextObservation], [CGRect]) in
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
            let observations = (request.results ?? []).compactMap { observation -> TextObservation? in
                guard let text = observation.topCandidates(1).first else { return nil }
                let raw = text.string
                let contentRange = Self.labelContentRange(in: raw)
                // An adjacent dropdown chevron can become 丶 or ～ between
                // frames. Measure the label itself so that changing chevron OCR
                // cannot shift the click point or make an unchanged box stale.
                let contentBox: CGRect?
                if contentRange != raw.startIndex..<raw.endIndex {
                    contentBox = (try? text.boundingBox(for: contentRange))?.boundingBox
                } else { contentBox = nil }
                return TextObservation(text: raw, confidence: text.confidence,
                                       visionBox: contentBox ?? observation.boundingBox)
            }
            let tiles = Self.activationTiles(in: screenshot, bounds: bounds)
            try Task.checkCancellation()
            return (observations, tiles)
        }
        let (observations, tiles) = try await withTaskCancellationHandler {
            try await recognition.value
        } onCancel: { recognition.cancel() }
        try Task.checkCancellation()
        let candidates = Self.candidates(from: observations, bounds: bounds, activationTiles: tiles)
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

    nonisolated static func candidates(from observations: [TextObservation], bounds: CGRect,
                                       activationTiles: [CGRect] = []) -> [Candidate] {
        guard validBounds(bounds) else { return [] }
        let usable: [(String, CGRect)] = observations.compactMap { observation in
            // Vision assigns 0.3 to readable meeting labels when an adjacent
            // chevron becomes part of the line. OCR proposes text only;
            // fresh label uniqueness and geometry checks remain required.
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
        let counts = Dictionary(grouping: usable, by: { labelIdentity($0.0) }).mapValues(\.count)
        let tiles = activationTiles.filter { validNormalizedBox($0) }
        return usable.filter { counts[labelIdentity($0.0)] == 1 }.prefix(60).enumerated().map { index, label in
            let nearby = tiles.filter { tileIsAboveLabel($0, label: label.1, bounds: bounds) }
            // Both directions must be unique, including labels beyond the cap.
            // A nearby icon is evidence only when its label association is clear.
            let activation: CGRect?
            if let tile = nearby.first, nearby.count == 1,
               usable.filter({ tileIsAboveLabel(tile, label: $0.1, bounds: bounds) }).count == 1 {
                activation = tile
            } else { activation = nil }
            return Candidate(id: "visual_\(index + 1)", text: label.0, normalizedBox: label.1, activationBox: activation)
        }
    }

    nonisolated static func screenPoint(for candidate: Candidate, in snapshot: Snapshot) -> CGPoint? {
        guard snapshot.candidates.contains(candidate), validBounds(snapshot.bounds), validNormalizedBox(candidate.normalizedBox),
              candidate.normalizedBox.width * snapshot.bounds.width >= 6,
              candidate.normalizedBox.height * snapshot.bounds.height >= 6 else { return nil }
        let target = candidate.activationBox ?? candidate.normalizedBox
        guard validNormalizedBox(target), target.width * snapshot.bounds.width >= 6,
              target.height * snapshot.bounds.height >= 6 else { return nil }
        return CGPoint(x: snapshot.bounds.minX + target.midX * snapshot.bounds.width,
                       y: snapshot.bounds.minY + target.midY * snapshot.bounds.height)
    }

    /// Exact window identity/frame and a unique label are mandatory. The same
    /// label elsewhere is ambiguous even if one occurrence is close to the old
    /// position. OCR-box jitter is allowed only within eight screen points.
    nonisolated static func revalidatedCandidate(_ selected: Candidate, from previous: Snapshot,
                                                 in current: Snapshot) -> Candidate? {
        guard previous.processID == current.processID, previous.windowID == current.windowID,
              previous.bounds == current.bounds, validBounds(current.bounds),
              previous.candidates.contains(selected),
              previous.candidates.filter({ labelIdentity($0.text) == labelIdentity(selected.text) }).count == 1 else { return nil }
        let matches = current.candidates.filter { labelIdentity($0.text) == labelIdentity(selected.text) }
        guard matches.count == 1, let fresh = matches.first,
              screenPoint(for: selected, in: previous) != nil, screenPoint(for: fresh, in: current) != nil else { return nil }
        guard boxesAgree(selected.normalizedBox, fresh.normalizedBox, bounds: current.bounds) else { return nil }
        switch (selected.activationBox, fresh.activationBox) {
        case (.none, .none): break
        case let (.some(old), .some(new)):
            guard boxesAgree(old, new, bounds: current.bounds) else { return nil }
        default:
            // Never silently switch between a label and an icon after selection.
            return nil
        }
        return fresh
    }

    /// Ignore only known dropdown-chevron OCR suffixes. Keep meaningful
    /// punctuation, digits, and internal characters; this is not fuzzy matching.
    /// Duplicate labels use the same identity, so normalization never turns two
    /// visible choices into a unique target.
    nonisolated static func labelIdentity(_ text: String) -> String {
        String(text[labelContentRange(in: text)])
    }

    nonisolated static func labelContentRange(in text: String) -> Range<String.Index> {
        var start = text.startIndex, end = text.endIndex
        while start < end, text[start].isWhitespace { start = text.index(after: start) }
        while start < end, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        let trimmedEnd = end
        let chevrons: Set<Character> = ["丶", "丷", "~", "～", "⌄", "⌃", "﹀", "∨", "⌵", "▾", "▿", "▼", "˅"]
        while start < end {
            let last = text.index(before: end)
            guard chevrons.contains(text[last]) || text[last].isWhitespace else { break }
            end = last
        }
        // Vision also reads a dropdown chevron as ASCII v/V after Chinese
        // labels. Only strip one after at least two Han characters, immediately
        // following Han; English names such as Dev or Rev remain literal.
        if start < end {
            let last = text.index(before: end)
            if text[last] == "v" || text[last] == "V",
               String(text[start..<last]).range(of: #"\p{Han}.*\p{Han}$"#, options: .regularExpression) != nil {
                end = last
            }
        }
        // Do not normalize symbols or numeric fields such as 1~ into a target.
        let letters = text[start..<end].unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return start..<(letters >= 2 ? end : trimmedEnd)
    }

    /// Finds compact colored components in this window image. This is pixel
    /// evidence, not a guessed offset above text; the label association is made
    /// separately. Neutral controls keep the existing OCR-label fallback.
    nonisolated static func activationTiles(in image: CGImage, bounds: CGRect) -> [CGRect] {
        guard validBounds(bounds), image.width > 0, image.height > 0 else { return [] }
        let reduction = min(1, 1_024 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * reduction).rounded()))
        let height = max(1, Int((CGFloat(image.height) * reduction).rounded()))
        // Do not infer a small target from a severely downsampled capture.
        guard bounds.width / CGFloat(width) <= 3, bounds.height / CGFloat(height) <= 3 else { return [] }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        var mask = [UInt8](repeating: 0, count: width * height)
        for index in mask.indices {
            let offset = index * 4
            let maximum = Int(max(pixels[offset], pixels[offset + 1], pixels[offset + 2]))
            let minimum = Int(min(pixels[offset], pixels[offset + 1], pixels[offset + 2]))
            // Color-independent saturation: blue, green, red, etc. are equal.
            if maximum >= 90, maximum - minimum >= 70, 2 * (maximum - minimum) >= maximum {
                mask[index] = 1
            }
        }
        var components: [CGRect] = []
        var pending: [Int] = []
        for seed in mask.indices where mask[seed] == 1 {
            mask[seed] = 0
            pending.append(seed)
            var count = 0, minX = width, maxX = 0, minY = height, maxY = 0
            while let index = pending.popLast() {
                let x = index % width, y = index / width
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                func append(_ neighbor: Int) {
                    if mask[neighbor] == 1 { mask[neighbor] = 0; pending.append(neighbor) }
                }
                if x > 0 { append(index - 1) }
                if x + 1 < width { append(index + 1) }
                if y > 0 { append(index - width) }
                if y + 1 < height { append(index + width) }
            }
            let pixelWidth = maxX - minX + 1, pixelHeight = maxY - minY + 1
            let pointWidth = CGFloat(pixelWidth) / CGFloat(width) * bounds.width
            let pointHeight = CGFloat(pixelHeight) / CGFloat(height) * bounds.height
            let largestSide = min(240, min(bounds.width, bounds.height) * 0.35)
            // Rounded backgrounds may contain white glyph holes; thin glyphs,
            // separators, large banners and highly elongated shapes are excluded.
            guard min(pointWidth, pointHeight) >= 24, max(pointWidth, pointHeight) <= largestSide,
                  pointWidth / pointHeight >= 0.65, pointWidth / pointHeight <= 1.55,
                  Double(count) / Double(pixelWidth * pixelHeight) >= 0.65 else { continue }
            components.append(CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                                     width: CGFloat(pixelWidth) / CGFloat(width), height: CGFloat(pixelHeight) / CGFloat(height)))
            // Exceeding the bound is an ambiguous/dense image, not permission to
            // discard later components and make an earlier label appear unique.
            if components.count > 120 { return [] }
        }
        return components
    }

    nonisolated private static func tileIsAboveLabel(_ tile: CGRect, label: CGRect, bounds: CGRect) -> Bool {
        let tileWidth = tile.width * bounds.width, tileHeight = tile.height * bounds.height
        let labelWidth = label.width * bounds.width, labelHeight = label.height * bounds.height
        let gap = (label.minY - tile.maxY) * bounds.height
        return gap >= -1 && gap <= min(36, labelHeight * 1.6)
            && tileWidth >= labelWidth * 0.6 && tileWidth <= labelWidth * 2.5
            && tileHeight >= labelHeight * 2 && tileHeight <= labelHeight * 8
            && abs(tile.midX - label.midX) * bounds.width <= min(tileWidth, labelWidth) * 0.2
    }

    nonisolated private static func boxesAgree(_ a: CGRect, _ b: CGRect, bounds: CGRect) -> Bool {
        abs(a.minX - b.minX) * bounds.width <= 8 && abs(a.maxX - b.maxX) * bounds.width <= 8
            && abs(a.minY - b.minY) * bounds.height <= 8 && abs(a.maxY - b.maxY) * bounds.height <= 8
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
