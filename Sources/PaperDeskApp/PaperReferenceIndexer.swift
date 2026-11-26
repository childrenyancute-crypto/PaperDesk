import Foundation
import PDFKit
import PaperDeskCore

struct PaperReferenceIndexResult: Sendable {
    var drafts: [PaperReferenceDraft]
    var headingPageIndex: Int?
    var scannedPages: Int
    var foundSection: Bool
}

/// Reads the bibliography section off the main thread. Only the closing pages
/// are scanned; a missing or scanned-only reference section becomes an
/// `unavailable` index instead of an error shown to the reader.
enum PaperReferenceIndexer {
    private static let headingExpression = try? NSRegularExpression(
        pattern: #"(?im)^[ \t]*(?:\d{1,2}[.)]?[ \t]*)?(?:references(?: cited| and notes)?|bibliography|works cited|literature cited|参考文献|引用文献)[ \t]*$"#
    )

    static func index(pdfURL: URL, pageCount: Int) throws -> PaperReferenceIndexResult {
        guard pageCount > 0 else { return PaperReferenceIndexResult(drafts: [], headingPageIndex: nil, scannedPages: 0, foundSection: false) }
        guard let document = PDFDocument(url: pdfURL) else {
            throw PaperDeskError.invalid(L("无法打开 PDF 以建立参考文献索引", "Could not open the PDF to build a reference index"))
        }
        let actualCount = document.pageCount
        guard actualCount > 0 else { return PaperReferenceIndexResult(drafts: [], headingPageIndex: nil, scannedPages: 0, foundSection: false) }
        let tailStart = max(0, actualCount - 40)
        var headingPageIndex: Int?
        if let expression = headingExpression {
            var pageIndex = actualCount - 1
            while pageIndex >= tailStart {
                defer { pageIndex -= 1 }
                guard let page = document.page(at: pageIndex),
                      let text = page.string, !text.isEmpty else { continue }
                if expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                    headingPageIndex = pageIndex
                    break
                }
            }
        }
        // Very long papers can have their bibliography before the final
        // appendix. Fall back to PDFKit's search so a heading outside the
        // scanned tail is still recognized.
        if headingPageIndex == nil {
            for term in ["References", "Bibliography", "Works Cited", "参考文献", "引用文献"] {
                guard let match = document.findString(term, withOptions: [.caseInsensitive]).last,
                      let page = match.pages.first else { continue }
                let index = document.index(for: page)
                guard index >= actualCount / 2 else { continue }
                if let current = headingPageIndex, index <= current { continue }
                headingPageIndex = index
            }
        }
        let start = headingPageIndex ?? max(0, actualCount - 4)
        var pages: [PaperReferencePageText] = []
        var total = 0
        var index = start
        while index < actualCount, total < 1_200_000 {
            guard let page = document.page(at: index) else { break }
            let text = String((page.string ?? "").prefix(240_000))
            total += text.count
            pages.append(PaperReferencePageText(pageIndex: index,
                                                pageLabel: page.label ?? String(index + 1),
                                                text: text))
            index += 1
        }
        var drafts = PaperReferenceParser.entries(from: pages)
        // Without a bibliography heading, an appendix or arbitrary end matter
        // can look like paragraphs. Only keep unheaded results that contain
        // real numbered bibliography markers.
        if headingPageIndex == nil, drafts.allSatisfy({ $0.label.hasPrefix("R") }) {
            drafts = []
        }
        return PaperReferenceIndexResult(drafts: drafts, headingPageIndex: headingPageIndex,
                                         scannedPages: pages.count, foundSection: headingPageIndex != nil)
    }
}
