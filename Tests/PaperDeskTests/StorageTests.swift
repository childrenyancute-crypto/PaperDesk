import Foundation
import XCTest
@testable import PaperDeskCore
@testable import PaperDeskStorage

final class StorageTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try super.tearDownWithError()
    }

    func testImportDeduplicatesAndReopensWithPositionAndTags() throws {
        let source = try makePDF(named: "quantum-paper.pdf")
        let store = try LibraryStore(rootURL: temporaryDirectory.appendingPathComponent("library", isDirectory: true))
        let first = try store.importPDF(from: source, title: "Quantum Paper", pageCount: 4)
        let duplicate = try store.importPDF(from: source, title: "A different title", pageCount: 4)
        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(try store.papers().count, 1)

        try store.updateReadingPosition(paperID: first.id, pageIndex: 2)
        try store.setTags(paperID: first.id, tags: ["QFT", "QFT", " ", "theory"])
        try store.setReadingState(paperID: first.id, state: "reading")

        let reopened = try LibraryStore(rootURL: temporaryDirectory.appendingPathComponent("library", isDirectory: true))
        let persisted = try reopened.paper(id: first.id)
        XCTAssertEqual(persisted.lastPageIndex, 2)
        XCTAssertEqual(persisted.tags, ["QFT", "theory"])
        XCTAssertEqual(persisted.readingState, "reading")
        XCTAssertEqual(Data(contentsOf: reopened.pdfURL(for: persisted)), Data(contentsOf: source))
    }

    func testContextAndIdempotentNoteAndRevisionConflict() throws {
        let source = try makePDF(named: "formula.pdf")
        let store = try LibraryStore(rootURL: temporaryDirectory.appendingPathComponent("library", isDirectory: true))
        let paper = try store.importPDF(from: source, title: "Formula", pageCount: 2)
        let context = ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash, pageIndex: 1, pageLabel: "2", text: "E = mc^2", regions: [PageRegion(pageIndex: 1, x: 10, y: 12, width: 80, height: 24)])
        let savedContext = try store.saveContext(context)
        XCTAssertEqual(try store.context(id: savedContext.id), savedContext)

        let note = ReadingNote(paperID: paper.id, contextID: savedContext.id, pageIndex: 1, pageLabel: "2", quote: "E = mc^2", content: "Check the units.", source: "ai", status: "draft")
        let first = try store.insertNote(note, idempotencyKey: "unit-check")
        let retry = try store.insertNote(note, idempotencyKey: "unit-check")
        XCTAssertEqual(first, retry)
        XCTAssertEqual(try store.notes(paperID: paper.id).count, 1)

        let updated = try store.updateNote(id: first.id, content: "The dimensions match.", status: "accepted", expectedRevision: 1)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertThrowsError(try store.updateNote(id: first.id, content: "stale", status: "accepted", expectedRevision: 1)) { error in
            guard case PaperDeskError.conflict = error else { return XCTFail("expected a revision conflict") }
        }
        XCTAssertTrue(try store.search(query: "dimensions").contains(where: { $0.id == paper.id }))
    }

    func testRejectsInvalidContextVersionAndDuplicateIdempotencyPayload() throws {
        let source = try makePDF(named: "invalid.pdf")
        let store = try LibraryStore(rootURL: temporaryDirectory.appendingPathComponent("library", isDirectory: true))
        let paper = try store.importPDF(from: source, title: "Invalid Cases", pageCount: 1)
        let invalid = ContextSnapshot(paperID: paper.id, documentHash: "wrong", pageIndex: 0, pageLabel: "1", text: "text")
        XCTAssertThrowsError(try store.saveContext(invalid))

        let note = ReadingNote(paperID: paper.id, pageIndex: 0, pageLabel: "1", content: "first")
        _ = try store.insertNote(note, idempotencyKey: "same-key")
        let changed = ReadingNote(id: UUID().uuidString, paperID: paper.id, pageIndex: 0, pageLabel: "1", content: "second")
        XCTAssertThrowsError(try store.insertNote(changed, idempotencyKey: "same-key")) { error in
            guard case PaperDeskError.conflict = error else { return XCTFail("expected an idempotency conflict") }
        }
    }

    func testBackupContainsDatabaseAndAssets() throws {
        let source = try makePDF(named: "backup.pdf")
        let libraryURL = temporaryDirectory.appendingPathComponent("library", isDirectory: true)
        let store = try LibraryStore(rootURL: libraryURL)
        let paper = try store.importPDF(from: source, title: "Backup", pageCount: 1)
        _ = try store.insertNote(ReadingNote(paperID: paper.id, pageIndex: 0, pageLabel: "1", content: "kept"))
        let backupURL = temporaryDirectory.appendingPathComponent("backup", isDirectory: true)
        try store.backup(to: backupURL)
        let restored = try LibraryStore(rootURL: backupURL)
        XCTAssertEqual(try restored.papers().count, 1)
        XCTAssertEqual(try restored.notes(paperID: paper.id).first?.content, "kept")
        XCTAssertEqual(Data(contentsOf: restored.pdfURL(for: paper)), Data(contentsOf: source))
    }

    func testSnapshotCitationsNumberPerAnswerAndRejectForeignContexts() throws {
        let source = try makePDF(named: "citations.pdf")
        let store = try LibraryStore(rootURL: temporaryDirectory.appendingPathComponent("library", isDirectory: true))
        let paper = try store.importPDF(from: source, title: "Citations", pageCount: 2)
        let state = PaperReadingState(paperID: paper.id, documentHash: paper.fileHash)
        let snapshot = ReadingQuestionSnapshot(state: state)
        try store.freezeReadingState(snapshot)

        let first = try store.saveContext(ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash,
                                                          pageIndex: 0, pageLabel: "1", text: "first quote",
                                                          regions: [PageRegion(pageIndex: 0, x: 10, y: 10, width: 40, height: 12)]))
        let second = try store.saveContext(ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash,
                                                           pageIndex: 1, pageLabel: "2", text: "second quote",
                                                           regions: [PageRegion(pageIndex: 1, x: 10, y: 30, width: 50, height: 12)]))
        let firstCitation = try store.addSnapshotCitation(snapshotID: snapshot.id, contextID: first.id)
        XCTAssertEqual(firstCitation.number, 1)
        let repeated = try store.addSnapshotCitation(snapshotID: snapshot.id, contextID: first.id)
        XCTAssertEqual(repeated.number, 1)
        let secondCitation = try store.addSnapshotCitation(snapshotID: snapshot.id, contextID: second.id)
        XCTAssertEqual(secondCitation.number, 2)
        XCTAssertEqual(try store.snapshotCitations(snapshotID: snapshot.id).map(\.number), [1, 2])

        let other = try store.importPDF(from: try makePDF(named: "other.pdf"), title: "Other", pageCount: 1)
        let foreign = try store.saveContext(ContextSnapshot(paperID: other.id, documentHash: other.fileHash,
                                                            pageIndex: 0, pageLabel: "1", text: "foreign"))
        XCTAssertThrowsError(try store.addSnapshotCitation(snapshotID: snapshot.id, contextID: foreign.id)) { error in
            guard case PaperDeskError.conflict = error else { return XCTFail("expected a version conflict") }
        }

        let citations = [MessageCitation(contextID: first.id, label: "1", pageLabel: "1"),
                         MessageCitation(contextID: second.id, label: "2", pageLabel: "2")]
        let id = try store.appendDiscussion(paperID: paper.id, snapshotID: snapshot.id,
                                            question: "How?",
                                            answer: "See ⟦1⟧ and ⟦2⟧.",
                                            sourceContextIDs: [], idempotencyKey: "citations-key",
                                            citations: citations, origin: RecordOrigin(clientName: "Codex")).id
        let session = try store.chatSession(paperID: paper.id)
        let answer = try XCTUnwrap(session.messages.first(where: { $0.id == id }))
        XCTAssertEqual(answer.citations?.map(\.label), ["1", "2"])
        XCTAssertEqual(answer.citations?.map(\.contextID), [first.id, second.id])

        // An exact retry replays; changing the citation payload conflicts.
        XCTAssertEqual(try store.appendDiscussion(paperID: paper.id, snapshotID: snapshot.id,
                                                  question: "How?", answer: "See ⟦1⟧ and ⟦2⟧.",
                                                  sourceContextIDs: [], idempotencyKey: "citations-key",
                                                  citations: citations).id, id)
        XCTAssertThrowsError(try store.appendDiscussion(paperID: paper.id, snapshotID: snapshot.id,
                                                        question: "How?", answer: "See ⟦1⟧ and ⟦2⟧.",
                                                        sourceContextIDs: [], idempotencyKey: "citations-key",
                                                        citations: [MessageCitation(contextID: first.id, label: "1")]))
        XCTAssertThrowsError(try store.appendDiscussion(paperID: paper.id, snapshotID: snapshot.id,
                                                        question: "Bad", answer: "Bad",
                                                        sourceContextIDs: [], idempotencyKey: "foreign-key",
                                                        citations: [MessageCitation(contextID: foreign.id, label: "1")])) { error in
            guard case PaperDeskError.conflict = error else { return XCTFail("expected a citation conflict") }
        }
        XCTAssertEqual(try store.snapshotCitations(snapshotID: snapshot.id).count, 2)
    }

    private func makePDF(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        let data = Data("%PDF-1.7\n% PaperDesk test fixture\n".utf8)
        try data.write(to: url)
        return url
    }
}
