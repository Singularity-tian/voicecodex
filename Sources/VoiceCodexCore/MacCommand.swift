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
    case openApp, newTab, newWindow, closeTab, closeWindow, closeAllWindows
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
    struct Request {
        let routingTranscript: String
        let candidates: [String]
        let isTypingEnvelope: Bool
        let hasSecondaryAction: Bool
        let payloadIsQuoted: Bool

        init(routingTranscript: String, candidates: [String], isTypingEnvelope: Bool,
             hasSecondaryAction: Bool = false, payloadIsQuoted: Bool = false) {
            self.routingTranscript = routingTranscript
            self.candidates = candidates
            self.isTypingEnvelope = isTypingEnvelope
            self.hasSecondaryAction = hasSecondaryAction
            self.payloadIsQuoted = payloadIsQuoted
        }
    }

    private static let quotePattern = #""([^"]+)"|“([^”]+)”|(?<![\p{Latin}\p{N}])'([^']+)'(?![\p{Latin}\p{N}])|‘([^’]+)’|「([^」]+)」|『([^』]+)』"#
    private static let secondaryActionPattern = #"(?:(?:(?:and\s+then|then|and)\s+|[,;]\s*)(?:press|hit|click|open|close|launch|send|submit|save|copy|paste|undo|scroll|type|enter)\b|(?:然后|接着|随后|并且|并|再|[,，;；])\s*(?:按|点|打开|关闭|发送|提交|保存|复制|粘贴|撤销|滚动|输入|回车|换行))"#

    /// Parse the instruction around an explicitly dictated payload. Raw payload
    /// text stays local; action and target selection see only the envelope.
    static func request(in transcript: String) -> Request {
        let unchanged = Request(routingTranscript: transcript, candidates: [], isTypingEnvelope: false)
        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard let quotes = try? NSRegularExpression(pattern: quotePattern),
              let markers = try? NSRegularExpression(
                pattern: #"输入|写下|内容是|\b(?:type|enter|insert)\b(?:\s+(?:the\s+)?(?:text|words?)\b)?|\bwrite\b(?:\s+down\b|\s+(?:the\s+)?(?:text|words?)\b)?"#,
                options: .caseInsensitive
              ) else { return unchanged }
        let spans = quotes.matches(in: transcript, range: fullRange)
        guard let marker = markers.matches(in: transcript, range: fullRange).first(where: { candidate in
            guard !spans.contains(where: { NSLocationInRange(candidate.range.location, $0.range) }),
                  let range = Range(candidate.range, in: transcript) else { return false }
            // A word naming the requested control is not a typing verb. Ignore
            // quoted names in the prefix, and stop a click clause at sequencing
            // words so "click ... then type hello" still has a typing envelope.
            let prefix = String(transcript[..<range.lowerBound])
            let controlPrefix = NSMutableString(string: prefix)
            for span in spans.reversed() where NSMaxRange(span.range) <= controlPrefix.length {
                controlPrefix.replaceCharacters(in: span.range, with: String(repeating: " ", count: span.range.length))
            }
            if (controlPrefix as String).range(of: #"(?:(?:\b(?:click|tap|press|hit|select|choose)\b|点击|单击|双击|选择)(?:(?!(?:\b(?:then|and)\b|然后|接着|随后|并且|并|再|[,，;；.!?。！？\n])).)*|(?:按(?:下|一下)?|点(?:一下)?)\s*)$"#,
                                              options: [.regularExpression, .caseInsensitive]) != nil { return false }
            return true
        }), let markerRange = Range(marker.range, in: transcript) else { return unchanged }

        var payloadStart = markerRange.upperBound
        while payloadStart < transcript.endIndex,
              transcript[payloadStart].isWhitespace || transcript[payloadStart] == ":" || transcript[payloadStart] == "：" {
            payloadStart = transcript.index(after: payloadStart)
        }
        let payloadOffset = NSRange(transcript.startIndex..<payloadStart, in: transcript).length
        let firstQuote = spans.first { $0.range.location == payloadOffset }
        // Unquoted "write a poem/email" asks for generation, not verbatim input.
        if transcript[markerRange].lowercased() == "write", firstQuote == nil { return unchanged }
        guard payloadStart < transcript.endIndex else {
            if transcript[markerRange].lowercased() == "enter" { return unchanged }
            return Request(routingTranscript: transcript, candidates: [], isTypingEnvelope: true)
        }

        let payload: String
        let payloadEnd: String.Index
        if let firstQuote, let wholeRange = Range(firstQuote.range, in: transcript) {
            guard let innerRange = (1..<firstQuote.numberOfRanges).compactMap({ Range(firstQuote.range(at: $0), in: transcript) }).first else {
                return Request(routingTranscript: transcript, candidates: [], isTypingEnvelope: true)
            }
            payload = String(transcript[innerRange])
            payloadEnd = wholeRange.upperBound
            // Multiple separately quoted payloads are ambiguous. Keep them all
            // out of routing and require the user to provide one literal span.
            if spans.contains(where: { $0.range.location >= NSMaxRange(firstQuote.range) }) {
                let suffix = String(transcript[payloadEnd...])
                let namesDestination = suffix.range(of: #"^\s*(?:\b(?:in|into|to)\b|在|到|至)\s*"#,
                                                     options: [.regularExpression, .caseInsensitive]) != nil
                if !namesDestination {
                    return Request(routingTranscript: String(transcript[..<payloadStart]) + "[literal text] " + suffix,
                                   candidates: [], isTypingEnvelope: true)
                }
            }
        } else {
            let tail = String(transcript[payloadStart...])
            // Do not swallow a second operation as unquoted literal text.
            if let suffix = tail.range(of: secondaryActionPattern, options: [.regularExpression, .caseInsensitive]) {
                let distance = tail.distance(from: tail.startIndex, to: suffix.lowerBound)
                payloadEnd = transcript.index(payloadStart, offsetBy: distance)
            } else {
                payloadEnd = transcript.endIndex
            }
            payload = String(transcript[payloadStart..<payloadEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let envelope = String(transcript[..<payloadStart]) + "[literal text] " + String(transcript[payloadEnd...])
        let suffix = String(transcript[payloadEnd...])
        let prefix = String(transcript[..<markerRange.lowerBound])
        let hasSecondaryAction = suffix.range(of: secondaryActionPattern, options: [.regularExpression, .caseInsensitive]) != nil ||
            prefix.range(of: secondaryActionPattern, options: [.regularExpression, .caseInsensitive]) != nil ||
            prefix.range(of: #"(?:\b(?:and\s+then|then|and)\s*|(?:然后|接着|随后|并且|并|再))$"#,
                         options: [.regularExpression, .caseInsensitive]) != nil
        return Request(routingTranscript: envelope,
                       candidates: payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [payload],
                       isTypingEnvelope: true,
                       hasSecondaryAction: hasSecondaryAction,
                       payloadIsQuoted: firstQuote != nil)
    }

}
