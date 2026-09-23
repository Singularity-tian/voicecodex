import Foundation

public enum MacCommandSequenceError: LocalizedError, Equatable {
    case emptyCommand, malformedSequence, unbalancedQuotes, tooLong, tooManySteps

    public var errorDescription: String? {
        switch self {
        case .emptyCommand: return "请说出要执行的操作。"
        case .malformedSequence: return "每一步都需要一个完整操作，请用「然后」连接。"
        case .unbalancedQuotes: return "输入文字的引号没有配对，请补全引号后重试。"
        case .tooLong: return "这段指令太长，请缩短后重试。"
        case .tooManySteps: return "一次最多执行 6 步，请分成两次指令。"
        }
    }
}

/// Splits an explicitly ordered request before any step can execute. It neither
/// invents missing steps nor copies an earlier app name into later instructions.
public enum MacCommandSequence {
    public static let maximumSteps = 6
    public static let maximumTranscriptLength = 8_000
    public static let maximumUTF8Bytes = 32_000

    public static func parse(_ transcript: String) throws -> [String] {
        guard transcript.count <= maximumTranscriptLength, transcript.utf8.count <= maximumUTF8Bytes else {
            throw MacCommandSequenceError.tooLong
        }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacCommandSequenceError.emptyCommand
        }

        let masked = NSMutableString(string: transcript)
        for range in try quotedRanges(in: transcript).reversed() {
            // A non-word, non-whitespace sentinel prevents "and <quoted text>
            // then" from turning into a separator that consumes the quote.
            masked.replaceCharacters(in: range, with: String(repeating: "\u{fffc}", count: range.length))
        }
        // A bare 再 must introduce an action, rather than occur in 再见/再次.
        // Combined 然后再 and "and then" are one separator, never empty steps.
        let pattern = #"\b(?:and\s+then|then)\b|(?:然后|接着)(?:\s*再)?|再(?=\s*(?:打开|启动|关闭|新建|创建|点击|单击|双击|点|按|输入|写下|复制|粘贴|撤销|滚动|向上|向下|切换|选择|保存|回车|换行|开始|加入))"#
        let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let separators = expression.matches(in: masked as String, range: NSRange(location: 0, length: masked.length))
        let original = transcript as NSString
        var start = 0
        var steps: [String] = []
        let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；"))
        for end in separators.map(\.range) + [NSRange(location: original.length, length: 0)] {
            let step = original.substring(with: NSRange(location: start, length: end.location - start))
                .trimmingCharacters(in: edgeCharacters)
            // A new streaming utterance can continue the previous one with
            // "然后创建…". Allow one leading connector, never an empty action.
            if start == 0, step.isEmpty, end.length > 0 {
                start = NSMaxRange(end)
                continue
            }
            guard !step.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty else {
                throw MacCommandSequenceError.malformedSequence
            }
            steps.append(step)
            guard steps.count <= maximumSteps else { throw MacCommandSequenceError.tooManySteps }
            start = NSMaxRange(end)
        }
        return steps
    }

    private static func quotedRanges(in transcript: String) throws -> [NSRange] {
        let pairs: [Character: Character] = ["\"": "\"", "'": "'", "“": "”", "‘": "’", "「": "」", "『": "』"]
        let closing = Set(pairs.values)
        var stack: [Character] = []
        var outerStart: String.Index?
        var ranges: [NSRange] = []
        var index = transcript.startIndex
        while index < transcript.endIndex {
            let character = transcript[index]
            let next = transcript.index(after: index)
            // Apostrophes in don't, John's, and users' are not quote delimiters.
            if ["'", "’", "‘"].contains(character) {
                let previousIsWord = index > transcript.startIndex && isWord(transcript[transcript.index(before: index)])
                let nextIsWord = next < transcript.endIndex && isWord(transcript[next])
                if previousIsWord, nextIsWord || stack.last != character {
                    index = next
                    continue
                }
            }
            if character == "\\", !stack.isEmpty, next < transcript.endIndex {
                index = transcript.index(after: next)
                continue
            }
            if character == stack.last {
                stack.removeLast()
                if stack.isEmpty, let start = outerStart {
                    ranges.append(NSRange(start..<next, in: transcript))
                    outerStart = nil
                }
            } else if let end = pairs[character] {
                if stack.isEmpty { outerStart = index }
                stack.append(end)
            } else if closing.contains(character) {
                throw MacCommandSequenceError.unbalancedQuotes
            }
            index = next
        }
        guard stack.isEmpty else { throw MacCommandSequenceError.unbalancedQuotes }
        return ranges
    }

    private static func isWord(_ character: Character) -> Bool {
        // CJK letters after a closing quote (输入‘你好’然后…) are not contractions.
        String(character).range(of: #"^[\p{Latin}\p{N}]\p{M}*$"#, options: .regularExpression) != nil
    }
}
