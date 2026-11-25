import XCTest
import SwiftMath
@testable import PaperDeskCore

final class LatexSubsetTests: XCTestCase {
    private let extraCommandsWithArguments: Set<String> = [
        "frac", "binom", "sqrt", "overline", "underline",
        "color", "textcolor", "colorbox", "left", "right", "begin", "end",
        "over", "atop", "choose", "brack", "brace", "limits", "nolimits", "cr", "\\"
    ]

    private let fontAndAccentCommands: Set<String> = [
        "mathnormal", "mathrm", "textrm", "rm", "mathbf", "bf", "textbf",
        "mathcal", "cal", "mathtt", "texttt", "mathit", "textit", "mit",
        "mathsf", "textsf", "mathfrak", "frak", "mathbb", "mathbfit", "bm", "text",
        "acute", "grave", "hat", "tilde", "bar", "breve", "dot", "ddot",
        "check", "vec", "widehat", "widetilde"
    ]

    private func template(for command: String) -> String? {
        switch command {
        case "frac", "binom":
            return "\\" + command + "{a}{b}"
        case "sqrt", "overline", "underline":
            return "\\" + command + "{a}"
        case "color", "textcolor", "colorbox":
            return "\\" + command + "{red}{a}"
        case "over", "atop", "choose", "brack", "brace":
            return "a \\" + command + " b"
        case "limits", "nolimits":
            return "\\sum\\" + command + "_{i=1}^{n}"
        case "cr":
            return "a\\cr b"
        case "\\":
            return "a\\\\b"
        case "left":
            return "\\left(a\\right)"
        case "right":
            return nil
        case "begin", "end":
            return nil
        case " ":
            return "a\\ b"
        case "{", "}", "|", "#", "$", "%", "&", "_":
            return "\\" + command
        default:
            if fontAndAccentCommands.contains(command) {
                return "\\" + command + "{a}"
            }
            return "\\" + command
        }
    }

    func testEveryAllowedCommandParsesWithSwiftMath() {
        for command in LatexSubset.allowedCommandNames where !extraCommandsWithArguments.contains(command) {
            guard let latex = template(for: command) else { continue }
            var error: NSError?
            let list = MTMathListBuilder.build(fromString: latex, error: &error)
            XCTAssertNotNil(list, "SwiftMath rejected \\\(command) built as \(latex): \(error?.localizedDescription ?? "no error")")
        }
    }

    func testEnvironmentRewrites() {
        XCTAssertEqual(
            LatexSubset.normalize(#"\begin{align} a &= b \end{align}"#),
            #"\begin{aligned} a &= b \end{aligned}"#
        )
        XCTAssertEqual(
            LatexSubset.normalize(#"\begin{array}{cc} 1 & 2 \\ 3 & 4 \end{array}"#),
            #"\begin{matrix} 1 & 2 \\ 3 & 4 \end{matrix}"#
        )
        XCTAssertEqual(LatexSubset.normalize(#"\begin{equation*}x\end{equation*}"#), #"\begin{gather}x\end{gather}"#)
    }

    func testCommandRewrites() {
        XCTAssertEqual(LatexSubset.normalize(#"\dfrac{a}{b}"#), #"\frac{a}{b}"#)
        XCTAssertEqual(LatexSubset.normalize(#"\operatorname{tr}(A)"#), #"\mathrm{tr}(A)"#)
        XCTAssertEqual(LatexSubset.normalize(#"\dots"#), #"\ldots"#)
        XCTAssertEqual(LatexSubset.normalize(#"\boldsymbol{x}"#), #"\mathbf{x}"#)
        XCTAssertEqual(LatexSubset.normalize(#"\textnormal{rate}"#), #"\text{rate}"#)
    }

    func testStructuralRewrites() {
        XCTAssertEqual(LatexSubset.normalize(#"a \not= b"#), #"a \neq b"#)
        XCTAssertEqual(LatexSubset.normalize(#"a \not\in B"#), #"a \notin B"#)
        XCTAssertEqual(LatexSubset.normalize(#"\bigl( x \bigr)"#), #"\left( x \right)"#)
        XCTAssertEqual(LatexSubset.normalize(#"a \\[4pt] b"#), #"a \\ b"#)
        XCTAssertEqual(LatexSubset.normalize("a~b"), #"a\ b"#)
        XCTAssertEqual(LatexSubset.normalize("a % comment\nb"), "a \nb")
        XCTAssertEqual(LatexSubset.normalize(#"x \tag{1} \label{eq:a}"#), "x  ")
        XCTAssertEqual(LatexSubset.normalize(#"see \eqref{eq:a} and \ref{eq:b}"#), "see (eq:a) and eq:b")
    }

    func testSupportedFormulasHaveNoIssues() {
        let formulas = [
            #"\frac{a}{b} + x^2 - y_{i}"#,
            #"\sum_{i=1}^{n} i^2 = \frac{n(n+1)(2n+1)}{6}"#,
            #"\left(\frac{a}{b}\right)^{2}"#,
            #"\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}"#,
            #"\begin{cases} x & x > 0 \\ 0 & x \le 0 \end{cases}"#,
            #"\begin{aligned} a &= b + c \\ d &= e \end{aligned}"#,
            #"\mathbb{R}^{n} \to \mathbb{R}"#,
            #"\int_{0}^{\infty} e^{-x}\,dx = 1"#,
            #"\sqrt[3]{x} \approx 1.442"#,
            #"\color{red}{x} + \vec{v} \cdot \hat{n}"#,
            #"\begin{gather} a = b \\ c = d \end{gather}"#
        ]
        for formula in formulas {
            let prepared = LatexSubset.prepare(formula)
            XCTAssertTrue(prepared.issues.isEmpty, "\(formula) -> \(prepared.issues.map(\.message))")
        }
    }

    func testIssuesAreReported() {
        XCTAssertEqual(LatexSubset.prepare(#"\ce{H2O}"#).issues.first?.kind, .unsupportedCommand)
        XCTAssertEqual(LatexSubset.prepare(#"\begin{multline} a \end{multline}"#).issues.first?.kind, .unsupportedEnvironment)
        XCTAssertTrue(LatexSubset.prepare("x = 中").issues.contains { $0.kind == .nonASCIICharacter })
        XCTAssertTrue(LatexSubset.prepare(#"\frac{a}{b"#).issues.contains { $0.kind == .unmatchedBrace })
        XCTAssertTrue(LatexSubset.prepare(#"\left( a"#).issues.contains { $0.kind == .unmatchedDelimiter })
        XCTAssertTrue(LatexSubset.prepare(#"a $ b"#).issues.contains { $0.kind == .dollarSign })
        XCTAssertTrue(LatexSubset.prepare(#"a & b"#).issues.contains { $0.kind == .columnCount })
        XCTAssertTrue(LatexSubset.prepare(String(repeating: "x", count: LatexSubset.maximumBytes + 1))
            .issues.contains { $0.kind == .tooLong })
    }

    func testAlignedColumnLimit() {
        let prepared = LatexSubset.prepare(#"\begin{aligned} a &= b & c &= d \end{aligned}"#)
        XCTAssertTrue(prepared.issues.contains { $0.kind == .columnCount })
    }

    func testNormalizedFormulaParsesWithSwiftMath() {
        let formulas = [
            #"\dfrac{a}{b}"#,
            #"\operatorname{tr}(A)"#,
            #"\begin{align} a &= b \\ c &= d \end{align}"#,
            #"\begin{array}{cc} 1 & 2 \\ 3 & 4 \end{array}"#,
            #"a \not= b"#,
            #"\bigl( x \bigr)"#,
            #"\dfrac{x}{y} \tag{1}"#
        ]
        for formula in formulas {
            let normalized = LatexSubset.normalize(formula)
            var error: NSError?
            XCTAssertNotNil(MTMathListBuilder.build(fromString: normalized, error: &error),
                            "\(formula) -> \(normalized): \(error?.localizedDescription ?? "nil")")
        }
    }

    func testDocumentSegments() {
        let text = #"Inline $a^2$ and display $$\frac{a}{b}$$ plus \(c\) and \[d\]"#
        let segments = LatexDocument.segments(text)
        XCTAssertEqual(segments.map(\.formula), [#"a^2"#, #"\frac{a}{b}"#, "c", "d"])
        XCTAssertEqual(segments.map(\.isDisplay), [false, true, false, true])
    }

    func testEquationEnvironmentPreservesFirstFormulaCharacter() {
        let equation = LatexDocument.segments(#"\begin{equation}x+1\end{equation}"#)
        XCTAssertEqual(equation.map(\.formula), ["x+1"])

        let starred = LatexDocument.segments(#"\begin{equation*}y-1\end{equation*}"#)
        XCTAssertEqual(starred.map(\.formula), ["y-1"])
    }

    func testUnclosedEquationDoesNotCrashAndIsReported() {
        let blocks = LatexDocument.blocks(#"\begin{equation}"#)
        XCTAssertEqual(blocks, [.inline([.text(#"\begin{equation}"#)])])

        let result = LatexSubset.checkResult(text: #"\begin{equation}"#)
        XCTAssertEqual(result["isError"].boolValue, true)
        XCTAssertTrue(result["content"].arrayValue?.first?["text"].stringValue?.contains("\\end{equation}") ?? false)
    }

    func testUnclosedBracketDelimiterIsReportedAlongsideValidMath() {
        let result = LatexSubset.checkResult(text: #"Known $x$. Broken \[y"#)
        XCTAssertEqual(result["isError"].boolValue, true)
        let report = result["content"].arrayValue?.first?["text"].stringValue ?? ""
        XCTAssertTrue(report.contains("\\]"), report)
    }

    func testCurrencyDollarRemainsPlainProse() {
        let result = LatexSubset.checkResult(text: #"Cost $20 today; equation $x$"#)
        XCTAssertEqual(result["isError"].boolValue, false)
        XCTAssertTrue(result["content"].arrayValue?.first?["text"].stringValue?.contains("1. inline: $x$") ?? false)
    }

    func testNumericLeadingMathWithSpacesStillParses() {
        let result = LatexSubset.checkResult(text: #"$2 + 1$"#)
        XCTAssertEqual(result["isError"].boolValue, false)
        XCTAssertTrue(result["content"].arrayValue?.first?["text"].stringValue?.contains("1. inline: $2 + 1$") ?? false)
    }

    func testCheckResultCountsSegments() throws {
        let ok = LatexSubset.checkResult(text: #"Value $x^2$ is fine."#)
        XCTAssertEqual(ok["isError"].boolValue, false)
        XCTAssertTrue(ok["content"].arrayValue?.first?["text"].stringValue?.contains("all renderable") ?? false)

        let bad = LatexSubset.checkResult(text: #"Value $x = 中$ is broken."#)
        XCTAssertEqual(bad["isError"].boolValue, true)
        XCTAssertTrue(bad["content"].arrayValue?.first?["text"].stringValue?.contains("non-Latin") ?? false)

        let empty = LatexSubset.checkResult(text: "no math here")
        XCTAssertEqual(empty["isError"].boolValue, false)
    }
}
