import Foundation
import XCTest
@testable import PaperDeskCore
@testable import PaperDeskStorage

final class ReferenceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperdesk-reference-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try super.tearDownWithError()
    }

    func testParserExtractsNumberedBibliographyEntries() {
        let text = """
        References

        [1] Smith, J., & Doe, A. (2020). Quantum reading with structured references. Journal of Examples, 12(3), 45-67. https://doi.org/10.1234/example.2020.001
        [2] Vaswani, A. et al. (2017). Attention is all you need. In Advances in Neural Information Processing Systems (pp. 5998-6008).
        [3] Chen, L. A study of local-first readers. arXiv:2101.12345v2.
        """
        let drafts = PaperReferenceParser.entries(from: [
            PaperReferencePageText(pageIndex: 9, pageLabel: "10", text: text)
        ])
        XCTAssertEqual(drafts.count, 3)
        XCTAssertEqual(drafts[0].label, "1")
        XCTAssertEqual(drafts[0].authors, "Smith, J., & Doe, A")
        XCTAssertEqual(drafts[0].firstAuthor, "Smith")
        XCTAssertEqual(drafts[0].title, "Quantum reading with structured references")
        XCTAssertEqual(drafts[0].year, 2020)
        XCTAssertEqual(drafts[0].doi, "10.1234/example.2020.001")
        XCTAssertEqual(drafts[0].pageIndex, 9)
        XCTAssertEqual(drafts[1].year, 2017)
        XCTAssertEqual(drafts[1].firstAuthor, "Vaswani")
        XCTAssertEqual(drafts[2].arxivID, "2101.12345v2")
    }

    func testParserStopsAtAppendixAndSupplementarySections() {
        let drafts = PaperReferenceParser.entries(from: [
            PaperReferencePageText(pageIndex: 7, pageLabel: "8", text: """
            References

            [1] Smith, J. (2020). A local first reader. Journal of Examples, 1, 1-2.
            [2] Doe, A. (2021). Another paper. Journal of Tests, 2, 3-4.
            """),
            PaperReferencePageText(pageIndex: 8, pageLabel: "9", text: """
            Appendix A. Additional checks

            [1] Appendix, A. (2022). This is not a bibliography entry.
            [2] Appendix, B. (2023). This must not replace bibliography item 2.

            Supplementary Materials

            [1] Supplement, S. (2024). More material that is not a bibliography entry.
            """)
        ])

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.label), ["1", "2"])
        XCTAssertEqual(Set(drafts.map(\.label)).count, drafts.count)
        XCTAssertTrue(drafts.allSatisfy { !$0.rawText.contains("Appendix") && !$0.rawText.contains("Supplement") })
    }

    func testParserKeepsSingleNumberedBibliographyEntryLabel() {
        let drafts = PaperReferenceParser.entries(from: [
            PaperReferencePageText(pageIndex: 4, pageLabel: "5", text: """
            Bibliography

            [1] Smith, J. (2020). A local first reader. Journal of Examples, 1, 1-2.

            Appendix B: One numbered item in an appendix
            [1] Appendix, A. (2022). This is not a bibliography entry.
            """)
        ])

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.label, "1")
        XCTAssertEqual(drafts.first?.firstAuthor, "Smith")
    }

    func testStorageVerifiesAndReindexesWithoutDroppingVerifiedMetadata() throws {
        let source = try makePDF(named: "references.pdf")
        let store = try LibraryStore(rootURL: temporaryDirectory.appendingPathComponent("library", isDirectory: true))
        let paper = try store.importPDF(from: source, title: "References", pageCount: 3)
        let drafts = PaperReferenceParser.entries(from: [
            PaperReferencePageText(pageIndex: 2, pageLabel: "3", text: """
            Bibliography
            [1] Smith, J. (2020). A local first reader. Journal of Examples, 1, 1-2. doi:10.1234/one
            [2] Doe, A. (2021). Another paper. Journal of Tests, 2, 3-4.
            """)
        ])
        XCTAssertEqual(drafts.count, 2)
        try store.replacePDFBibliography(paperID: paper.id, entries: drafts,
                                          headingPageIndex: 2, parserVersion: PaperReferenceParser.version)
        var references = try store.references(paperID: paper.id)
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(references.first?.status, .unverified)
        XCTAssertEqual(try store.referenceIndex(paperID: paper.id)?.state, PaperReferenceIndex.State.ready)

        let first = try XCTUnwrap(references.first)
        let verified = try store.verifyReference(id: first.id, authors: "Smith, John", title: "A Local First Reader",
                                                 year: 2020, venue: "Journal of Examples", doi: "10.1234/one",
                                                 arxivID: nil, url: nil, bibtex: nil,
                                                 verifiedBy: "Codex", evidenceURL: "https://doi.org/10.1234/one")
        XCTAssertEqual(verified.status, .verified)
        XCTAssertEqual(verified.firstAuthor, "Smith")
        XCTAssertEqual(verified.verifiedBy, "Codex")

        // A parser re-run must keep the AI-verified fields even if the local
        // extraction was weaker.
        let weaker = PaperReferenceDraft(label: "1", entryIndex: 0, authors: nil, firstAuthor: nil,
                                          title: nil, year: nil, venue: nil, doi: "10.1234/one",
                                          arxivID: nil, url: nil,
                                          rawText: "[1] Smith, J. (2020). A local first reader.",
                                          pageIndex: 2, pageLabel: "3", fingerprint: "reindexed-fingerprint")
        try store.replacePDFBibliography(paperID: paper.id, entries: [weaker],
                                          headingPageIndex: 2, parserVersion: PaperReferenceParser.version)
        references = try store.references(paperID: paper.id)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.status, .verified)
        XCTAssertEqual(references.first?.title, "A Local First Reader")
        XCTAssertEqual(references.first?.authors, "Smith, John")

        let reopened = try LibraryStore(rootURL: temporaryDirectory.appendingPathComponent("library", isDirectory: true))
        XCTAssertEqual(try reopened.references(paperID: paper.id).first?.status, .verified)
    }

    private func makePDF(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        let data = Data("%PDF-1.7\n% PaperDesk test fixture\n".utf8)
        try data.write(to: url)
        return url
    }
}
