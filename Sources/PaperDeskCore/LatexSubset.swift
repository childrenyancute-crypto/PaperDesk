import Foundation

/// One problem that would prevent PaperDesk from rendering a formula.
public struct LatexIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case tooLong
        case unsupportedCommand
        case unsupportedEnvironment
        case nonASCIICharacter
        case unmatchedBrace
        case unmatchedEnvironment
        case unmatchedDelimiter
        case dollarSign
        case columnCount
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// The LaTeX subset understood by the bundled SwiftMath renderer.
///
/// `normalize` rewrites common out-of-subset constructs into equivalents the
/// renderer accepts. `check` validates already-normalized math and reports the
/// constructs that would still fail. `prepare` is the usual entry point.
///
/// The command table mirrors `SwiftMath/MathRender/MTMathAtomFactory.swift` and
/// its aliases, accents, font styles, environments, and special commands.
/// `LatexSubsetTests` builds every listed command with the real parser, so an
/// upstream SwiftMath change fails the suite instead of drifting silently.
public enum LatexSubset {
    public static let maximumBytes = 2_048

    public static let supportedEnvironments: Set<String> = [
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix",
        "eqalign", "split", "aligned", "displaylines", "gather", "eqnarray", "cases"
    ]

    private static let environmentRewrites: [String: String] = [
        "align": "aligned", "align*": "aligned",
        "flalign": "aligned", "flalign*": "aligned",
        "alignedat": "aligned", "alignat": "aligned", "alignat*": "aligned",
        "eqnarray*": "eqnarray",
        "gather*": "gather", "gathered": "gather",
        "equation": "gather", "equation*": "gather",
        "displaymath": "gather", "math": "gather",
        "array": "matrix", "smallmatrix": "matrix", "tabular": "matrix",
        "cases*": "cases", "dcases": "cases", "rcases": "cases"
    ]

    private static let commandsWithColumnSpec: Set<String> = ["array", "tabular", "alignat", "alignedat"]

    private static let commandRewrites: [String: String] = [
        "dfrac": "frac", "tfrac": "frac", "cfrac": "frac",
        "dots": "ldots", "dotsc": "ldots", "dotsb": "cdots", "dotsm": "cdots",
        "boldsymbol": "mathbf", "pmb": "mathbf",
        "textup": "text", "textnormal": "text", "mbox": "text", "hbox": "text"
    ]

    private static let removableCommands: Set<String> = [
        "label", "tag", "nonumber", "notag", "hspace", "vspace", "allowbreak", "noindent"
    ]

    private static let sizingCommands: Set<String> = [
        "big", "Big", "bigg", "Bigg",
        "bigl", "Bigl", "biggl", "Biggl",
        "bigr", "Bigr", "biggr", "Biggr",
        "bigm", "Bigm", "biggm", "Biggm"
    ]

    private static let commandSuggestions: [String: String] = [
        "operatorname": #"use \mathrm"#,
        "mathop": #"use \mathrm"#,
        "mathbin": #"use \mathrm"#,
        "mathrel": #"use \mathrm or the plain relation symbol"#,
        "mathord": #"use \mathrm"#,
        "mathopen": #"use \left"#,
        "mathclose": #"use \right"#,
        "mathpunct": #"use punctuation directly"#,
        "mathinner": #"remove it"#,
        "overset": #"use a superscript"#,
        "underset": #"use a subscript"#,
        "stackrel": #"use a superscript"#,
        "substack": #"use a matrix environment"#,
        "boxed": #"remove the box"#,
        "fbox": #"remove the box"#,
        "cancel": #"remove the cancellation mark"#,
        "bcancel": #"remove the cancellation mark"#,
        "xcancel": #"remove the cancellation mark"#,
        "phantom": #"remove it"#,
        "hphantom": #"remove it"#,
        "vphantom": #"remove it"#,
        "hspace": #"use \, \; \quad or \qquad"#,
        "vspace": #"split the display or remove it"#,
        "kern": #"use \, \; \quad or \qquad"#,
        "mspace": #"use \, \; \quad or \qquad"#,
        "includegraphics": #"describe the figure in prose"#,
        "href": #"remove the link"#,
        "url": #"keep URLs outside math"#,
        "definecolor": #"use a built-in color name"#,
        "ce": #"chemistry is not supported; write the formula as plain symbols"#,
        "pu": #"write units outside math"#,
        "si": #"write units outside math"#,
        "R": #"use \mathbb{R}"#,
        "N": #"use \mathbb{N}"#,
        "Z": #"use \mathbb{Z}"#,
        "Q": #"use \mathbb{Q}"#,
        "C": #"use \mathbb{C}"#,
        "overbrace": #"use \overline"#,
        "underbrace": #"use \underline"#,
        "overrightarrow": #"use \vec"#,
        "overleftarrow": #"remove the arrow"#,
        "dddot": #"use \ddot"#,
        "implies": #"use \Rightarrow"#,
        "impliedby": #"use \Leftarrow"#,
        "iff": #"use \Leftrightarrow"#
    ]

    private static let expectedColumns: [String: Int] = [
        "aligned": 2, "split": 2, "eqalign": 2,
        "gather": 1, "displaylines": 1,
        "eqnarray": 3,
        "cases": 2
    ]

    private static let allowedNonASCII = Set(
        "áéíóúýàèìòùâêîôûäëïöüÿãñõçøåæœßÁÉÍÓÚÝÀÌÒÙÂÊÎÔÛÄËÏÖÜÃÑÕÇØÅÆŒ"
    )

    static let allowedCommandNames: Set<String> = [
        " ", "!", "#", "$", "%", "&", ",", ";", ">", "AA", "AE", "CC", "Delta", "Downarrow",
        "Gamma", "Im", "Lambda", "Leftarrow", "Leftrightarrow", "Longleftarrow",
        "Longleftrightarrow", "Longrightarrow", "O", "OE", "Omega", "Phi", "Pi", "Pr", "Psi",
        "Re", "Rightarrow", "Sigma", "Theta", "Uparrow", "Updownarrow", "Upsilon", "Vert",
        "Xi", "_", "aa", "acute", "ae", "aleph", "alpha", "amalg", "angle", "angstrom",
        "approx", "arccos", "arcsin", "arctan", "arg", "ast", "asymp", "atop", "backslash",
        "bar", "begin", "beta", "bf", "bigcap", "bigcup", "bigodot", "bigoplus", "bigotimes",
        "bigsqcup", "biguplus", "bigvee", "bigwedge", "binom", "bm", "bot", "brace", "brack",
        "breve", "bullet", "cal", "cap", "cc", "cdot", "cdotp", "cdots", "check", "chi",
        "choose", "circ", "colon", "color", "colorbox", "cong", "coprod", "cos", "cosh", "cot",
        "coth", "cr", "csc", "cup", "dagger", "ddagger", "ddot", "ddots", "deg", "degree",
        "delta", "det", "dim", "displaystyle", "div", "dot", "doteq", "downarrow", "ell",
        "emptyset", "end", "epsilon", "equiv", "eta", "exists", "exp", "forall", "frac",
        "frak", "gamma", "gcd", "ge", "geq", "gets", "gg", "grave", "hat", "hbar", "hom",
        "iff", "imath", "in", "inf", "infty", "int", "iota", "jmath", "kappa", "ker", "lambda",
        "land", "langle", "lbar", "lbrace", "lceil", "ldots", "le", "left", "leftarrow",
        "leftrightarrow", "leq", "lfloor", "lg", "lgroup", "lim", "liminf", "limits", "limsup",
        "ll", "ln", "lnot", "log", "longleftarrow", "longleftrightarrow", "longrightarrow",
        "lor", "mapsto", "mathbb", "mathbf", "mathbfit", "mathcal", "mathfrak", "mathit",
        "mathnormal", "mathrm", "mathsf", "mathtt", "max", "mho", "mid", "min", "mit",
        "models", "mp", "mu", "nabla", "ne", "nearrow", "neg", "neq", "ni", "nolimits",
        "notin", "nu", "nwarrow", "o", "odot", "oe", "oint", "omega", "omicron", "ominus",
        "oplus", "oslash", "otimes", "over", "overline", "parallel", "partial", "perp", "phi",
        "pi", "pm", "prec", "prime", "prod", "propto", "psi", "qquad", "quad", "rangle",
        "rbrace", "rceil", "rfloor", "rgroup", "rho", "right", "rightarrow", "rm",
        "scriptscriptstyle", "scriptstyle", "searrow", "sec", "setminus", "sigma", "sim",
        "simeq", "sin", "sinh", "sqcap", "sqcup", "sqrt", "sqsubset", "sqsubseteq", "sqsupset",
        "sqsupseteq", "square", "ss", "star", "subset", "subseteq", "succ", "sum", "sup",
        "supset", "supseteq", "swarrow", "tan", "tanh", "tau", "text", "textbf", "textcolor",
        "textit", "textrm", "textsf", "textstyle", "texttt", "theta", "tilde", "times", "to",
        "top", "triangle", "underline", "uparrow", "updownarrow", "uplus", "upquote",
        "upsilon", "varepsilon", "varphi", "varpi", "varrho", "varsigma", "vartheta", "vdots",
        "vec", "vee", "vert", "wedge", "widehat", "widetilde", "wp", "wr", "xi", "zeta", "{",
        "|", "}", "\\"
    ]

    public static func normalize(_ source: String) -> String {
        var output = ""
        var cursor = source.startIndex

        while cursor < source.endIndex {
            let character = source[cursor]

            if character == "%" {
                while cursor < source.endIndex, source[cursor] != "\n" {
                    cursor = source.index(after: cursor)
                }
                continue
            }

            if character == "~" {
                output += "\\ "
                cursor = source.index(after: cursor)
                continue
            }

            guard character == "\\" else {
                output.append(character)
                cursor = source.index(after: cursor)
                continue
            }

            let command = readCommand(in: source, at: cursor)
            cursor = command.end
            let name = command.name
            guard !name.isEmpty else {
                output += "\\"
                continue
            }

            if name == "\\" || name == "cr" {
                output += "\\\\"
                if cursor < source.endIndex, source[cursor] == "[" {
                    cursor = skipBracketGroup(in: source, from: cursor)
                }
                continue
            }

            if name == "begin" || name == "end" {
                guard let group = readGroup(in: source, at: cursor) else {
                    output += "\\" + name
                    continue
                }
                let original = group.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let environment = environmentRewrites[original] ?? original
                output += "\\" + name + "{" + environment + "}"
                cursor = group.end
                if name == "begin", commandsWithColumnSpec.contains(original) {
                    if let spec = readGroup(in: source, at: cursor) {
                        cursor = spec.end
                    }
                }
                continue
            }

            if name == "operatorname" || name == "mathop" {
                if cursor < source.endIndex, source[cursor] == "*" {
                    cursor = source.index(after: cursor)
                }
                output += "\\mathrm"
                continue
            }

            if name == "not" {
                let next = skipSpaces(in: source, from: cursor)
                if next < source.endIndex, source[next] == "=" {
                    output += "\\neq"
                    cursor = source.index(after: next)
                    continue
                }
                if source[next...].hasPrefix("\\in") {
                    output += "\\notin"
                    cursor = source.index(next, offsetBy: 3)
                    continue
                }
                output += "\\not"
                continue
            }

            if let replacement = commandRewrites[name] {
                output += "\\" + replacement
                continue
            }

            if sizingCommands.contains(name) {
                if name.hasSuffix("l") {
                    output += "\\left"
                } else if name.hasSuffix("r") {
                    output += "\\right"
                }
                continue
            }

            if removableCommands.contains(name) {
                if let group = readGroup(in: source, at: cursor) {
                    cursor = group.end
                }
                continue
            }

            if name == "ref" || name == "eqref" {
                guard let group = readGroup(in: source, at: cursor) else {
                    output += "\\" + name
                    continue
                }
                let body = group.body.trimmingCharacters(in: .whitespacesAndNewlines)
                output += name == "eqref" ? "(" + body + ")" : body
                cursor = group.end
                continue
            }

            output += "\\" + name
        }

        return output
    }

    public static func prepare(_ source: String) -> (latex: String, issues: [LatexIssue]) {
        let latex = normalize(source)
        return (latex, check(latex))
    }

    public static func check(_ latex: String) -> [LatexIssue] {
        var issues: [LatexIssue] = []

        if latex.utf8.count > maximumBytes {
            issues.append(LatexIssue(
                kind: .tooLong,
                message: "formula is \(latex.utf8.count) bytes; keep it under \(maximumBytes) bytes or split it"
            ))
        }

        var braceDepth = 0
        var mismatchedBrace = false
        var leftDelimiters = 0
        var rightDelimiters = 0
        var sawDollar = false
        var unknownCommands: [String] = []
        var foreignCharacters = Set<Character>()
        var environments: [EnvironmentFrame] = []
        var completedEnvironments: [EnvironmentFrame] = []

        var cursor = latex.startIndex
        while cursor < latex.endIndex {
            let character = latex[cursor]

            if character == "\\" {
                let command = readCommand(in: latex, at: cursor)
                cursor = command.end
                let name = command.name
                if name.isEmpty { continue }

                switch name {
                case "begin":
                    if let group = readGroup(in: latex, at: cursor) {
                        cursor = group.end
                        let environment = group.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !supportedEnvironments.contains(environment) {
                            issues.append(LatexIssue(
                                kind: .unsupportedEnvironment,
                                message: "unsupported environment " + environment + environmentHint(environment)
                            ))
                        }
                        if !environments.isEmpty {
                            environments[environments.count - 1].hasNestedContent = true
                        }
                        environments.append(EnvironmentFrame(name: environment))
                    }
                case "end":
                    if let group = readGroup(in: latex, at: cursor) {
                        cursor = group.end
                        let environment = group.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let last = environments.last {
                            if last.name != environment {
                                issues.append(LatexIssue(
                                    kind: .unmatchedEnvironment,
                                    message: "\\end{" + environment + "} does not match \\begin{" + last.name + "}"
                                ))
                            }
                            completedEnvironments.append(environments.removeLast())
                        } else {
                            issues.append(LatexIssue(
                                kind: .unmatchedEnvironment,
                                message: "\\end{" + environment + "} has no matching \\begin"
                            ))
                        }
                    }
                case "left":
                    leftDelimiters += 1
                case "right":
                    rightDelimiters += 1
                case "\\", "cr":
                    if !environments.isEmpty {
                        environments[environments.count - 1].startRow()
                    }
                default:
                    if !allowedCommandNames.contains(name), !unknownCommands.contains(name) {
                        unknownCommands.append(name)
                    }
                }
                continue
            }

            switch character {
            case "{":
                braceDepth += 1
            case "}":
                braceDepth -= 1
                if braceDepth < 0 {
                    braceDepth = 0
                    mismatchedBrace = true
                }
            case "&":
                if environments.isEmpty {
                    issues.append(LatexIssue(
                        kind: .columnCount,
                        message: "& is only valid inside a table environment"
                    ))
                } else {
                    environments[environments.count - 1].countColumn()
                }
            case "$":
                sawDollar = true
            default:
                if !isAllowedCharacter(character) {
                    foreignCharacters.insert(character)
                }
            }
            cursor = latex.index(after: cursor)
        }

        if braceDepth != 0 || mismatchedBrace {
            issues.append(LatexIssue(kind: .unmatchedBrace, message: "braces are not balanced"))
        }
        if leftDelimiters != rightDelimiters {
            issues.append(LatexIssue(
                kind: .unmatchedDelimiter,
                message: "\\left and \\right do not match (" + String(leftDelimiters) + " vs " + String(rightDelimiters) + ")"
            ))
        }
        if sawDollar {
            issues.append(LatexIssue(kind: .dollarSign, message: "$ inside a formula; delimiters must stay outside"))
        }
        if !environments.isEmpty {
            issues.append(LatexIssue(
                kind: .unmatchedEnvironment,
                message: "environment " + environments[environments.count - 1].name + " is never closed with \\end"
            ))
        }
        for name in unknownCommands {
            let hint = commandSuggestions[name].map { " (" + $0 + ")" } ?? ""
            issues.append(LatexIssue(kind: .unsupportedCommand, message: "unsupported command \\" + name + hint))
        }
        if !foreignCharacters.isEmpty {
            let listed = foreignCharacters.prefix(4).map { "“" + String($0) + "”" }.joined(separator: ", ")
            issues.append(LatexIssue(
                kind: .nonASCIICharacter,
                message: "the renderer drops " + listed + "; write non-Latin text, emoji, or CJK outside math"
            ))
        }
        issues.append(contentsOf: columnIssues(in: completedEnvironments + environments))
        return issues
    }

    /// Human-readable and machine-readable report for the `check_latex` tool.
    public static func checkResult(text: String) -> JSONValue {
        let parsed = LatexDocument.segmentsAndDelimiterIssues(text)
        let delimiterIssues = parsed.delimiterIssues
        let segments = parsed.segments
        guard !segments.isEmpty else {
            guard delimiterIssues.isEmpty else {
                let details = delimiterIssues.map { "issue: " + $0.message }
                let count = delimiterIssues.count
                let summary = String(count) + " malformed math delimiter" + (count == 1 ? "" : "s") + " found"
                return JSONValue.textResult(([summary] + details).joined(separator: "\n\n"), isError: true)
            }
            return JSONValue.textResult(
                "No math found. Wrap inline math in $...$ or \\(...\\) and display math in $$...$$, \\[...\\], or the equation/equation* environment."
            )
        }

        var report: [String] = []
        var blocking = delimiterIssues.count
        report.append(contentsOf: delimiterIssues.map { "delimiter issue: " + $0.message })
        for (index, segment) in segments.enumerated() {
            let prepared = prepare(segment.formula)
            let changed = prepared.latex != segment.formula
            let position = segment.isDisplay ? "display" : "inline"
            let preview = segment.raw.count > 160 ? String(segment.raw.prefix(160)) + "…" : segment.raw
        var lines = [String(index + 1) + ". " + position + ": " + preview]
            if changed {
                lines.append("   normalized for the renderer: " + prepared.latex)
            }
            if prepared.issues.isEmpty {
                lines.append("   ok")
            } else {
                blocking += 1
                for issue in prepared.issues {
                    lines.append("   issue: " + issue.message)
                }
            }
            report.append(lines.joined(separator: "\n"))
        }

        let summary = String(segments.count) + " math segment" + (segments.count == 1 ? "" : "s") + " checked; "
            + (blocking == 0 ? "all renderable" : String(blocking) + (blocking == 1 ? " needs a fix" : " need fixes"))
        let body = ([summary] + report).joined(separator: "\n\n")
        return JSONValue.textResult(body, isError: blocking > 0)
    }

    private struct EnvironmentFrame {
        let name: String
        var rows: [Int] = [0]
        var hasNestedContent = false

        mutating func countColumn() {
            rows[rows.count - 1] += 1
        }

        mutating func startRow() {
            rows.append(0)
        }
    }

    private static func columnIssues(in frames: [EnvironmentFrame]) -> [LatexIssue] {
        var issues: [LatexIssue] = []
        for frame in frames {
            guard let expected = expectedColumns[frame.name], !frame.hasNestedContent else { continue }
            for (row, ampersands) in frame.rows.enumerated() where ampersands + 1 != expected {
                issues.append(LatexIssue(
                    kind: .columnCount,
                    message: frame.name + " expects " + String(expected) + " columns; row "
                        + String(row + 1) + " has " + String(ampersands + 1)
                ))
            }
        }
        return issues
    }

    private static func environmentHint(_ environment: String) -> String {
        if let replacement = environmentRewrites[environment] {
            return " (use " + replacement + ")"
        }
        switch environment {
        case "alignat", "alignat*":
            return " (use aligned with one & per row)"
        case "multline", "multline*", "flalign", "flalign*":
            return " (use gather or aligned)"
        case "tikzpicture", "picture", "pspicture":
            return " (figures are not supported)"
        default:
            return " (supported: " + supportedEnvironments.sorted().joined(separator: ", ") + ")"
        }
    }

    private struct Command {
        let name: String
        let end: String.Index
    }

    private static func readCommand(in source: String, at index: String.Index) -> Command {
        var cursor = source.index(after: index)
        guard cursor < source.endIndex else { return Command(name: "", end: cursor) }
        if source[cursor].isLetter {
            var name = ""
            while cursor < source.endIndex, source[cursor].isLetter {
                name.append(source[cursor])
                cursor = source.index(after: cursor)
            }
            return Command(name: name, end: cursor)
        }
        let name = String(source[cursor])
        cursor = source.index(after: cursor)
        return Command(name: name, end: cursor)
    }

    private static func readGroup(in source: String, at index: String.Index) -> (body: String, end: String.Index)? {
        let start = skipSpaces(in: source, from: index)
        guard start < source.endIndex, source[start] == "{" else { return nil }
        var depth = 0
        var body = ""
        var cursor = start
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "\\" {
                let command = readCommand(in: source, at: cursor)
                body += String(source[cursor..<command.end])
                cursor = command.end
                continue
            }
            if character == "{" {
                depth += 1
                if depth > 1 { body.append(character) }
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return (body, source.index(after: cursor))
                }
                body.append(character)
            } else {
                body.append(character)
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func skipSpaces(in source: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\n" || source[cursor] == "\t" {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    private static func skipBracketGroup(in source: String, from index: String.Index) -> String.Index {
        var cursor = source.index(after: index)
        while cursor < source.endIndex {
            let character = source[cursor]
            cursor = source.index(after: cursor)
            if character == "]" { return cursor }
        }
        return cursor
    }

    private static func isAllowedCharacter(_ character: Character) -> Bool {
        if character == " " || character == "\n" || character == "\t" { return true }
        if let scalar = character.unicodeScalars.first,
           character.unicodeScalars.count == 1,
           scalar.value >= 0x21,
           scalar.value <= 0x7E {
            return true
        }
        if character >= "\u{0410}" && character <= "\u{044F}" { return true }
        return allowedNonASCII.contains(character)
    }
}
