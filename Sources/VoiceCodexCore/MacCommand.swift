import Foundation

public struct MacApplication: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The complete action vocabulary the local executor can perform.
public enum MacIntent: String, Codable, CaseIterable, Sendable {
    case openApp, newTab, newWindow, closeWindow, closeAllWindows
    case typeText, pressReturn, copy, paste, undo, scrollDown, scrollUp
    case clickElement, unsupported
}

public struct MacCommand: Codable, Sendable, Equatable {
    public let intent: MacIntent
    public let applicationID: String?
    public let text: String?
    public let confidence: Double

    public init(intent: MacIntent, applicationID: String? = nil,
                text: String? = nil, confidence: Double) {
        self.intent = intent
        self.applicationID = applicationID
        self.text = text
        self.confidence = confidence
    }
}

/// Candidates are verbatim spans, never model-generated text. Quoted spans take
/// priority so instructions such as `type "hello" in the search box` remain exact.
enum MacLiteralText {
    static func candidates(in transcript: String) -> [String] {
        let quoted = captures(
            #""([^"\n]+)"|“([^”\n]+)”|(?<![\p{L}\p{N}])'([^'\n]+)'(?![\p{L}\p{N}])|‘([^’\n]+)’|「([^」\n]+)」|『([^』\n]+)』"#,
            in: transcript
        )
        if !quoted.isEmpty { return unique(quoted) }
        let marked = captures(
            #"(?:输入|写下|内容是)\s*[:：]?\s*(.+)$|(?:^|\s)(?:type(?:\s+(?:the\s+)?(?:text|words?))?|write(?:\s+(?:the\s+)?(?:text|words?))?|says?|search\s+for)\s*[:：]?\s+(.+)$"#,
            in: transcript,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        return unique(marked)
    }

    private static func captures(_ pattern: String, in text: String,
                                 options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text) {
                    let value = String(text[range])
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                }
            }
            return nil
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return Array(values.filter { $0.count <= 8_000 && seen.insert($0).inserted }.prefix(16))
    }
}
