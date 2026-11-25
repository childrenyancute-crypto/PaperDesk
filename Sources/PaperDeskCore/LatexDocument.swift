import Foundation

/// Splits a mixed prose/LaTeX string into renderable blocks.
///
/// The reader is intentionally limited: it understands inline `$…$` and `\(…\)`,
/// display `$$…$$`, `\[…\]`, and the `equation`/`equation*` environments. Every
/// other construct is left inside the surrounding text.
public enum LatexBlock: Equatable, Sendable {
    case inline([LatexInlinePart])
    case display(formula: String, raw: String)
}

public enum LatexInlinePart: Equatable, Sendable {
    case text(String)
    case math(formula: String, raw: String)
}

public enum LatexDocument {
    public struct Segment: Equatable, Sendable {
        public let formula: String
        public let raw: String
        public let isDisplay: Bool
    }

    /// A math opener that has no matching closer in the source document.
    ///
    /// Unclosed delimiters are kept as plain text by ``blocks(_:)`` so the
    /// reader can still show the original material.  Callers that validate a
    /// reply (for example, the ``check_latex`` tool) can use this diagnostic to
    /// explain why no renderable segment was found.
    public struct DelimiterIssue: Equatable, Sendable {
        public let opening: String
        public let closing: String

        public init(opening: String, closing: String) {
            self.opening = opening
            self.closing = closing
        }

        public var message: String {
            "unclosed math delimiter " + opening + "; expected " + closing
        }
    }

    public static func blocks(_ source: String) -> [LatexBlock] {
        parse(source).blocks
    }

    public static func segments(_ source: String) -> [Segment] {
        segmentsAndDelimiterIssues(source).segments
    }

    /// Parses a document once for callers that need both renderable segments
    /// and delimiter diagnostics (notably `check_latex`).
    static func segmentsAndDelimiterIssues(_ source: String) -> (segments: [Segment], delimiterIssues: [DelimiterIssue]) {
        let result = parse(source)
        let segments = result.blocks.flatMap { block -> [Segment] in
            switch block {
            case .inline(let parts):
                return parts.compactMap { part in
                    guard case .math(let formula, let raw) = part else { return nil }
                    return Segment(formula: formula, raw: raw, isDisplay: false)
                }
            case .display(let formula, let raw):
                return [Segment(formula: formula, raw: raw, isDisplay: true)]
            }
        }
        return (segments, result.delimiterIssues)
    }

    /// Returns recognized math openers that are not closed in `source`.
    ///
    /// This deliberately follows the same limited delimiter grammar as
    /// ``blocks(_:)``.  It does not attempt to parse arbitrary LaTeX; it only
    /// reports a delimiter when the reader would otherwise leave the whole
    /// opener and its remainder as plain text.
    public static func delimiterIssues(_ source: String) -> [DelimiterIssue] {
        parse(source).delimiterIssues
    }

    private struct ParseResult {
        let blocks: [LatexBlock]
        let delimiterIssues: [DelimiterIssue]
    }

    private static func parse(_ source: String) -> ParseResult {
        var blocks: [LatexBlock] = []
        var delimiterIssues: [DelimiterIssue] = []
        var plain = ""
        var inline: [LatexInlinePart] = []
        var cursor = source.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            inline.append(.text(plain))
            plain.removeAll(keepingCapacity: true)
        }

        func flushInline() {
            guard !inline.isEmpty else { return }
            blocks.append(.inline(inline))
            inline.removeAll(keepingCapacity: true)
        }

        while cursor < source.endIndex {
            if let match = displayOpening(in: source, at: cursor) {
                guard let end = source.range(of: match.close, range: match.bodyStart..<source.endIndex) else {
                    delimiterIssues.append(DelimiterIssue(
                        opening: String(source[cursor..<match.bodyStart]),
                        closing: match.close
                    ))
                    plain.append(contentsOf: source[cursor...])
                    break
                }
                flushPlain()
                flushInline()
                blocks.append(.display(formula: String(source[match.bodyStart..<end.lowerBound]),
                                       raw: String(source[cursor..<end.upperBound])))
                cursor = end.upperBound
                continue
            }

            if source[cursor] == "$" && !isEscaped(source, at: cursor) {
                let next = source.index(after: cursor)
                if next < source.endIndex && source[next] == "$" {
                    let bodyStart = source.index(after: next)
                    if let end = source.range(of: "$$", range: bodyStart..<source.endIndex) {
                        flushPlain()
                        flushInline()
                        blocks.append(.display(formula: String(source[bodyStart..<end.lowerBound]),
                                               raw: String(source[cursor..<end.upperBound])))
                        cursor = end.upperBound
                        continue
                    }

                    delimiterIssues.append(DelimiterIssue(opening: "$$", closing: "$$"))
                    plain.append(contentsOf: source[cursor...])
                    break
                }
            }

            if source[cursor] == "$" && !isEscaped(source, at: cursor) {
                let bodyStart = source.index(after: cursor)
                if let end = closingDollar(in: source, from: bodyStart) {
                    flushPlain()
                    inline.append(.math(formula: String(source[bodyStart..<end]),
                                        raw: String(source[cursor..<source.index(after: end)])))
                    cursor = source.index(after: end)
                    continue
                }

                // Only treat a number-leading dollar as currency after we
                // have confirmed that it has no matching delimiter.  This
                // preserves valid expressions such as "$2 + 1$".
                if looksLikeCurrency(in: source, at: cursor) {
                    plain.append(source[cursor])
                    cursor = source.index(after: cursor)
                    continue
                }

                delimiterIssues.append(DelimiterIssue(opening: "$", closing: "$"))
            }

            if source[cursor] == "\\" {
                let next = source.index(after: cursor)
                if next < source.endIndex && source[next] == "(" {
                    let bodyStart = source.index(after: next)
                    if let end = source.range(of: "\\)", range: bodyStart..<source.endIndex) {
                        flushPlain()
                        inline.append(.math(formula: String(source[bodyStart..<end.lowerBound]),
                                            raw: String(source[cursor..<end.upperBound])))
                        cursor = end.upperBound
                        continue
                    }

                    delimiterIssues.append(DelimiterIssue(opening: "\\(", closing: "\\)"))
                }
            }

            plain.append(source[cursor])
            cursor = source.index(after: cursor)
        }
        flushPlain()
        flushInline()
        return ParseResult(
            blocks: blocks.isEmpty ? [.inline([.text(source)])] : blocks,
            delimiterIssues: delimiterIssues
        )
    }

    private struct Opening {
        let close: String
        let bodyStart: String.Index
    }

    private static func displayOpening(in source: String, at index: String.Index) -> Opening? {
        let displayBracketOpening = "\\["
        if source[index...].hasPrefix(displayBracketOpening) {
            return Opening(close: "\\]", bodyStart: source.index(index, offsetBy: displayBracketOpening.count))
        }
        let equationOpening = "\\begin{equation}"
        if source[index...].hasPrefix(equationOpening) {
            return Opening(close: "\\end{equation}", bodyStart: source.index(index, offsetBy: equationOpening.count))
        }
        let starredEquationOpening = "\\begin{equation*}"
        if source[index...].hasPrefix(starredEquationOpening) {
            return Opening(close: "\\end{equation*}", bodyStart: source.index(index, offsetBy: starredEquationOpening.count))
        }
        return nil
    }

    private static func closingDollar(in source: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < source.endIndex {
            if source[cursor] == "$" && !isEscaped(source, at: cursor) { return cursor }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func looksLikeCurrency(in source: String, at index: String.Index) -> Bool {
        var cursor = source.index(after: index)
        guard cursor < source.endIndex, source[cursor].isNumber else { return false }

        var sawNumber = false
        while cursor < source.endIndex {
            let character = source[cursor]
            if character.isNumber {
                sawNumber = true
            } else if character != "," && character != "." {
                break
            }
            cursor = source.index(after: cursor)
        }
        guard sawNumber else { return false }
        return cursor == source.endIndex || source[cursor].isWhitespace
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        var count = 0
        var cursor = index
        while cursor > source.startIndex {
            cursor = source.index(before: cursor)
            if source[cursor] != "\\" { break }
            count += 1
        }
        return count % 2 == 1
    }
}
