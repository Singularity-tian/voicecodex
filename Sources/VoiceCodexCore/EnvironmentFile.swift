import Foundation

/// Reads dotenv data as literals. No command execution or variable interpolation is performed.
public enum EnvironmentFile {
    public struct ParseError: LocalizedError, Equatable {
        public let line: Int
        public let reason: String

        public var errorDescription: String? { "Invalid .env line \(line): \(reason)" }
    }

    public static func parse(_ contents: String) throws -> [String: String] {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [String: String] = [:]
        var lineIndex = 0

        while lineIndex < lines.count {
            let assignmentLine = lineIndex + 1
            var line = String(lines[lineIndex].drop(while: { $0.isWhitespace }))
            if lineIndex == 0, line.hasPrefix("\u{feff}") {
                line = String(line.dropFirst().drop(while: { $0.isWhitespace }))
            }
            if line.isEmpty || line.hasPrefix("#") { lineIndex += 1; continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst(6).drop(while: { $0.isWhitespace }))
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw ParseError(line: assignmentLine, reason: "Expected a KEY=value assignment.")
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard validKey(key) else {
                throw ParseError(line: assignmentLine, reason: "The variable name is invalid.")
            }
            let value = String(line[line.index(after: equals)...].drop(while: { $0.isWhitespace }))
            if let quote = value.first, quote == "\"" || quote == "'" {
                result[key] = try quotedValue(value, quote: quote, lines: lines,
                                              lineIndex: &lineIndex, assignmentLine: assignmentLine)
            } else {
                let characters = Array(value)
                let comment = characters.indices.first { index in
                    characters[index] == "#" && (index == 0 || characters[index - 1].isWhitespace)
                }
                result[key] = String(characters[..<(comment ?? characters.count)])
                    .trimmingCharacters(in: .whitespaces)
            }
            lineIndex += 1
        }
        return result
    }

    private static func validKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        func letterOrUnderscore(_ byte: UInt8) -> Bool {
            byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard let first = bytes.first, letterOrUnderscore(first) else { return false }
        return bytes.dropFirst().allSatisfy { letterOrUnderscore($0) || (48...57).contains($0) }
    }

    private static func quotedValue(_ firstLine: String, quote: Character, lines: [String],
                                    lineIndex: inout Int, assignmentLine: Int) throws -> String {
        var characters = Array(firstLine.dropFirst())
        var index = 0
        var result = ""
        while true {
            while index < characters.count {
                let character = characters[index]
                if character == quote {
                    let suffix = String(characters.dropFirst(index + 1)).trimmingCharacters(in: .whitespaces)
                    guard suffix.isEmpty || suffix.hasPrefix("#") else {
                        throw ParseError(line: lineIndex + 1, reason: "Unexpected text after a quoted value.")
                    }
                    return result
                }
                if quote == "\"", character == "\\", index + 1 < characters.count {
                    index += 1
                    switch characters[index] {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    default: result.append("\\"); result.append(characters[index])
                    }
                } else {
                    result.append(character)
                }
                index += 1
            }
            lineIndex += 1
            guard lineIndex < lines.count else {
                throw ParseError(line: assignmentLine, reason: "A quoted value is not closed.")
            }
            result.append("\n")
            characters = Array(lines[lineIndex])
            index = 0
        }
    }
}
