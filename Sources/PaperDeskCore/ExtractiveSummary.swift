import Foundation

public struct ExtractiveCoverage: Codable, Equatable, Sendable {
    public let textPageIndices: [Int]
    public let unavailablePageIndices: [Int]

    public init(textPageIndices: [Int], unavailablePageIndices: [Int]) {
        self.textPageIndices = textPageIndices
        self.unavailablePageIndices = unavailablePageIndices
    }
}

/// One verbatim piece of text taken from a PDF page.
///
/// The model only chooses the `id`. The text shown to the user always comes
/// from this value, which keeps the saved summary tied to the PDF extraction.
public struct ExtractiveSource: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let pageIndex: Int
    public let pageLabel: String
    public let text: String

    public init(id: String, pageIndex: Int, pageLabel: String, text: String) {
        self.id = id
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.text = text
    }
}

public enum ExtractiveSummaryError: LocalizedError, Equatable, Sendable {
    case invalidMaximum
    case emptyResponse
    case invalidJSON
    case emptySelection
    case unknownSource(String)
    case duplicateSource(String)
    case tooManySources

    public var errorDescription: String? {
        switch self {
        case .invalidMaximum: return "摘录数量上限无效"
        case .emptyResponse: return "模型没有返回可核对的摘录编号"
        case .invalidJSON: return "模型返回的摘录编号不是严格 JSON 数组"
        case .emptySelection: return "摘录编号为空"
        case .unknownSource(let id): return "摘录编号不存在：\(id)"
        case .duplicateSource(let id): return "摘录编号重复：\(id)"
        case .tooManySources: return "摘录数量超过上限"
        }
    }
}

/// Builds and verifies a source-first summary.
///
/// `candidates` performs no paraphrasing. It only divides text that already
/// exists on a page into readable, continuous pieces. `verifiedSources`
/// accepts only a JSON array of candidate IDs, so any displayed text can be
/// reconstructed from the original PDF extraction after the model responds.
public enum ExtractiveSummary {
    public static func candidates(pageIndex: Int, pageLabel: String, text: String) -> [ExtractiveSource] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }

        let characters = Array(source)
        guard characters.contains(where: isLetterOrNumber) else { return [] }

        var ends: [Int] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "?" || character == "!" || character == "。" || character == "！" || character == "？" {
                ends.append(includingClosers(after: index, in: characters))
                index += 1
                continue
            }

            if character == ".", isSentencePeriod(at: index, in: characters) {
                ends.append(includingClosers(after: index, in: characters))
            }
            index += 1
        }

        var ranges: [(Int, Int)] = []
        var start = 0
        for end in ends {
            guard end >= start else { continue }
            if let span = usefulSpan(characters, start: start, end: end) {
                ranges.append(span)
            }
            start = end + 1
            while start < characters.count, characters[start].isWhitespace { start += 1 }
        }

        // A page often ends in a sentence continued on the next page. Keep
        // that exact trailing fragment instead of silently dropping it.
        if let span = usefulSpan(characters, start: start, end: characters.count - 1) {
            ranges.append(span)
        }

        // If the page has no sentence punctuation, paragraph boundaries are a
        // useful fallback for headings and extracted display-math blocks.
        if ranges.count == 1, ends.isEmpty {
            let paragraphs = paragraphSpans(characters)
            if paragraphs.count > 1 {
                ranges = paragraphs.compactMap { usefulSpan(characters, start: $0.0, end: $0.1) }
            }
        }

        return ranges.enumerated().map { offset, span in
            ExtractiveSource(
                id: "P\(pageIndex + 1)S\(offset + 1)",
                pageIndex: pageIndex,
                pageLabel: pageLabel,
                text: String(characters[span.0...span.1])
            )
        }
    }

    public static func verifiedSources(response: String, from candidates: [ExtractiveSource], maximum: Int) throws -> [ExtractiveSource] {
        guard maximum > 0 else { throw ExtractiveSummaryError.invalidMaximum }
        let payload = try strictPayload(response)
        guard !payload.isEmpty else { throw ExtractiveSummaryError.emptySelection }
        guard payload.count <= maximum else { throw ExtractiveSummaryError.tooManySources }

        var byID: [String: ExtractiveSource] = [:]
        for candidate in candidates {
            byID[candidate.id] = candidate
        }

        var seen = Set<String>()
        return try payload.map { id in
            guard !id.isEmpty else { throw ExtractiveSummaryError.emptySelection }
            guard seen.insert(id).inserted else { throw ExtractiveSummaryError.duplicateSource(id) }
            guard let source = byID[id] else { throw ExtractiveSummaryError.unknownSource(id) }
            return source
        }
    }

    private static func strictPayload(_ response: String) throws -> [String] {
        var value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ExtractiveSummaryError.emptyResponse }

        if value.hasPrefix("```") {
            guard value.hasSuffix("```") else { throw ExtractiveSummaryError.invalidJSON }
            guard let firstLineEnd = value.firstIndex(of: "\n") else { throw ExtractiveSummaryError.invalidJSON }
            let bodyStart = value.index(after: firstLineEnd)
            let closingStart = value.index(value.endIndex, offsetBy: -3)
            guard bodyStart <= closingStart else { throw ExtractiveSummaryError.invalidJSON }
            value = String(value[bodyStart..<closingStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.contains("```") else { throw ExtractiveSummaryError.invalidJSON }
        }

        guard let data = value.data(using: .utf8) else { throw ExtractiveSummaryError.invalidJSON }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw ExtractiveSummaryError.invalidJSON
        }
    }

    private static func isSentencePeriod(at index: Int, in characters: [Character]) -> Bool {
        let previous = index > 0 ? characters[index - 1] : nil
        let nextIndex = index + 1
        if let previous, let next = nextIndex < characters.count ? characters[nextIndex] : nil,
           isDigit(previous), isDigit(next) {
            return false
        }

        // The middle periods in i.e., e.g., and the final period in common
        // scholarly abbreviations should remain inside the same source span.
        let token = precedingWord(before: index, in: characters).lowercased()
        let abbreviations: Set<String> = [
            "a", "al", "approx", "cf", "dr", "e", "etc", "et", "fig", "figs", "g", "i", "ie", "i.e", "eq", "eqs", "mr", "ms", "no", "p", "pp", "prof", "ref", "refs", "sec", "secs", "vs", "vol"
        ]
        if abbreviations.contains(token) { return false }

        var cursor = index + 1
        while cursor < characters.count, isClosingDelimiter(characters[cursor]) { cursor += 1 }
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        guard cursor < characters.count else { return true }
        let next = characters[cursor]
        if next == "[" || next == "{" { return false }
        if isLowercase(next) { return false }
        if isLetterOrNumber(next) || next == "\"" || next == "'" || next == "(" { return true }
        return false
    }

    private static func precedingWord(before index: Int, in characters: [Character]) -> String {
        guard index > 0 else { return "" }
        var end = index
        while end > 0, !isLetterOrNumber(characters[end - 1]), characters[end - 1] != "." { end -= 1 }
        var start = end
        while start > 0, isLetterOrNumber(characters[start - 1]) { start -= 1 }
        return String(characters[start..<end])
    }

    private static func includingClosers(after index: Int, in characters: [Character]) -> Int {
        var end = index
        var cursor = index + 1
        while cursor < characters.count, isClosingDelimiter(characters[cursor]) {
            end = cursor
            cursor += 1
        }
        return end
    }

    private static func isClosingDelimiter(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == ")" || character == "]" || character == "}" || character == "”" || character == "’"
    }

    private static func usefulSpan(_ characters: [Character], start: Int, end: Int) -> (Int, Int)? {
        guard start <= end, !characters.isEmpty else { return nil }
        var left = start
        var right = min(end, characters.count - 1)
        while left <= right, characters[left].isWhitespace { left += 1 }
        while right >= left, characters[right].isWhitespace { right -= 1 }
        guard left <= right else { return nil }
        let text = String(characters[left...right])
        guard text.contains(where: isLetterOrNumber) else { return nil }
        return (left, right)
    }

    private static func paragraphSpans(_ characters: [Character]) -> [(Int, Int)] {
        var spans: [(Int, Int)] = []
        var start = 0
        var index = 0
        while index < characters.count {
            if characters[index] == "\n" || characters[index] == "\r" {
                var cursor = index
                var lineBreaks = 0
                while cursor < characters.count, characters[cursor] == "\n" || characters[cursor] == "\r" {
                    lineBreaks += 1
                    cursor += 1
                }
                if lineBreaks >= 2 {
                    while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" { cursor += 1 }
                    spans.append((start, index - 1))
                    start = cursor
                    index = cursor
                    continue
                }
            }
            index += 1
        }
        spans.append((start, characters.count - 1))
        return spans
    }

    private static func isLetterOrNumber(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isLowercase(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
    }
}
