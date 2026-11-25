import AppKit
import PaperDeskCore
import SwiftMath
import SwiftUI

/// A lightweight native LaTeX reader for notes and discussion records.
/// SwiftMath typesets formulas with CoreText and a bundled math font.
struct LatexText: View {
    let source: String
    var bodyFont: Font = .system(size: 16, design: .serif)
    /// Maps footnote numbers (`⟦1⟧`) to citation context IDs. Only discussion
    /// answers pass this; notes keep plain text.
    var citationContextIDs: [String: String] = [:]
    var citationColor: Color = .teal

    var body: some View {
        let blocks = LatexDocument.blocks(source)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .inline(let parts):
                    LatexInlineText(parts: parts, bodyFont: bodyFont,
                                    citationContextIDs: citationContextIDs, citationColor: citationColor)
                case .display(let formula, let raw):
                    LatexDisplayFormula(formula: LatexSubset.normalize(formula), raw: raw, fontSize: 18)
                }
            }
        }
    }
}

private struct LatexInlineText: View {
    let parts: [LatexInlinePart]
    let bodyFont: Font
    var citationContextIDs: [String: String] = [:]
    var citationColor: Color = .teal
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        makeText()
            .font(bodyFont)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func makeText() -> Text {
        var result = Text("")
        for part in parts {
            switch part {
            case .text(let text):
                result = append(text: text, to: result)
            case .math(let formula, let raw):
                let normalized = LatexSubset.normalize(formula)
                if let rendered = NativeMathImage.render(normalized, fontSize: 16, mode: .text, color: mathColor) {
                    let math = Text(Image(nsImage: rendered.image))
                        .baselineOffset(rendered.baselineOffset)
                    result = Text("\(result)\(math)")
                } else {
                    // Keep malformed or unsupported input visible exactly as
                    // recorded instead of silently rewriting the formula.
                    result = Text("\(result)\(Text(raw))")
                }
            }
        }
        return result
    }

    /// Renders `⟦n⟧` as a superscript citation link. Unknown numbers stay
    /// visible as plain text so a stale record never silently loses content.
    private func append(text: String, to original: Text) -> Text {
        guard !citationContextIDs.isEmpty, text.contains("⟦") else {
            return Text("\(original)\(Text(text))")
        }
        var result = original
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "⟦"),
              let close = rest[open...].firstIndex(of: "⟧") {
            let before = rest[..<open]
            if !before.isEmpty { result = Text("\(result)\(Text(String(before)))") }
            let number = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if let contextID = citationContextIDs[number],
               let url = URL(string: "paperdesk-citation://\(contextID)") {
                var token = AttributedString(number)
                token.font = InspectorText.badge
                token.foregroundColor = citationColor
                token.underlineStyle = .single
                token.baselineOffset = 4
                token.link = url
                result = Text("\(result)\(Text(token))")
            } else {
                result = Text("\(result)\(Text("⟦\(number)⟧"))")
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { result = Text("\(result)\(Text(String(rest)))") }
        return result
    }

    private var mathColor: NSColor {
        colorScheme == .dark
            ? NSColor(calibratedWhite: 0.94, alpha: 1)
            : NSColor(calibratedWhite: 0.12, alpha: 1)
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
    let baselineOffset: CGFloat

    static func render(_ formula: String, fontSize: CGFloat, mode: MTMathUILabelMode, color: NSColor) -> NativeMathImage? {
        guard formula.utf8.count <= LatexSubset.maximumBytes else { return nil }
        var mathImage = MathImage(latex: formula, fontSize: fontSize, textColor: color,
                                  labelMode: mode, textAlignment: .left)
        let result = mathImage.asImage()
        guard result.0 == nil, let image = result.1, let layout = result.2 else { return nil }
        return NativeMathImage(image: image, baselineOffset: -layout.descent / 2)
    }
}
