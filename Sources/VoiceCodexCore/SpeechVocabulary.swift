import Foundation

/// Names shared by speech recognition and command routing. Callers look up
/// aliases only for bundle identifiers present in the installed app inventory.
public enum MacApplicationAliases {
    public static func aliases(forBundleIdentifier identifier: String) -> [String] {
        knownAliases[identifier.lowercased()] ?? []
    }

    private static let knownAliases: [String: [String]] = [
        "com.google.chrome": ["Google Chrome", "Chrome", "谷歌浏览器"],
        "com.apple.safari": ["Safari"],
        "com.microsoft.edgemac": ["Microsoft Edge", "Edge"],
        "org.mozilla.firefox": ["Firefox", "火狐浏览器"],
        "com.brave.browser": ["Brave"],
        "com.apple.calculator": ["Calculator", "计算器"],
        "com.apple.stickies": ["Stickies", "便笺", "便签"],
        "com.apple.notes": ["Notes", "Apple Notes", "备忘录"],
        "com.apple.textedit": ["TextEdit", "文本编辑"],
        "com.apple.finder": ["Finder", "访达"],
        "com.apple.systempreferences": ["System Settings", "System Preferences", "系统设置", "系统偏好设置"],
        "com.apple.terminal": ["Terminal", "终端"],
        "com.apple.mail": ["Mail", "Apple Mail", "邮件"],
        "com.apple.reminders": ["Reminders", "提醒事项"],
        "com.apple.ical": ["Calendar", "日历"],
        "com.apple.preview": ["Preview", "预览"],
        "com.apple.mobilesms": ["Messages", "信息"],
        "com.apple.photos": ["Photos", "照片"],
        "com.apple.music": ["Music", "Apple Music", "音乐"],
        "com.apple.appstore": ["App Store", "Mac App Store"],
        "com.apple.activitymonitor": ["Activity Monitor", "活动监视器"],
        "com.apple.freeform": ["Freeform", "无边记"],
        "com.apple.iwork.keynote": ["Keynote"],
        "com.apple.iwork.numbers": ["Numbers"],
        "com.apple.iwork.pages": ["Pages"],
        "com.apple.dt.xcode": ["Xcode"],
        "com.tencent.xinwechat": ["WeChat", "微信"],
        "com.tencent.meeting": ["Tencent Meeting", "TencentMeeting", "腾讯会议"],
        "com.electron.lark": ["Feishu", "Lark", "飞书"],
        "com.microsoft.vscode": ["Visual Studio Code", "VS Code", "VSCode"],
        "com.todesktop.230313mzl4w4u92": ["Cursor"],
        "com.anthropic.claudefordesktop": ["Claude"],
        "md.obsidian": ["Obsidian"],
        "com.cmuxterm.app": ["cmux"],
        "com.mitchellh.ghostty": ["Ghostty"],
        "com.hnc.discord": ["Discord"],
        "com.tinyspeck.slackmacgap": ["Slack"],
        "us.zoom.xos": ["Zoom"],
        "notion.id": ["Notion"],
        "com.lemon.lvoverseas": ["CapCut"],
        "com.timpler.screenstudio": ["Screen Studio"],
        "com.microsoft.outlook": ["Microsoft Outlook", "Outlook"],
        "com.docker.docker": ["Docker"],
        "com.google.android.studio": ["Android Studio"]
    ]
}

/// A bounded Soniox context containing public app names, never window content,
/// file paths, command history, or arbitrary caller-supplied instructions.
public struct SpeechVocabulary: Sendable {
    public static let maximumContextUTF8Bytes = 7_000
    public static let maximumTermLength = 80
    public static let defaultTerms = ["Codex", "GitHub", "README", "worktree", "Swift", "Persom"]

    public let terms: [String]
    public let includedApplicationCount: Int
    public let omittedApplicationCount: Int
    public let contextUTF8ByteCount: Int

    public var context: [String: Any] { Self.context(terms: terms) }

    /// The current app comes first; remaining apps retain the caller's priority
    /// order (normally running apps, then other installed GUI applications).
    public static func build(applications: [MacApplication], currentApplicationID: String?) -> SpeechVocabulary {
        var identifiers = Set<String>()
        let unique = applications.filter { identifiers.insert($0.id.lowercased()).inserted }
        let current = unique.filter {
            guard let currentApplicationID else { return false }
            return $0.id.caseInsensitiveCompare(currentApplicationID) == .orderedSame
        }
        let ordered = current + unique.filter { application in
            !current.contains(where: { $0.id == application.id })
        }
        var terms = defaultTerms
        var seen = Set(terms.map(normalizedKey))
        var byteCount = encodedSize(terms: terms)
        var includedApplications = 0

        for application in ordered {
            var represented = false
            for candidate in [application.name] + MacApplicationAliases.aliases(forBundleIdentifier: application.id) {
                guard let term = sanitizedTerm(candidate) else { continue }
                let key = normalizedKey(term)
                if seen.contains(key) {
                    represented = true
                    continue
                }
                // Appending one term adds its encoded string and one comma.
                // Encode that tiny array so quotes/Unicode escaping are counted
                // exactly without repeatedly encoding the growing vocabulary.
                guard let encodedTerm = try? JSONSerialization.data(withJSONObject: [term]) else { continue }
                let candidateSize = byteCount + encodedTerm.count - 1
                guard candidateSize <= maximumContextUTF8Bytes else { continue }
                terms.append(term)
                seen.insert(key)
                byteCount = candidateSize
                represented = true
            }
            if represented { includedApplications += 1 }
        }
        return SpeechVocabulary(terms: terms,
                                includedApplicationCount: includedApplications,
                                omittedApplicationCount: unique.count - includedApplications,
                                contextUTF8ByteCount: byteCount)
    }

    private static func context(terms: [String]) -> [String: Any] {
        ["general": [
            ["key": "domain", "value": "macOS desktop applications and software development"],
            ["key": "topic", "value": "Voice commands in Chinese and English, including application names"]
        ], "terms": terms]
    }

    private static func encodedSize(terms: [String]) -> Int {
        // Only static keys and strings enter this dictionary, so JSON encoding
        // cannot fail. A failure still causes candidate additions to be refused.
        (try? JSONSerialization.data(withJSONObject: context(terms: terms), options: [.sortedKeys]).count) ?? Int.max
    }

    private static func normalizedKey(_ term: String) -> String {
        term.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func sanitizedTerm(_ candidate: String) -> String? {
        let clean = candidate.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty, clean.count <= maximumTermLength,
              !clean.contains("/"), !clean.contains("\\"),
              !clean.hasPrefix("~"), !clean.lowercased().hasPrefix("file:") else { return nil }
        return clean
    }
}
