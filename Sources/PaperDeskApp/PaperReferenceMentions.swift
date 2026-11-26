import Foundation
import PaperDeskCore

struct PaperReferenceLabelGroup {
    let range: NSRange
    let labels: [String]
}

enum PaperReferenceMentions {
    private static let groupExpression = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])\[([Rr]?\d{1,3}(?:(?:\s*[,;]\s*|\s*[-–—]\s*)[Rr]?\d{1,3})*)\](?!\()"#
    )
    private static let labelExpression = try? NSRegularExpression(
        pattern: #"[Rr]?\d{1,3}(?:\s*[-–—]\s*[Rr]?\d{1,3})?"#
    )
    private static let authorYearExpression = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])([A-Z][A-Za-z'’\-]{1,30})(?:\s+(?:et al\.?|(?:&|and)\s+[A-Z][A-Za-z'’\-]+))?\s*,?\s*\(?((?:19|20)\d{2})[a-z]?\)?"#
    )
    private static let inlineCodeExpression = try? NSRegularExpression(pattern: #"`+[^`]*`+"#)
    static func labelGroups(in text: String) -> [PaperReferenceLabelGroup] {
        guard let expression = groupExpression else { return [] }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let contentRange = match.range(at: 1)
            let content = ns.substring(with: contentRange)
            guard let labelExpression else { return nil }
            let labels = labelExpression.matches(in: content, range: NSRange(location: 0, length: (content as NSString).length))
                .compactMap { token -> String? in
                    guard token.numberOfRanges > 0 else { return nil }
                    return (content as NSString).substring(with: token.range)
                }
            let expanded = expandRanges(labels)
            guard !expanded.isEmpty else { return nil }
            return PaperReferenceLabelGroup(range: match.range, labels: expanded)
        }
    }

    static func snapshots(in answer: String, references: [PaperReference]) -> [MessageReference] {
        let prose = proseParts(in: answer)
        guard !prose.isEmpty else { return [] }

        var byLabel: [String: PaperReference] = [:]
        var labelCounts: [String: Int] = [:]
        var byAuthorYear: [String: PaperReference] = [:]
        var authorYearCounts: [String: Int] = [:]
        for reference in references {
            let label = normalizedLabel(reference.displayLabel)
            labelCounts[label, default: 0] += 1
            byLabel[label] = reference
            guard let year = reference.year,
                  let author = reference.firstAuthor ?? ReferenceLookupHelpers.firstAuthor(reference.authors) else { continue }
            let key = authorYearKey(author, year)
            authorYearCounts[key, default: 0] += 1
            byAuthorYear[key] = reference
        }
        for (label, count) in labelCounts where count > 1 { byLabel.removeValue(forKey: label) }
        for (key, count) in authorYearCounts where count > 1 { byAuthorYear.removeValue(forKey: key) }

        var found: [String: PaperReference] = [:]
        for text in prose {
            for group in labelGroups(in: text) {
                for label in group.labels {
                    let key = normalizedLabel(label)
                    if let reference = byLabel[key] { found[reference.id] = reference }
                }
            }
            guard let authorYearExpression else { continue }
            let ns = text as NSString
            for match in authorYearExpression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > 2,
                      let year = Int(ns.substring(with: match.range(at: 2))) else { continue }
                let author = ns.substring(with: match.range(at: 1))
                if let reference = byAuthorYear[authorYearKey(author, year)] { found[reference.id] = reference }
            }
        }
        return found.values.sorted { $0.entryIndex < $1.entryIndex }.map {
            MessageReference(referenceID: $0.id, label: $0.displayLabel, authors: $0.authors,
                             firstAuthor: $0.firstAuthor, title: $0.title, year: $0.year,
                             status: $0.status)
        }
    }

    static func unresolvedLabels(in answer: String, references: [PaperReference]) -> [String] {
        var counts: [String: Int] = [:]
        for reference in references {
            counts[normalizedLabel(reference.displayLabel), default: 0] += 1
        }
        let known = Set(counts.filter { $0.value == 1 }.keys)
        var unresolved = Set<String>()
        for text in proseParts(in: answer) {
            for group in labelGroups(in: text) {
                for label in group.labels where !known.contains(normalizedLabel(label)) {
                    unresolved.insert(label)
                }
            }
        }
        return unresolved.sorted {
            let left = Int($0) ?? Int($0.dropFirst()) ?? Int.max
            let right = Int($1) ?? Int($1.dropFirst()) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
    }

    static func normalizedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    static func authorYearKey(_ author: String, _ year: Int) -> String {
        author.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]"))
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased() + "|" + String(year)
    }

    private static func expandRanges(_ labels: [String]) -> [String] {
        guard let rangeExpression = try? NSRegularExpression(pattern: #"^([Rr]?\d{1,3})\s*[-–—]\s*([Rr]?\d{1,3})$"#) else {
            return labels
        }
        var result: [String] = []
        for label in labels {
            let ns = label as NSString
            guard let match = rangeExpression.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 2 else {
                result.append(label)
                continue
            }
            let first = ns.substring(with: match.range(at: 1))
            let last = ns.substring(with: match.range(at: 2))
            guard !first.lowercased().hasPrefix("r"), !last.lowercased().hasPrefix("r"),
                  let lower = Int(first), let upper = Int(last), upper >= lower, upper - lower <= 50 else {
                continue
            }
            result.append(contentsOf: (lower...upper).map(String.init))
        }
        return result
    }

    private static func proseParts(in answer: String) -> [String] {
        let lines = answer.components(separatedBy: .newlines)
        var fenced: String?
        var visibleLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if isFence {
                let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
                if fenced == nil { fenced = marker }
                else if fenced == marker { fenced = nil }
                continue
            }
            guard fenced == nil else { continue }
            visibleLines.append(removeInlineCode(from: line))
        }
        let source = visibleLines.joined(separator: "\n")
        return LatexDocument.blocks(source).flatMap { block -> [String] in
            guard case .inline(let parts) = block else { return [] }
            return parts.compactMap { part in
                guard case .text(let text) = part else { return nil }
                return text
            }
        }
    }

    private static func removeInlineCode(from line: String) -> String {
        guard let expression = inlineCodeExpression else { return line }
        let ns = line as NSString
        let matches = expression.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }
        let output = NSMutableString(string: line)
        for match in matches.reversed() { output.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length)) }
        return output as String
    }
}

private enum ReferenceLookupHelpers {
    static func firstAuthor(_ authors: String?) -> String? {
        guard let authors else { return nil }
        var cleaned = authors.replacingOccurrences(of: "et al.", with: "")
            .replacingOccurrences(of: "et al", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = cleaned.range(of: #"\s+(?:and|&)\s+"#, options: .regularExpression) {
            cleaned = String(cleaned[..<separator.lowerBound])
        }
        let segment = cleaned.firstIndex(of: ",").map { String(cleaned[..<$0]) } ?? cleaned
        let words = segment.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "’" && $0 != "'" })
        let candidate = words.count > 1 ? String(words[words.count - 1]) : segment
        let normalized = candidate.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,;:()[]")))
        return normalized.count >= 2 ? normalized : nil
    }
}
