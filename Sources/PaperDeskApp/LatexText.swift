import AppKit
import PaperDeskCore
import SwiftMath
import SwiftUI

private extension NSAttributedString.Key {
    static let paperDeskLink = NSAttributedString.Key("PaperDeskLink")
    static let paperDeskReference = NSAttributedString.Key("PaperDeskReference")
}

/// A lightweight native LaTeX reader for notes and discussion records.
/// SwiftMath typesets formulas with CoreText and a bundled math font.
struct LatexText: View {
    let source: String
    var bodyFont: NSFont = InspectorText.bodyNSFont
    /// Caps each inline block to a number of lines. Notes use this for previews.
    var maxLines: Int? = nil
    /// Maps footnote numbers (`⟦1⟧`) to citation context IDs. Only discussion
    /// answers pass this; notes keep plain text.
    var citationContextIDs: [String: String] = [:]
    var citationColor: Color = .teal
    /// The paper's bibliography index, used to turn `[12]` and author-year
    /// mentions into reference links.
    var references: [PaperReference] = []
    /// Frozen bibliography entries for an archived answer. `nil` enables the
    /// live index for legacy answers, while an empty array keeps old links off.
    var referencedWorks: [MessageReference]? = nil
    var showsReferenceLinks = false
    var allowsSelection = true
    /// Caps the laid-out height of each inline block (used by collapsed replies).
    var heightLimit: CGFloat? = nil
    var onTap: (() -> Void)? = nil
    var onReference: ((String) -> Void)? = nil

    var body: some View {
        let blocks = LatexDocument.blocks(source)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .inline(let parts):
                    LatexInlineText(parts: parts, bodyFont: bodyFont, maxLines: maxLines,
                                    citationContextIDs: citationContextIDs, citationColor: citationColor,
                                    references: references, referencedWorks: referencedWorks,
                                    showsReferenceLinks: showsReferenceLinks,
                                    rawSource: source, allowsSelection: allowsSelection,
                                    heightLimit: heightLimit, onTap: onTap, onReference: onReference)
                case .display(let formula, let raw):
                    LatexDisplayFormula(formula: LatexSubset.normalize(formula), raw: raw, fontSize: 18)
                }
            }
        }
    }
}

/// Lays out prose and math in one selectable text view. Inline formulas are
/// text attachments instead of images embedded in `Text`, so AppKit draws a
/// backing-scale math bitmap on the pixel grid instead of resampling a tiny
/// inline image. Selection, wrapping, citation links, and reference links stay
/// native.
private struct LatexInlineText: NSViewRepresentable {
    let parts: [LatexInlinePart]
    let bodyFont: NSFont
    var maxLines: Int? = nil
    var citationContextIDs: [String: String] = [:]
    var citationColor: Color = .teal
    var references: [PaperReference] = []
    var referencedWorks: [MessageReference]? = nil
    var showsReferenceLinks = false
    var rawSource: String? = nil
    var allowsSelection = true
    var heightLimit: CGFloat? = nil
    var onTap: (() -> Void)? = nil
    var onReference: ((String) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    final class Coordinator: NSObject, NSTextViewDelegate {
        var cacheKey = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LatexTextView {
        let view = LatexTextView()
        view.isEditable = false
        view.drawsBackground = false
        view.linkTextAttributes = [:]
        view.textContainerInset = NSSize.zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        configure(view)
        view.textStorage?.setAttributedString(makeAttributedString())
        context.coordinator.cacheKey = cacheKey
        return view
    }

    func updateNSView(_ view: LatexTextView, context: Context) {
        configure(view)
        let key = cacheKey
        if context.coordinator.cacheKey != key {
            context.coordinator.cacheKey = key
            view.textStorage?.setAttributedString(makeAttributedString())
        }
    }

    /// Sizes are derived from the proposed width and a fixed line cap, never
    /// from the proposed height, so the lazy conversation list does not
    /// oscillate while it lays out collapsed replies.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LatexTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let measured = nsView.measuredSize(width: width)
        guard let heightLimit else { return measured }
        return CGSize(width: width, height: max(min(measured.height, heightLimit), 1))
    }

    private func configure(_ view: LatexTextView) {
        view.onTap = onTap
        view.onReference = onReference
        view.copySource = rawSource
        view.isSelectable = allowsSelection
        view.forwardsClicks = !allowsSelection
        view.onURL = { url in openURL(url) }
        view.onCitation = { contextID in
            guard let url = URL(string: "paperdesk-citation://\(contextID)") else { return }
            openURL(url)
        }
        view.textContainer?.maximumNumberOfLines = maxLines ?? 0
        view.textContainer?.lineBreakMode = maxLines == nil ? .byWordWrapping : .byTruncatingTail
    }

    private var cacheKey: String {
        var key = ""
        for part in parts {
            switch part {
            case .text(let text):
                key += "t\(text.count):\(text)"
            case .math(let formula, let raw):
                key += "m\(formula.count):\(formula)|\(raw.count):\(raw)"
            }
        }
        key += "|\(bodyFont.fontName)|\(bodyFont.pointSize)|\(maxLines ?? 0)|\(showsReferenceLinks)|\(colorScheme == .dark)"
        key += "|\(String(describing: citationColor))"
        for (number, contextID) in citationContextIDs.sorted(by: { $0.key < $1.key }) {
            key += "|\(number)=\(contextID)"
        }
        for reference in references {
            key += "|ref:\(reference.id):\(reference.label):\(reference.firstAuthor ?? ""):\(reference.year.map(String.init) ?? "")"
        }
        for reference in referencedWorks ?? [] {
            key += "|saved-ref:\(reference.referenceID):\(reference.label):\(reference.firstAuthor ?? ""):\(reference.year.map(String.init) ?? "")"
        }
        return key
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
    }

    private func makeAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lookup = ReferenceLookup(references, archived: referencedWorks)
        for part in parts {
            switch part {
            case .text(let text):
                append(text: text, to: result, lookup: lookup)
            case .math(let formula, let raw):
                let normalized = LatexSubset.normalize(formula)
                if let rendered = NativeMathImage.render(normalized, fontSize: 16, mode: .text, color: mathColor,
                                                        bitmapScale: 2) {
                    let attachment = NSTextAttachment()
                    attachment.attachmentCell = MathAttachmentCell(image: rendered.image, descent: rendered.descent)
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    // Keep malformed or unsupported input visible exactly as
                    // recorded instead of silently rewriting the formula.
                    result.append(NSAttributedString(string: raw, attributes: baseAttributes))
                }
            }
        }
        return result
    }

    /// Renders `⟦n⟧` as a superscript citation link. Unknown numbers stay
    /// visible as plain text so a stale record never silently loses content.
    private func append(text: String, to result: NSMutableAttributedString, lookup: ReferenceLookup) {
        guard !citationContextIDs.isEmpty, text.contains("⟦") else {
            appendProse(text, to: result, lookup: lookup)
            return
        }
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "⟦"),
              let close = rest[open...].firstIndex(of: "⟧") {
            let before = rest[..<open]
            if !before.isEmpty { appendProse(String(before), to: result, lookup: lookup) }
            let number = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if let contextID = citationContextIDs[number] {
                let attachment = CitationAttachment(contextID: contextID, label: number,
                                                    tint: NSColor(citationColor))
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: "⟦\(number)⟧", attributes: baseAttributes))
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { appendProse(String(rest), to: result, lookup: lookup) }
    }

    private static let referencePattern = try? NSRegularExpression(pattern: #"\[([^\[\]\n]+)\]\((https://[^\s()]+)\)"#)
    private static let authorYearPattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Z][A-Za-z'’\-]{1,30})(?:\s+(?:et al\.?|(?:&|and)\s+[A-Z][A-Za-z'’\-]+))?\s*,?\s*\(?((?:19|20)\d{2})[a-z]?\)?"#
    )

    private struct ProseMatch {
        enum Payload {
            case link(label: String, url: URL)
            case reference(id: String, chipLabel: String?)
            case referenceGroup([ReferenceLinkTarget])
        }
        let range: NSRange
        let payload: Payload
    }

    private func appendProse(_ text: String, to result: NSMutableAttributedString, lookup: ReferenceLookup) {
        guard !text.isEmpty else { return }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let protected = protectedRanges(in: text)
        var candidates: [ProseMatch] = []

        if showsReferenceLinks, let pattern = Self.referencePattern {
            for match in pattern.matches(in: text, range: fullRange) {
                guard match.numberOfRanges >= 3,
                      let url = URL(string: ns.substring(with: match.range(at: 2))),
                      url.host?.isEmpty == false, url.user == nil, url.password == nil else { continue }
                candidates.append(ProseMatch(range: match.range,
                                             payload: .link(label: ns.substring(with: match.range(at: 1)), url: url)))
            }
        }
        if !references.isEmpty || referencedWorks != nil {
            for group in PaperReferenceMentions.labelGroups(in: text) {
                guard !protected.contains(where: { NSIntersectionRange($0, group.range).length > 0 }) else { continue }
                let targets = group.labels.compactMap { lookup.byLabel[ReferenceLookup.normalizedLabel($0)] }
                guard targets.count == group.labels.count,
                      Set(targets.map(\.id)).count == targets.count else { continue }
                let payload: ProseMatch.Payload = targets.count == 1
                    ? .reference(id: targets[0].id, chipLabel: targets[0].label)
                    : .referenceGroup(targets)
                candidates.append(ProseMatch(range: group.range, payload: payload))
            }
            if let pattern = Self.authorYearPattern {
                for match in pattern.matches(in: text, range: fullRange) where match.numberOfRanges >= 3 {
                    guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                    let surname = ns.substring(with: match.range(at: 1))
                    guard let year = Int(ns.substring(with: match.range(at: 2))),
                          let reference = lookup.byAuthorYear[ReferenceLookup.authorYearKey(surname, year)] else { continue }
                    candidates.append(ProseMatch(range: match.range,
                                                 payload: .reference(id: reference.id, chipLabel: nil)))
                }
            }
        }
        guard !candidates.isEmpty else {
            result.append(NSAttributedString(string: text, attributes: baseAttributes))
            return
        }
        candidates.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length > $1.range.length
        }
        var accepted: [ProseMatch] = []
        for candidate in candidates {
            guard !accepted.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) else { continue }
            accepted.append(candidate)
        }
        accepted.sort { $0.range.location < $1.range.location }
        var cursor = 0
        for match in accepted {
            if match.range.location > cursor {
                let range = NSRange(location: cursor, length: match.range.location - cursor)
                result.append(NSAttributedString(string: ns.substring(with: range), attributes: baseAttributes))
            }
            switch match.payload {
            case .link(let label, let url):
                var attributes = baseAttributes
                attributes[.paperDeskLink] = url
                attributes[.foregroundColor] = NSColor.linkColor
                result.append(NSAttributedString(string: label, attributes: attributes))
            case .reference(let id, let chipLabel):
                if let chipLabel {
                    result.append(NSAttributedString(attachment: ReferenceAttachment(referenceID: id, label: chipLabel)))
                } else {
                    var attributes = baseAttributes
                    attributes[.paperDeskReference] = id
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.union(.patternDot).rawValue
                    result.append(NSAttributedString(string: ns.substring(with: match.range), attributes: attributes))
                }
            case .referenceGroup(let targets):
                result.append(NSAttributedString(string: "[", attributes: baseAttributes))
                for (index, target) in targets.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: ", ", attributes: baseAttributes)) }
                    result.append(NSAttributedString(attachment: ReferenceAttachment(referenceID: target.id,
                                                                                     label: target.label)))
                }
                result.append(NSAttributedString(string: "]", attributes: baseAttributes))
            }
            cursor = match.range.upperBound
        }
        if cursor < ns.length {
            result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: baseAttributes))
        }
    }

    private func protectedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var position = 0
        var fence: String?
        let inlineCode = try? NSRegularExpression(pattern: #"`+[^`]*`+"#)
        while position < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: position, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let opensFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if opensFence {
                let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
                ranges.append(lineRange)
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
            } else if fence != nil {
                ranges.append(lineRange)
            } else if let inlineCode {
                ranges.append(contentsOf: inlineCode.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
                    .map { NSRange(location: lineRange.location + $0.range.location, length: $0.range.length) })
            }
            position = NSMaxRange(lineRange)
        }
        return ranges
    }

    private var mathColor: NSColor {
        colorScheme == .dark
            ? NSColor(calibratedWhite: 0.94, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)
    }
}

/// A small case-insensitive index for the paper's bibliography.
private struct ReferenceLinkTarget {
    let id: String
    let label: String
    let authors: String?
    let firstAuthor: String?
    let year: Int?

    init(_ reference: PaperReference) {
        id = reference.id
        label = reference.displayLabel
        authors = reference.authors
        firstAuthor = reference.firstAuthor
        year = reference.year
    }

    init(_ reference: MessageReference) {
        id = reference.referenceID
        label = reference.label
        authors = reference.authors
        firstAuthor = reference.firstAuthor
        year = reference.year
    }
}

private struct ReferenceLookup {
    var byLabel: [String: ReferenceLinkTarget] = [:]
    var byAuthorYear: [String: ReferenceLinkTarget] = [:]

    init(_ references: [PaperReference], archived: [MessageReference]?) {
        let targets = archived.map { $0.map(ReferenceLinkTarget.init) }
            ?? references.map(ReferenceLinkTarget.init)
        var labelCounts: [String: Int] = [:]
        var authorYearCounts: [String: Int] = [:]
        for reference in targets {
            let label = Self.normalizedLabel(reference.label)
            labelCounts[label, default: 0] += 1
            byLabel[label] = reference
            guard let year = reference.year,
                  let surname = reference.firstAuthor ?? Self.derivedFirstAuthor(reference.authors) else { continue }
            let key = Self.authorYearKey(surname, year)
            authorYearCounts[key, default: 0] += 1
            byAuthorYear[key] = reference
        }
        for (label, count) in labelCounts where count > 1 {
            byLabel.removeValue(forKey: label)
        }
        for (key, count) in authorYearCounts where count > 1 {
            byAuthorYear.removeValue(forKey: key)
        }
    }

    static func normalizedLabel(_ label: String) -> String {
        PaperReferenceMentions.normalizedLabel(label)
    }

    static func authorYearKey(_ surname: String, _ year: Int) -> String {
        PaperReferenceMentions.authorYearKey(surname, year)
    }

    static func derivedFirstAuthor(_ authors: String?) -> String? {
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
}

/// A rounded citation bubble. It is an attachment rather than a superscript
/// run so the number stays a comfortable click target in prose.
private final class CitationAttachment: NSTextAttachment {
    let contextID: String

    init(contextID: String, label: String, tint: NSColor) {
        self.contextID = contextID
        super.init(data: nil, ofType: nil)
        attachmentCell = CitationAttachmentCell(label: label, tint: tint)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class CitationAttachmentCell: NSTextAttachmentCell {
    private let label: String
    private let tint: NSColor
    private let badgeFont: NSFont
    private let textSize: NSSize

    init(label: String, tint: NSColor) {
        self.label = label
        self.tint = tint
        self.badgeFont = InspectorText.serifNS(11, bold: true)
        self.textSize = (label as NSString).size(withAttributes: [.font: badgeFont])
        super.init()
    }

    required init(coder: NSCoder) { fatalError() }

    override var cellSize: NSSize {
        NSSize(width: max(20, ceil(textSize.width) + 12), height: 17)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        tint.withAlphaComponent(0.14).setFill()
        path.fill()
        tint.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: tint]
        let size = (label as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: cellFrame.midX - size.width / 2, y: cellFrame.midY - size.height / 2)
        (label as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// A bibliography chip. It is visually separate from passage citations so the
/// reader can tell "this answer's source in the PDF" from "a work cited here".
private final class ReferenceAttachment: NSTextAttachment {
    let referenceID: String

    init(referenceID: String, label: String) {
        self.referenceID = referenceID
        super.init(data: nil, ofType: nil)
        attachmentCell = ReferenceAttachmentCell(label: label, tint: NSColor.linkColor)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class ReferenceAttachmentCell: NSTextAttachmentCell {
    private let label: String
    private let tint: NSColor
    private let badgeFont: NSFont
    private let textSize: NSSize
    private let icon: NSImage?

    init(label: String, tint: NSColor) {
        self.label = label
        self.tint = tint
        self.badgeFont = InspectorText.serifNS(11, bold: true)
        self.textSize = (label as NSString).size(withAttributes: [.font: badgeFont])
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        self.icon = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        super.init()
    }

    required init(coder: NSCoder) { fatalError() }

    override var cellSize: NSSize {
        let iconWidth: CGFloat = icon == nil ? 0 : 11
        let gap: CGFloat = icon == nil ? 0 : 3
        return NSSize(width: max(22, iconWidth + gap + ceil(textSize.width) + 12), height: 17)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -3) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        tint.withAlphaComponent(0.10).setFill()
        path.fill()
        tint.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
        var x = rect.minX + 6
        if let icon {
            let iconRect = NSRect(x: x, y: rect.midY - 5, width: 11, height: 10)
            icon.draw(in: iconRect)
            x = iconRect.maxX + 3
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: tint]
        let size = (label as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: x, y: rect.midY - size.height / 2)
        (label as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// Draws a formula attachment from a backing-scale bitmap whose origin is
/// snapped to the device pixel grid. The default attachment cell draws the
/// vector image at a possibly fractional origin, which resamples small
/// formulas into a blur.
private final class MathAttachmentCell: NSTextAttachmentCell {
    private let source: NSImage
    private let descent: CGFloat

    init(image: NSImage, descent: CGFloat) {
        self.source = image
        self.descent = descent
        super.init()
    }

    required init(coder: NSCoder) { fatalError() }

    override var cellSize: NSSize { source.size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -descent) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        var rect = cellFrame
        if let controlView {
            var backing = controlView.convertToBacking(cellFrame)
            backing.origin.x = backing.origin.x.rounded()
            backing.origin.y = backing.origin.y.rounded()
            rect = controlView.convertFromBacking(backing)
        }
        let scale = controlView?.window?.backingScaleFactor ?? 2
        let interpolation: NSImageInterpolation = abs(scale - 2) < 0.01 ? .none : .high
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: interpolation.rawValue])
    }
}

/// Reports the height its text needs at a proposed width and treats a plain
/// click inside the reply as selecting that reply, while leaving drag
/// selection untouched.
final class LatexTextView: NSTextView {
    var onTap: (() -> Void)?
    var onURL: ((URL) -> Void)?
    var onCitation: ((String) -> Void)?
    var onReference: ((String) -> Void)?
    var copySource: String?
    var forwardsClicks = false
    private var mouseDownPoint: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        forwardsClicks ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        defer { mouseDownPoint = nil }
        guard event.clickCount == 1, let start = mouseDownPoint else { return }
        let endInWindow: NSPoint
        if let up = NSApp.currentEvent, up.type == .leftMouseUp {
            endInWindow = up.locationInWindow
        } else {
            endInWindow = window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
        }
        let end = convert(endInWindow, from: nil)
        guard hypot(end.x - start.x, end.y - start.y) < 3 else { return }
        if let citation = citationAttachment(at: start) {
            onCitation?(citation.contextID)
            return
        }
        if let referenceID = referenceID(at: start) {
            onReference?(referenceID)
            return
        }
        if let url = linkURL(at: start) {
            onURL?(url)
            return
        }
        onTap?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let copySource, !copySource.isEmpty else { return menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: L("复制原始文本"), action: #selector(copyFullSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = copySource
        menu.addItem(item)
        return menu
    }

    @objc private func copyFullSource(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func measuredSize(width: CGFloat) -> CGSize {
        guard let container = textContainer, let layoutManager else { return .zero }
        container.containerSize = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let height = ceil(used.height + textContainerInset.height * 2)
        return CGSize(width: width, height: max(height, 1))
    }

    private func citationAttachment(at point: NSPoint) -> CitationAttachment? {
        guard let index = characterIndex(at: point), let storage = textStorage else { return nil }
        return storage.attribute(.attachment, at: index, effectiveRange: nil) as? CitationAttachment
    }

    private func referenceID(at point: NSPoint) -> String? {
        guard let index = characterIndex(at: point), let storage = textStorage else { return nil }
        if let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? ReferenceAttachment {
            return attachment.referenceID
        }
        return storage.attribute(.paperDeskReference, at: index, effectiveRange: nil) as? String
    }

    private func linkURL(at point: NSPoint) -> URL? {
        guard let index = characterIndex(at: point), let storage = textStorage else { return nil }
        if let url = storage.attribute(.paperDeskLink, at: index, effectiveRange: nil) as? URL {
            return url
        }
        return storage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let index = layoutManager.characterIndex(for: point, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                              in: textContainer)
        guard rect.insetBy(dx: -2, dy: 0).contains(point) else { return nil }
        return index
    }
}

private struct LatexDisplayFormula: View {
    let formula: String
    let raw: String
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let rendered = NativeMathImage.render(formula, fontSize: fontSize, mode: .display, color: mathColor) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Image(nsImage: rendered.image).interpolation(.high)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Image(nsImage: rendered.image).interpolation(.high)
                            Spacer(minLength: 0)
                        }
                    }
                }
            } else {
                Text(raw)
                    .font(.system(size: fontSize, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.vertical, 3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var mathColor: NSColor {
        colorScheme == .dark
            ? NSColor(calibratedWhite: 0.94, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)
    }
}

private struct NativeMathImage {
    let image: NSImage
    let descent: CGFloat

    static func render(_ formula: String, fontSize: CGFloat, mode: MTMathUILabelMode, color: NSColor,
                       bitmapScale: CGFloat = 0) -> NativeMathImage? {
        guard formula.utf8.count <= LatexSubset.maximumBytes else { return nil }
        var mathImage = MathImage(latex: formula, fontSize: fontSize, textColor: color,
                                  labelMode: mode, textAlignment: .left)
        let result = mathImage.asImage(scale: bitmapScale)
        guard result.0 == nil, let image = result.1, let layout = result.2 else { return nil }
        return NativeMathImage(image: image, descent: layout.descent)
    }
}
