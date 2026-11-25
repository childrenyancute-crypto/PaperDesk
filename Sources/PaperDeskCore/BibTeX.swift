import Foundation

/// A small, dependency-free reader for BibTeX files exported by reference
/// managers such as Zotero.
///
/// The parser deliberately keeps the complete source of each entry in
/// `Entry.raw`. This means fields that PaperDesk does not understand yet are
/// still preserved exactly and can be exported again later.
public enum BibTeX {
    public struct Entry: Identifiable, Equatable, Sendable {
        /// The BibTeX citation key, for example `Einstein1905`.
        public let id: String

        /// The complete entry, starting at `@` and ending at its closing
        /// brace/parenthesis. Whitespace and unknown fields are unchanged.
        public let raw: String

        /// The title when one is present, otherwise the citation key.
        public let label: String

        public init(id: String, raw: String, label: String) {
            self.id = id
            self.raw = raw
            self.label = label
        }
    }

    /// Reads ordinary BibTeX entries from `document`.
    ///
    /// `@comment`, `@preamble`, and `@string` blocks are skipped. Text before
    /// the first directive is also ignored, which is useful for exports that
    /// contain a short header. A malformed block is skipped rather than
    /// making all otherwise valid entries unavailable.
    public static func entries(in document: String) throws -> [Entry] {
        var parser = Parser(document: document)
        return parser.parse()
    }

    private struct Parser {
        private let characters: [Character]
        private let count: Int
        private var index: Int = 0

        init(document: String) {
            self.characters = Array(document)
            self.count = characters.count
        }

        mutating func parse() -> [Entry] {
            var result: [Entry] = []

            while index < count {
                if characters[index] == "%" {
                    skipLineComment()
                    continue
                }

                guard let at = nextDirectiveStart() else { break }
                index = at + 1

                let typeStart = index
                while index < count, isDirectiveCharacter(characters[index]) {
                    index += 1
                }
                guard typeStart < index else { continue }

                let type = String(characters[typeStart..<index]).lowercased()
                skipWhitespace()
                guard index < count,
                      characters[index] == "{" || characters[index] == "(" else {
                    // A prose `@name` or an incomplete directive is not a
                    // useful entry. Continue looking for the next directive.
                    continue
                }

                let open = characters[index]
                let close: Character = open == "{" ? "}" : ")"
                let blockStart = index
                index += 1
                guard let end = balancedEnd(open: open, close: close, from: index) else {
                    // There is no reliable boundary after an unclosed block;
                    // keep entries parsed before it and stop gracefully.
                    break
                }

                let blockEnd = end - 1 // index of the matching close character
                let raw = String(characters[at..<end])
                index = end

                if type == "comment" || type == "preamble" || type == "string" {
                    continue
                }

                guard let entry = makeEntry(raw: raw,
                                            bodyStart: blockStart + 1,
                                            bodyEnd: blockEnd) else {
                    continue
                }
                result.append(entry)
            }

            return result
        }

        private mutating func nextDirectiveStart() -> Int? {
            while index < count {
                if characters[index] == "@" {
                    return index
                }
                if characters[index] == "%" {
                    skipLineComment()
                } else {
                    index += 1
                }
            }
            return nil
        }

        private mutating func skipLineComment() {
            while index < count, characters[index] != "\n" {
                index += 1
            }
            if index < count { index += 1 }
        }

        private mutating func skipWhitespace() {
            while index < count, characters[index].isWhitespace {
                index += 1
            }
        }

        private func isDirectiveCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }

        /// Finds the matching outer delimiter while respecting nested braces,
        /// quoted strings, and escaped quote characters.
        private func balancedEnd(open: Character, close: Character, from start: Int) -> Int? {
            var cursor = start
            var depth = 1
            var inQuote = false
            var escaped = false

            while cursor < count {
                let character = characters[cursor]

                if inQuote {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inQuote = false
                    }
                    cursor += 1
                    continue
                }

                if character == "\"" {
                    inQuote = true
                } else if character == open {
                    depth += 1
                } else if character == close {
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                }
                cursor += 1
            }

            return nil
        }

        private func makeEntry(raw: String, bodyStart: Int, bodyEnd: Int) -> Entry? {
            guard bodyStart <= bodyEnd else { return nil }

            var cursor = bodyStart
            skipWhitespace(&cursor, upTo: bodyEnd)
            let keyStart = cursor

            while cursor < bodyEnd, characters[cursor] != "," {
                cursor += 1
            }

            let key = trimmed(String(characters[keyStart..<cursor]))
            guard !key.isEmpty else { return nil }

            var title: String?
            if cursor < bodyEnd { // A comma separates the key from fields.
                cursor += 1
                title = titleField(from: cursor, upTo: bodyEnd)
            }

            return Entry(id: key, raw: raw, label: title.flatMap(nonEmpty) ?? key)
        }

        private func titleField(from start: Int, upTo end: Int) -> String? {
            var cursor = start

            while cursor < end {
                while cursor < end,
                      characters[cursor].isWhitespace || characters[cursor] == "," {
                    cursor += 1
                }
                guard cursor < end else { break }

                let fieldStart = cursor
                while cursor < end,
                      characters[cursor] != "=",
                      characters[cursor] != "," {
                    cursor += 1
                }

                guard cursor < end, characters[cursor] == "=" else {
                    // Skip an unknown malformed fragment and continue with
                    // the next comma-separated field.
                    while cursor < end, characters[cursor] != "," { cursor += 1 }
                    continue
                }

                let fieldName = trimmed(String(characters[fieldStart..<cursor])).lowercased()
                cursor += 1
                let valueStart = cursor
                let valueEnd = fieldValueEnd(from: cursor, upTo: end)

                if fieldName == "title" {
                    return cleanTitle(String(characters[valueStart..<valueEnd]))
                }

                cursor = valueEnd
                if cursor < end, characters[cursor] == "," { cursor += 1 }
            }

            return nil
        }

        /// Scans a field value until a comma at the field's top level. Commas
        /// inside `{...}` or `"..."` are part of the value.
        private func fieldValueEnd(from start: Int, upTo end: Int) -> Int {
            var cursor = start
            var braceDepth = 0
            var inQuote = false
            var escaped = false

            while cursor < end {
                let character = characters[cursor]

                if inQuote {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inQuote = false
                    }
                    cursor += 1
                    continue
                }

                switch character {
                case "\"":
                    inQuote = true
                case "{":
                    braceDepth += 1
                case "}":
                    if braceDepth > 0 { braceDepth -= 1 }
                case ",":
                    if braceDepth == 0 { return cursor }
                default:
                    break
                }
                cursor += 1
            }

            return end
        }

        private func cleanTitle(_ value: String) -> String {
            let pieces = splitConcatenatedValue(value)
                .map { stripOuterDelimiters(trimmed($0)) }
                .filter { !$0.isEmpty }
            let combined = pieces.joined(separator: " ")
            return combined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        private func splitConcatenatedValue(_ value: String) -> [String] {
            let source = Array(value)
            var pieces: [String] = []
            var start = 0
            var cursor = 0
            var braceDepth = 0
            var inQuote = false
            var escaped = false

            while cursor < source.count {
                let character = source[cursor]
                if inQuote {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inQuote = false
                    }
                } else {
                    switch character {
                    case "\"": inQuote = true
                    case "{": braceDepth += 1
                    case "}": if braceDepth > 0 { braceDepth -= 1 }
                    case "#" where braceDepth == 0:
                        pieces.append(String(source[start..<cursor]))
                        start = cursor + 1
                    default: break
                    }
                }
                cursor += 1
            }

            pieces.append(String(source[start..<source.count]))
            return pieces
        }

        private func stripOuterDelimiters(_ value: String) -> String {
            var result = value
            var changed = true

            while changed, result.count >= 2 {
                changed = false
                let source = Array(result)
                guard let first = source.first, let last = source.last else { break }

                if (first == "{" && last == "}" && wrapsWhole(source, open: "{", close: "}")) ||
                    (first == "\"" && last == "\"" && wrapsWhole(source, open: "\"", close: "\"")) {
                    result = String(source.dropFirst().dropLast())
                    changed = true
                }
            }

            return result
        }

        private func wrapsWhole(_ source: [Character], open: Character, close: Character) -> Bool {
            guard source.first == open, source.last == close else { return false }

            var depth = 0
            var inQuote = false
            var escaped = false
            for (offset, character) in source.enumerated() {
                if open == "{" && inQuote {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inQuote = false
                    }
                    continue
                }

                if open == "{" && character == "\"" {
                    inQuote = true
                    continue
                }
                if character == open { depth += 1 }
                if character == close {
                    depth -= 1
                    if depth == 0 { return offset == source.count - 1 }
                }
            }
            return false
        }

        private func skipWhitespace(_ cursor: inout Int, upTo end: Int) {
            while cursor < end, characters[cursor].isWhitespace { cursor += 1 }
        }

        private func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func nonEmpty(_ value: String) -> String? {
            value.isEmpty ? nil : value
        }
    }
}
