import Foundation

/// Whether a bibliography entry still needs an AI or human check.
public enum PaperReferenceStatus: String, Codable, Sendable {
    case unverified
    case verified
}

/// Where a bibliography entry came from.
public enum PaperReferenceSource: String, Codable, Sendable {
    case pdfBibliography = "pdf_bibliography"
    case aiExternal = "ai_external"
    case manual
}

/// One bibliography entry attached to a paper. Local extraction fills what it
/// can and leaves the rest empty; `status` stays `unverified` until an AI or the
/// user confirms the metadata.
public struct PaperReference: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var paperID: String
    /// The label used in prose: the bibliography number (`12`) or a generated
    /// `R1`, `R2`, ... when the paper uses an unnumbered style.
    public var label: String
    public var entryIndex: Int
    public var authors: String?
    public var firstAuthor: String?
    public var title: String?
    public var year: Int?
    public var venue: String?
    public var doi: String?
    public var arxivID: String?
    public var url: String?
    public var bibtex: String?
    public var rawText: String
    public var status: PaperReferenceStatus
    public var source: PaperReferenceSource
    public var pageIndex: Int
    public var pageLabel: String
    public var parserVersion: Int
    public var fingerprint: String?
    public var verifiedAt: Date?
    public var verifiedBy: String?
    public var evidenceURL: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, paperID: String, label: String, entryIndex: Int,
                authors: String? = nil, firstAuthor: String? = nil, title: String? = nil,
                year: Int? = nil, venue: String? = nil, doi: String? = nil, arxivID: String? = nil,
                url: String? = nil, bibtex: String? = nil, rawText: String,
                status: PaperReferenceStatus = .unverified,
                source: PaperReferenceSource = .pdfBibliography,
                pageIndex: Int, pageLabel: String, parserVersion: Int,
                fingerprint: String? = nil, verifiedAt: Date? = nil, verifiedBy: String? = nil,
                evidenceURL: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.paperID = paperID
        self.label = label
        self.entryIndex = entryIndex
        self.authors = authors
        self.firstAuthor = firstAuthor
        self.title = title
        self.year = year
        self.venue = venue
        self.doi = doi
        self.arxivID = arxivID
        self.url = url
        self.bibtex = bibtex
        self.rawText = rawText
        self.status = status
        self.source = source
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.parserVersion = parserVersion
        self.fingerprint = fingerprint
        self.verifiedAt = verifiedAt
        self.verifiedBy = verifiedBy
        self.evidenceURL = evidenceURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isVerified: Bool { status == .verified }

    /// A short, stable label for chips and matching.
    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "R\(entryIndex + 1)" : trimmed
    }
}

/// Indexing state for one paper, shown while the background parser runs and
/// when the PDF has no usable reference section.
public struct PaperReferenceIndex: Equatable, Sendable {
    public enum State: String, Sendable {
        case indexing, ready, unavailable, failed
    }

    public var paperID: String
    public var state: State
    public var parserVersion: Int
    public var headingPageIndex: Int?
    public var entryCount: Int
    public var indexedAt: Date?
    public var error: String?

    public init(paperID: String, state: State, parserVersion: Int,
                headingPageIndex: Int? = nil, entryCount: Int = 0,
                indexedAt: Date? = nil, error: String? = nil) {
        self.paperID = paperID
        self.state = state
        self.parserVersion = parserVersion
        self.headingPageIndex = headingPageIndex
        self.entryCount = entryCount
        self.indexedAt = indexedAt
        self.error = error
    }
}

/// Page text passed to the parser. The app reads PDFKit pages off the main
/// thread and keeps the page identity so entries can point back to the PDF.
public struct PaperReferencePageText: Equatable, Sendable {
    public var pageIndex: Int
    public var pageLabel: String
    public var text: String

    public init(pageIndex: Int, pageLabel: String, text: String) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.text = text
    }
}

/// One parsed bibliography entry before it is stored.
public struct PaperReferenceDraft: Equatable, Sendable {
    public var label: String
    public var entryIndex: Int
    public var authors: String?
    public var firstAuthor: String?
    public var title: String?
    public var year: Int?
    public var venue: String?
    public var doi: String?
    public var arxivID: String?
    public var url: String?
    public var rawText: String
    public var pageIndex: Int
    public var pageLabel: String
    public var fingerprint: String

    public init(label: String, entryIndex: Int, authors: String?, firstAuthor: String?,
                title: String?, year: Int?, venue: String?, doi: String?, arxivID: String?,
                url: String?, rawText: String, pageIndex: Int, pageLabel: String,
                fingerprint: String) {
        self.label = label
        self.entryIndex = entryIndex
        self.authors = authors
        self.firstAuthor = firstAuthor
        self.title = title
        self.year = year
        self.venue = venue
        self.doi = doi
        self.arxivID = arxivID
        self.url = url
        self.rawText = rawText
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.fingerprint = fingerprint
    }
}

/// Heuristic reference-section parser. It intentionally keeps `rawText` for
/// every entry: local extraction is allowed to leave unknown fields empty and
/// an AI can verify them later.
public enum PaperReferenceParser {
    public static let version = 5
    public static let maximumEntries = 500

    private struct PageSpan {
        let pageIndex: Int
        let pageLabel: String
        let start: Int
        let end: Int
    }

    private static let headingExpression = try? NSRegularExpression(
        pattern: #"(?im)^[ \t]*(?:\d{1,2}[.)]?[ \t]*)?(?:references(?: cited| and notes)?|bibliography|works cited|literature cited|参考文献|引用文献)[ \t]*$"#
    )
    // A bibliography is normally followed by appendices or supplemental
    // material. Those sections often use their own numbered lists, so keep
    // them out of the bibliography before looking for numbered entries.
    private static let trailingSectionExpression = try? NSRegularExpression(
        pattern: #"(?im)^[ \t]*(?:appendix(?:es)?|appendices|supplement(?:ary|al)?|supporting[ \t]+(?:information|materials?))(?:[ \t]+[^\r\n]*|[ \t]*[:.][^\r\n]*)?[ \t]*$"#
    )
    private static let numberedEntryExpression = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:\[(\d{1,3})\]|(\d{1,3})[.)])[ \t]+"#
    )
    private static let doiExpression = try? NSRegularExpression(
        pattern: #"10\.\d{4,9}/[^\s<>"”’]+"#, options: [.caseInsensitive]
    )
    private static let arxivExpression = try? NSRegularExpression(
        pattern: #"(?:arxiv[:\s]*|arxiv\.org/(?:abs|pdf)/)(\d{4}\.\d{4,5})(v\d+)?"#, options: [.caseInsensitive]
    )
    private static let oldArxivExpression = try? NSRegularExpression(
        pattern: #"\b((?:hep-ph|hep-th|gr-qc|astro-ph|cond-mat|nucl-th|nucl-ex|quant-ph|math-ph|physics|cs|q-bio|q-fin|stat|eess|econ)/\d{7}(?:v\d+)?)\b"#,
        options: [.caseInsensitive]
    )
    private static let quotedTitleExpression = try? NSRegularExpression(
        pattern: #"^(.{2,240}?)[,\.]?\s*[“"](.{2,400}?)[”"]"#, options: [.dotMatchesLineSeparators]
    )
    private static let urlExpression = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"”’]+"#, options: [.caseInsensitive]
    )
    private static let parentheticalYearExpression = try? NSRegularExpression(
        pattern: #"\((1[89]\d{2}|20\d{2})[a-z]?\)"#, options: [.caseInsensitive]
    )
    private static let yearExpression = try? NSRegularExpression(
        pattern: #"\b(1[89]\d{2}|20\d{2})[a-z]?\b"#, options: [.caseInsensitive]
    )
    private static let authorYearExpression = try? NSRegularExpression(
        pattern: #"^(.{2,240}?)\s*\(((?:19|20)\d{2})[a-z]?\)\.?\s*(.+)$"#, options: [.dotMatchesLineSeparators]
    )
    private static let authorPeriodExpression = try? NSRegularExpression(
        pattern: #"^(.{2,240}?)\.\s+(.{2,400}?)(?:\.\s|$)"#, options: [.dotMatchesLineSeparators]
    )

    public static func entries(from pages: [PaperReferencePageText]) -> [PaperReferenceDraft] {
        guard !pages.isEmpty else { return [] }
        var spans: [PageSpan] = []
        var combined = ""
        for page in pages {
            let start = combined.utf16.count
            combined += page.text
            if !combined.hasSuffix("\n") { combined += "\n" }
            spans.append(PageSpan(pageIndex: page.pageIndex, pageLabel: page.pageLabel,
                                  start: start, end: combined.utf16.count))
        }
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let ns = combined as NSString
        let heading = headingMatch(in: ns)
        let sectionRange: NSRange
        if let heading {
            let sectionStart = heading.range.upperBound
            let sectionEnd = trailingSectionStart(in: ns, after: sectionStart) ?? ns.length
            sectionRange = NSRange(location: heading.range.upperBound,
                                   length: max(0, sectionEnd - sectionStart))
        } else {
            sectionRange = NSRange(location: 0, length: ns.length)
        }
        let section = ns.substring(with: sectionRange) as NSString
        var entries: [(raw: String, marker: String?, range: NSRange)] = []
        let numbered = numberedEntryMatches(in: section)
        // A heading gives a lone numbered item enough context to be a real
        // bibliography entry. Without a heading, retain the two-marker
        // heuristic so an isolated list number in end matter is not promoted
        // to a reference by accident.
        if numbered.count >= 2 || (heading != nil && !numbered.isEmpty) {
            for (index, match) in numbered.enumerated() {
                let start = match.range.location
                let end = index + 1 < numbered.count ? numbered[index + 1].range.location : section.length
                let raw = section.substring(with: NSRange(location: start, length: max(0, end - start)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let marker = numberFromMatch(match, in: section)
                entries.append((raw, marker, NSRange(location: sectionRange.location + start,
                                                     length: max(0, end - start))))
            }
        } else {
            let paragraphs = splitParagraphs(section as String)
            var cursor = 0
            for paragraph in paragraphs {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 24 else { cursor += paragraph.utf16.count; continue }
                let location = section.range(of: trimmed).location
                let absolute = location == NSNotFound ? cursor : location
                entries.append((trimmed, nil, NSRange(location: sectionRange.location + absolute,
                                                      length: trimmed.utf16.count)))
                cursor = absolute + trimmed.utf16.count
            }
            if entries.isEmpty {
                let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 24 {
                    entries.append((trimmed, nil, sectionRange))
                }
            }
        }

        let result = entries.prefix(maximumEntries).enumerated().compactMap { index, entry -> PaperReferenceDraft? in
            let cleaned = stripMarker(entry.raw, marker: entry.marker)
            let normalized = normalize(cleaned)
            guard normalized.count >= 12 else { return nil }
            let page = pageSpan(for: entry.range.location, spans: spans)
            let parsed = parseFields(normalized)
            let label: String
            if let marker = entry.marker, !marker.isEmpty {
                label = marker
            } else {
                label = "R\(index + 1)"
            }
            return PaperReferenceDraft(
                label: label, entryIndex: index,
                authors: parsed.authors, firstAuthor: firstAuthor(parsed.authors),
                title: parsed.title, year: parsed.year, venue: parsed.venue,
                doi: parsed.doi, arxivID: parsed.arxivID, url: parsed.url,
                rawText: entry.raw.trimmingCharacters(in: .whitespacesAndNewlines),
                pageIndex: page.pageIndex, pageLabel: page.pageLabel,
                fingerprint: fingerprint(doi: parsed.doi, arxivID: parsed.arxivID,
                                         title: parsed.title, authors: parsed.authors,
                                         year: parsed.year, raw: normalized))
        }
        return result
    }

    private struct ParsedFields {
        var authors: String?
        var title: String?
        var year: Int?
        var venue: String?
        var doi: String?
        var arxivID: String?
        var url: String?
    }

    private static func parseFields(_ text: String) -> ParsedFields {
        var fields = ParsedFields()
        let ns = text as NSString
        var remainder = text

        if let expression = doiExpression,
           let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range)
            fields.doi = trimLinkPunctuation(raw)
        }
        if let expression = arxivExpression,
           let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           match.range(at: 1).location != NSNotFound {
            let id = ns.substring(with: match.range(at: 1))
            let version = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            fields.arxivID = id + version
        }
        if let expression = urlExpression,
           let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range)
            fields.url = trimLinkPunctuation(raw)
        }
        if fields.arxivID == nil, let expression = oldArxivExpression,
           let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           match.numberOfRanges > 1 {
            fields.arxivID = ns.substring(with: match.range(at: 1))
        }
        let yearText = text
            .replacingOccurrences(of: #"https?://[^\s<>\"”’]+"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"10\.\d{4,9}/[^\s<>\"”’]+"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?:arxiv[:\s]*|arxiv\.org/(?:abs|pdf)/)\d{4}\.\d{4,5}(?:v\d+)?"#, with: " ", options: [.regularExpression, .caseInsensitive])
        fields.year = year(in: yearText)

        var quotedTitle = false
        if let expression = quotedTitleExpression,
           let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
           match.numberOfRanges >= 3,
           let authors = cleanAuthors(ns.substring(with: match.range(at: 1))),
           let title = cleanQuotedTitle(ns.substring(with: match.range(at: 2))) {
            fields.authors = authors
            fields.title = title
            quotedTitle = true
        }

        if !quotedTitle {
            if let expression = authorYearExpression,
               let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 4 {
                fields.authors = cleanAuthors(ns.substring(with: match.range(at: 1)))
                fields.year = Int(ns.substring(with: match.range(at: 2))) ?? fields.year
                remainder = ns.substring(with: match.range(at: 3))
            } else if let expression = authorPeriodExpression,
                      let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                      match.numberOfRanges >= 3 {
                fields.authors = cleanAuthors(ns.substring(with: match.range(at: 1)))
                remainder = ns.substring(with: match.range(at: 2))
            } else {
                remainder = text
            }
            fields.title = cleanTitle(remainder, authors: fields.authors)
        }
        fields.venue = venue(in: remainder, title: fields.title)
        return fields
    }

    private static func year(in text: String) -> Int? {
        let maximum = Calendar.current.component(.year, from: Date()) + 1
        func valid(_ value: Int?) -> Int? {
            guard let value, value >= 1800, value <= maximum else { return nil }
            return value
        }
        if let expression = parentheticalYearExpression,
           let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
           match.numberOfRanges > 1 {
            return valid(Int((text as NSString).substring(with: match.range(at: 1))))
        }
        guard let expression = yearExpression else { return nil }
        let ns = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges > 1 else { return nil }
        return valid(Int(ns.substring(with: last.range(at: 1))))
    }

    private static func cleanAuthors(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;: ")))
        guard trimmed.count >= 2, trimmed.count <= 240 else { return nil }
        let lowered = trimmed.lowercased()
        guard !lowered.contains("http"), !lowered.contains("www."),
              !lowered.contains("doi.org"), !lowered.contains("arxiv") else { return nil }
        return trimmed
    }

    private static func firstAuthor(_ authors: String?) -> String? {
        guard let authors else { return nil }
        var cleaned = authors.replacingOccurrences(of: "et al.", with: "")
            .replacingOccurrences(of: "et al", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = cleaned.range(of: #"\s+(?:and|&)\s+"#, options: .regularExpression) {
            cleaned = String(cleaned[..<separator.lowerBound])
        }
        let segment: String
        if let comma = cleaned.firstIndex(of: ",") {
            segment = String(cleaned[..<comma])
        } else {
            segment = cleaned
        }
        let words = segment.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "’" && $0 != "'" })
        let candidate = words.count > 1 ? String(words[words.count - 1]) : segment
        let normalized = candidate.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;:()[]")))
        return normalized.count >= 2 ? normalized : nil
    }

    private static func cleanTitle(_ text: String, authors: String?) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"^[\"“”'‘’]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[\"“”'‘’]$"#, with: "", options: .regularExpression)
        if let range = value.range(of: #"\.\s"#, options: .regularExpression) {
            let candidate = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 8 { value = candidate }
        }
        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;: ")))
        guard value.count >= 8, value.count <= 400 else { return nil }
        let lowered = value.lowercased()
        guard !lowered.hasPrefix("http"), !lowered.contains("doi.org"), !lowered.contains("arxiv:") else { return nil }
        if let authors, value == authors { return nil }
        if value.allSatisfy({ $0.isNumber || $0.isWhitespace || $0 == "." || $0 == "-" }) { return nil }
        return value
    }

    private static func cleanQuotedTitle(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[\"“”'‘’]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\"“”'‘’]$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;: ")))
        guard value.count >= 4, value.count <= 400 else { return nil }
        let lowered = value.lowercased()
        guard !lowered.hasPrefix("http"), !lowered.contains("doi.org"), !lowered.contains("arxiv") else { return nil }
        guard !value.allSatisfy({ $0.isNumber || $0.isWhitespace || $0 == "." || $0 == "-" }) else { return nil }
        return value
    }

    private static func venue(in text: String, title: String?) -> String? {
        guard let title,
              let range = text.range(of: title) else { return nil }
        let tail = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = tail.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
        guard value.count >= 2, value.count <= 240 else { return nil }
        let lowered = value.lowercased()
        guard !lowered.hasPrefix("http"), !lowered.contains("doi.org") else { return nil }
        return String(value.prefix(240))
    }

    private static func fingerprint(doi: String?, arxivID: String?, title: String?,
                                    authors: String?, year: Int?, raw: String) -> String {
        let base: String
        if let doi, !doi.isEmpty {
            base = "doi:" + doi.lowercased()
        } else if let arxivID, !arxivID.isEmpty {
            base = "arxiv:" + arxivID.lowercased()
        } else {
            let key = [authors, title, year.map(String.init), raw]
                .compactMap { $0?.lowercased() }
                .joined(separator: "|")
            base = "text:" + normalize(key).filter { $0.isLetter || $0.isNumber }
        }
        return hexHash(base)
    }

    private static func hexHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func pageSpan(for location: Int, spans: [PageSpan]) -> PageSpan {
        spans.last(where: { $0.start <= location }) ?? spans[0]
    }

    private static func headingMatch(in text: NSString) -> NSTextCheckingResult? {
        guard let expression = headingExpression else { return nil }
        return expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)).last
    }

    private static func trailingSectionStart(in text: NSString, after location: Int) -> Int? {
        guard let expression = trailingSectionExpression,
              location < text.length else { return nil }
        let range = NSRange(location: location, length: text.length - location)
        return expression.firstMatch(in: text as String, range: range)?.range.location
    }

    private static func numberedEntryMatches(in text: NSString) -> [NSTextCheckingResult] {
        guard let expression = numberedEntryExpression else { return [] }
        return expression.matches(in: text as String, range: NSRange(location: 0, length: text.length))
    }

    private static func numberFromMatch(_ match: NSTextCheckingResult, in text: NSString) -> String? {
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound {
                return text.substring(with: range)
            }
        }
        return nil
    }

    private static func stripMarker(_ raw: String, marker: String?) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker, !marker.isEmpty {
            value = value.replacingOccurrences(of: #"^[ \t]*\[?"# + NSRegularExpression.escapedPattern(for: marker) + #"\]?[.)]?[ \t]+"#,
                                               with: "", options: .regularExpression)
        }
        return value
    }

    private static func splitParagraphs(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n[ \t]*\n+"#, with: "\n\u{1F}", options: .regularExpression)
        return normalized.components(separatedBy: "\n\u{1F}").flatMap { block -> [String] in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 900 { return trimmed.isEmpty ? [] : [trimmed] }
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            var result: [String] = []
            var current = ""
            for line in lines {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !current.isEmpty,
                   value.range(of: #"^[A-Z][A-Za-z'’\-]+(?:\s*,\s*[A-Z]|\s+et al\.?\s*\(|\s*\((?:19|20)\d{2})"#,
                               options: .regularExpression) != nil {
                    result.append(current)
                    current = value
                } else {
                    current += current.isEmpty ? value : " " + value
                }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimLinkPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}>\"”’"))
    }
}
