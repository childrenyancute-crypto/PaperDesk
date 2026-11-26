import CryptoKit
import Foundation
import SQLite3
import PaperDeskCore

/// One numbered citation created for a frozen reading snapshot.
public struct SnapshotCitation: Equatable, Sendable {
    public let number: Int
    public let context: ContextSnapshot

    public init(number: Int, context: ContextSnapshot) {
        self.number = number
        self.context = context
    }
}

/// The single-process, local library store used by the reader and the MCP bridge.
///
/// The store owns the database connection. Callers should serialize writes through
/// one instance (the application does this on its main model queue).
public final class LibraryStore {
    public let rootURL: URL

    private let databaseURL: URL
    private let pdfsURL: URL
    private let contextsURL: URL
    private var database: OpaquePointer?
    private let isoFormatter: ISO8601DateFormatter
    private let fileManager = FileManager.default
    private let maxContextImageBytes = 16 * 1024 * 1024

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.databaseURL = self.rootURL.appendingPathComponent("library.sqlite")
        self.pdfsURL = self.rootURL.appendingPathComponent("pdfs", isDirectory: true)
        self.contextsURL = self.rootURL.appendingPathComponent("contexts", isDirectory: true)
        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let rootExisted = fileManager.fileExists(atPath: self.rootURL.path)
        if rootExisted {
            let rootValues = try self.rootURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard rootValues.isSymbolicLink != true else { throw PaperDeskError.invalid("资料库路径不能是符号链接") }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: self.rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PaperDeskError.invalid("资料库路径必须是专用目录")
            }
            let entries = try fileManager.contentsOfDirectory(atPath: self.rootURL.path)
            let containsDatabase = fileManager.fileExists(atPath: self.databaseURL.path)
            guard entries.isEmpty || containsDatabase else {
                throw PaperDeskError.invalid("资料库目录必须为空，或已经是 PaperDesk 资料库；请新建一个专用文件夹")
            }
        }
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try setPrivateDirectory(self.rootURL)
        try fileManager.createDirectory(at: self.pdfsURL, withIntermediateDirectories: true)
        try setPrivateDirectory(self.pdfsURL)
        try fileManager.createDirectory(at: self.contextsURL, withIntermediateDirectories: true)
        try setPrivateDirectory(self.contextsURL)

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "无法打开资料库"
            if let handle { sqlite3_close(handle) }
            throw PaperDeskError.invalid("无法打开资料库：\(message)")
        }
        self.database = handle
        do {
            try setPrivateFile(databaseURL)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 5000")
            try execute("PRAGMA journal_mode = WAL")
            try migrate()
        } catch {
            sqlite3_close(handle)
            self.database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    // MARK: - Public paper API

    public func importPDF(from sourceURL: URL, title: String, pageCount: Int) throws -> Paper {
        guard pageCount > 0 else { throw PaperDeskError.invalid("PDF 页数必须大于零") }
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw PaperDeskError.missing("找不到 PDF 文件") }
        guard fileManager.isReadableFile(atPath: sourceURL.path) else { throw PaperDeskError.invalid("PDF 文件不可读") }
        guard try isPDF(sourceURL) else { throw PaperDeskError.invalid("文件不是有效的 PDF") }

        let hash = try sha256(sourceURL)
        if let existing = try paper(withFileHash: hash) {
            guard fileManager.fileExists(atPath: pdfURL(for: existing).path) else {
                throw PaperDeskError.invalid("资料库中的 PDF 文件已丢失：\(existing.fileName)")
            }
            return existing
        }

        let originalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = originalTitle.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : originalTitle
        let paper = Paper(title: displayTitle,
                          fileName: sourceURL.lastPathComponent,
                          fileHash: hash,
                          pageCount: pageCount,
                          projectName: displayTitle)
        let managedURL = pdfURL(for: paper)
        try fileManager.copyItem(at: sourceURL, to: managedURL)
        try setPrivateFile(managedURL)
        do {
            try transaction {
                let sql = """
                INSERT INTO papers (id,title,file_name,file_hash,page_count,last_page_index,tags_json,reading_state,bibtex,added_at,updated_at,project_name)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """
                try withStatement(sql) { statement in
                    bindText(statement, 1, paper.id)
                    bindText(statement, 2, paper.title)
                    bindText(statement, 3, paper.fileName)
                    bindText(statement, 4, paper.fileHash)
                    bindInt(statement, 5, paper.pageCount)
                    bindInt(statement, 6, paper.lastPageIndex)
                    bindText(statement, 7, try encodeTags(paper.tags))
                    bindText(statement, 8, paper.readingState)
                    bindText(statement, 9, paper.bibtex)
                    bindDate(statement, 10, paper.addedAt)
                    bindDate(statement, 11, paper.updatedAt)
                    bindText(statement, 12, paper.projectName ?? "")
                    try stepDone(statement)
                }
            }
        } catch {
            try? fileManager.removeItem(at: managedURL)
            if let existing = try? self.paper(withFileHash: hash) { return existing }
            throw error
        }
        // Read the committed row back so dates and any SQLite-normalized values
        // have exactly the same representation as a later reopen/dedup lookup.
        guard let persisted = try self.paper(withID: paper.id) else { throw PaperDeskError.invalid("导入后的文献不存在") }
        return persisted
    }

    public func papers() throws -> [Paper] {
        try withStatement("SELECT id,title,file_name,file_hash,page_count,last_page_index,tags_json,reading_state,bibtex,added_at,updated_at,project_name FROM papers ORDER BY updated_at DESC, title COLLATE NOCASE ASC") { statement in
            var result: [Paper] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(try makePaper(statement)) }
            try checkLastStep(statement)
            return result
        }
    }

    public func paper(id: String) throws -> Paper {
        guard !id.isEmpty else { throw PaperDeskError.invalid("文献 ID 不能为空") }
        guard let paper = try paper(withID: id) else { throw PaperDeskError.missing("找不到文献") }
        return paper
    }

    public func pdfURL(for paper: Paper) -> URL {
        pdfsURL.appendingPathComponent(secureFileName(paper.id) + ".pdf")
    }

    public func annotatedPDFURL(for paper: Paper) -> URL {
        pdfsURL.appendingPathComponent(secureFileName(paper.id) + "-annotated.pdf")
    }

    public func readingPDFURL(for paper: Paper) -> URL {
        let annotated = annotatedPDFURL(for: paper)
        return FileManager.default.fileExists(atPath: annotated.path) ? annotated : pdfURL(for: paper)
    }

    /// The last successful request made by the Codex project bound to this
    /// paper and PDF version. This is kept in the library so the reader can
    /// show a real connection history after it is reopened.
    public func projectContact(paperID: String) throws -> Date? {
        let paper = try paper(id: paperID)
        return try withStatement("SELECT last_contact FROM paper_project_contacts WHERE paper_id = ? AND document_hash = ?") { statement in
            bindText(statement, 1, paperID)
            bindText(statement, 2, paper.fileHash)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                try checkLastStep(statement)
                return nil
            }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    /// Records a verified bound-project request. The hash check prevents a
    /// stale Codex project from appearing connected to a newly imported PDF.
    public func recordProjectContact(paperID: String, documentHash: String, at date: Date = Date()) throws {
        let paper = try paper(id: paperID)
        guard paper.fileHash == documentHash else {
            throw PaperDeskError.conflict("Codex 项目绑定的 PDF 版本已经变化")
        }
        try withStatement("""
        INSERT INTO paper_project_contacts (paper_id, document_hash, last_contact)
        VALUES (?, ?, ?)
        ON CONFLICT(paper_id) DO UPDATE SET document_hash = excluded.document_hash,
                                            last_contact = excluded.last_contact
        """) { statement in
            bindText(statement, 1, paperID)
            bindText(statement, 2, documentHash)
            bindDate(statement, 3, date)
            try stepDone(statement)
        }
    }

    public func updateReadingPosition(paperID: String, pageIndex: Int) throws {
        let current = try paper(id: paperID)
        guard pageIndex >= 0, pageIndex < current.pageCount else { throw PaperDeskError.invalid("页码超出文献范围") }
        try transaction {
            try withStatement("UPDATE papers SET last_page_index = ?, updated_at = ? WHERE id = ?") { statement in
                bindInt(statement, 1, pageIndex); bindDate(statement, 2, Date()); bindText(statement, 3, paperID); try stepDone(statement)
            }
        }
    }

    public func setTags(paperID: String, tags: [String]) throws {
        _ = try paper(id: paperID)
        var seen = Set<String>()
        let normalized = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.filter { seen.insert($0).inserted }
        try transaction {
            try withStatement("UPDATE papers SET tags_json = ?, updated_at = ? WHERE id = ?") { statement in
                bindText(statement, 1, try encodeTags(normalized)); bindDate(statement, 2, Date()); bindText(statement, 3, paperID); try stepDone(statement)
            }
        }
    }

    public func setBibliography(paperID: String, bibtex: String) throws {
        _ = try paper(id: paperID)
        try transaction {
            try withStatement("UPDATE papers SET bibtex = ?, updated_at = ? WHERE id = ?") { statement in
                bindText(statement, 1, bibtex); bindDate(statement, 2, Date()); bindText(statement, 3, paperID); try stepDone(statement)
            }
        }
    }

    // MARK: - Paper references

    public func referenceIndex(paperID: String) throws -> PaperReferenceIndex? {
        try withStatement("SELECT state, parser_version, heading_page_index, entry_count, indexed_at, error FROM paper_reference_index WHERE paper_id = ?") { statement in
            bindText(statement, 1, paperID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let state = PaperReferenceIndex.State(rawValue: try requiredText(statement, 0)) ?? .failed
            return PaperReferenceIndex(
                paperID: paperID,
                state: state,
                parserVersion: Int(sqlite3_column_int(statement, 1)),
                headingPageIndex: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2)),
                entryCount: Int(sqlite3_column_int(statement, 3)),
                indexedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : date(sqlite3_column_double(statement, 4)),
                error: optionalText(statement, 5)
            )
        }
    }

    public func references(paperID: String) throws -> [PaperReference] {
        try withStatement("SELECT \(referenceColumns) FROM paper_references WHERE paper_id = ? ORDER BY entry_index ASC, label COLLATE NOCASE ASC") { statement in
            bindText(statement, 1, paperID)
            var result: [PaperReference] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(try makeReference(statement)) }
            try checkLastStep(statement)
            return result
        }
    }

    public func reference(id: String) throws -> PaperReference? {
        try withStatement("SELECT \(referenceColumns) FROM paper_references WHERE id = ?") { statement in
            bindText(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try makeReference(statement)
        }
    }

    public func markReferenceIndex(paperID: String, state: PaperReferenceIndex.State,
                                   parserVersion: Int, headingPageIndex: Int? = nil,
                                   entryCount: Int = 0, error: String? = nil) throws {
        _ = try paper(id: paperID)
        let indexedAt = state == .ready ? Date() : nil
        try transaction {
            try withStatement("""
                INSERT INTO paper_reference_index (paper_id,state,parser_version,heading_page_index,entry_count,indexed_at,error)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(paper_id) DO UPDATE SET state=excluded.state,
                    parser_version=excluded.parser_version,
                    heading_page_index=excluded.heading_page_index,
                    entry_count=excluded.entry_count,
                    indexed_at=excluded.indexed_at,
                    error=excluded.error
                """) { statement in
                bindText(statement, 1, paperID)
                bindText(statement, 2, state.rawValue)
                bindInt(statement, 3, parserVersion)
                if let headingPageIndex { bindInt(statement, 4, headingPageIndex) } else { sqlite3_bind_null(statement, 4) }
                bindInt(statement, 5, entryCount)
                if let indexedAt { bindDate(statement, 6, indexedAt) } else { sqlite3_bind_null(statement, 6) }
                if let error { bindText(statement, 7, error) } else { sqlite3_bind_null(statement, 7) }
                try stepDone(statement)
            }
        }
    }

    /// Replaces the locally extracted bibliography. Every unverified row is
    /// rebuilt from the new parse; AI-verified rows survive by fingerprint,
    /// label, or title+year and keep their confirmed fields.
    public func replacePDFBibliography(paperID: String, entries: [PaperReferenceDraft],
                                       headingPageIndex: Int?, parserVersion: Int) throws {
        _ = try paper(id: paperID)
        var seen = Set<String>()
        let drafts = entries.filter { seen.insert($0.fingerprint).inserted }
        let existing = try references(paperID: paperID)
        let verified = existing.filter { $0.source == .pdfBibliography && $0.status == .verified }
        var byFingerprint: [String: PaperReference] = [:]
        var byLabel: [String: PaperReference] = [:]
        var byTitleYear: [String: PaperReference] = [:]
        var titleYearCounts: [String: Int] = [:]
        for reference in verified {
            if let fingerprint = reference.fingerprint, byFingerprint[fingerprint] == nil {
                byFingerprint[fingerprint] = reference
            }
            let label = normalizedReferenceLabel(reference.label)
            if byLabel[label] == nil { byLabel[label] = reference }
            if let key = titleYearKey(label: nil, title: reference.title, year: reference.year) {
                titleYearCounts[key, default: 0] += 1
                byTitleYear[key] = reference
            }
        }
        for (key, count) in titleYearCounts where count > 1 {
            byTitleYear.removeValue(forKey: key)
        }
        let draftLabels = Set(drafts.map { normalizedReferenceLabel($0.label) })
        let now = Date()
        var keptIDs = Set<String>()
        try transaction {
            // Local extraction is disposable. Verified rows are not.
            for reference in existing where reference.source == .pdfBibliography && reference.status == .unverified {
                try withStatement("DELETE FROM paper_references WHERE id = ?") { statement in
                    bindText(statement, 1, reference.id)
                    try stepDone(statement)
                }
            }
            for draft in drafts {
                let label = normalizedReferenceLabel(draft.label)
                let titleYear = titleYearKey(label: nil, title: draft.title, year: draft.year)
                let reference = byFingerprint[draft.fingerprint].flatMap { keptIDs.contains($0.id) ? nil : $0 }
                    ?? byLabel[label].flatMap { keptIDs.contains($0.id) ? nil : $0 }
                    ?? titleYear.flatMap { byTitleYear[$0] }.flatMap { keptIDs.contains($0.id) ? nil : $0 }
                if let reference {
                    keptIDs.insert(reference.id)
                    try withStatement("""
                        UPDATE paper_references SET label=?, entry_index=?, first_author=?, raw_text=?,
                            page_index=?, page_label=?, parser_version=?, updated_at=?
                        WHERE id=?
                        """) { statement in
                        bindText(statement, 1, draft.label)
                        bindInt(statement, 2, draft.entryIndex)
                        bindOptionalText(statement, 3, firstAuthor(from: reference.authors) ?? draft.firstAuthor)
                        bindText(statement, 4, draft.rawText)
                        bindInt(statement, 5, draft.pageIndex)
                        bindText(statement, 6, draft.pageLabel)
                        bindInt(statement, 7, parserVersion)
                        bindDate(statement, 8, now)
                        bindText(statement, 9, reference.id)
                        try stepDone(statement)
                    }
                } else {
                    let reference = PaperReference(
                        paperID: paperID, label: draft.label, entryIndex: draft.entryIndex,
                        authors: draft.authors, firstAuthor: draft.firstAuthor, title: draft.title,
                        year: draft.year, venue: draft.venue, doi: draft.doi, arxivID: draft.arxivID,
                        url: draft.url, rawText: draft.rawText, status: .unverified,
                        source: .pdfBibliography, pageIndex: draft.pageIndex, pageLabel: draft.pageLabel,
                        parserVersion: parserVersion, fingerprint: draft.fingerprint,
                        createdAt: now, updatedAt: now)
                    keptIDs.insert(reference.id)
                    try insertReference(reference)
                }
            }
            // Merge duplicate verified rows that describe the same work as a
            // kept row, or whose label still exists in the new bibliography.
            let kept = verified.filter { keptIDs.contains($0.id) }
            let keptFingerprints = Set(kept.compactMap(\.fingerprint))
            let keptTitleYears = Set(kept.compactMap { titleYearKey(label: nil, title: $0.title, year: $0.year) })
            for reference in verified where !keptIDs.contains(reference.id) {
                let sameWork = reference.fingerprint.map { keptFingerprints.contains($0) } ?? false
                let sameTitleYear = titleYearKey(label: nil, title: reference.title, year: reference.year)
                    .map { keptTitleYears.contains($0) } ?? false
                guard draftLabels.contains(normalizedReferenceLabel(reference.label))
                        || sameWork || sameTitleYear else { continue }
                try withStatement("DELETE FROM paper_references WHERE id = ?") { statement in
                    bindText(statement, 1, reference.id)
                    try stepDone(statement)
                }
            }
            try withStatement("""
                INSERT INTO paper_reference_index (paper_id,state,parser_version,heading_page_index,entry_count,indexed_at,error)
                VALUES (?,?,?,?,?,?,NULL)
                ON CONFLICT(paper_id) DO UPDATE SET state=excluded.state,
                    parser_version=excluded.parser_version,
                    heading_page_index=excluded.heading_page_index,
                    entry_count=excluded.entry_count,
                    indexed_at=excluded.indexed_at,
                    error=NULL
                """) { statement in
                bindText(statement, 1, paperID)
                bindText(statement, 2, PaperReferenceIndex.State.ready.rawValue)
                bindInt(statement, 3, parserVersion)
                if let headingPageIndex { bindInt(statement, 4, headingPageIndex) } else { sqlite3_bind_null(statement, 4) }
                bindInt(statement, 5, drafts.count)
                bindDate(statement, 6, now)
                try stepDone(statement)
            }
        }
    }

    private func normalizedReferenceLabel(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private func titleYearKey(label: String?, title: String?, year: Int?) -> String? {
        guard let year, let title else { return nil }
        let normalized = title.lowercased().filter { $0.isLetter || $0.isNumber }
        guard normalized.count >= 4 else { return nil }
        return normalized + "|" + String(year)
    }

    @discardableResult
    public func verifyReference(id: String, authors: String?, title: String?, year: Int?,
                                venue: String?, doi: String?, arxivID: String?, url: String?,
                                bibtex: String?, verifiedBy: String, evidenceURL: String?) throws -> PaperReference {
        guard let current = try reference(id: id) else { throw PaperDeskError.missing("找不到这条参考文献") }
        let now = Date()
        let nextAuthors = nonEmpty(authors) ?? current.authors
        let nextTitle = nonEmpty(title) ?? current.title
        let nextVenue = nonEmpty(venue) ?? current.venue
        let nextDOI = nonEmpty(doi) ?? current.doi
        let nextArxiv = nonEmpty(arxivID) ?? current.arxivID
        let nextURL = nonEmpty(url) ?? current.url
        let nextBibtex = nonEmpty(bibtex) ?? current.bibtex
        let nextYear = year ?? current.year
        try withStatement("""
            UPDATE paper_references SET authors=?, first_author=?, title=?, year=?, venue=?, doi=?,
                arxiv_id=?, url=?, bibtex=?, status=?, verified_at=?, verified_by=?, evidence_url=?, updated_at=?
            WHERE id=?
            """) { statement in
            bindOptionalText(statement, 1, nextAuthors)
            bindOptionalText(statement, 2, firstAuthor(from: nextAuthors))
            bindOptionalText(statement, 3, nextTitle)
            if let nextYear { bindInt(statement, 4, nextYear) } else { sqlite3_bind_null(statement, 4) }
            bindOptionalText(statement, 5, nextVenue)
            bindOptionalText(statement, 6, nextDOI)
            bindOptionalText(statement, 7, nextArxiv)
            bindOptionalText(statement, 8, nextURL)
            bindOptionalText(statement, 9, nextBibtex)
            bindText(statement, 10, PaperReferenceStatus.verified.rawValue)
            bindDate(statement, 11, now)
            bindText(statement, 12, verifiedBy)
            bindOptionalText(statement, 13, evidenceURL)
            bindDate(statement, 14, now)
            bindText(statement, 15, id)
            try stepDone(statement)
        }
        guard let updated = try reference(id: id) else { throw PaperDeskError.missing("找不到这条参考文献") }
        return updated
    }

    private static let referenceColumns = "id,paper_id,label,entry_index,authors,first_author,title,year,venue,doi,arxiv_id,url,bibtex,raw_text,status,source,page_index,page_label,parser_version,fingerprint,verified_at,verified_by,evidence_url,created_at,updated_at"

    private var referenceColumns: String { Self.referenceColumns }

    private func insertReference(_ reference: PaperReference) throws {
        try withStatement("""
            INSERT INTO paper_references (\(Self.referenceColumns))
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """) { statement in
            bindText(statement, 1, reference.id)
            bindText(statement, 2, reference.paperID)
            bindText(statement, 3, reference.label)
            bindInt(statement, 4, reference.entryIndex)
            bindOptionalText(statement, 5, reference.authors)
            bindOptionalText(statement, 6, reference.firstAuthor)
            bindOptionalText(statement, 7, reference.title)
            if let year = reference.year { bindInt(statement, 8, year) } else { sqlite3_bind_null(statement, 8) }
            bindOptionalText(statement, 9, reference.venue)
            bindOptionalText(statement, 10, reference.doi)
            bindOptionalText(statement, 11, reference.arxivID)
            bindOptionalText(statement, 12, reference.url)
            bindOptionalText(statement, 13, reference.bibtex)
            bindText(statement, 14, reference.rawText)
            bindText(statement, 15, reference.status.rawValue)
            bindText(statement, 16, reference.source.rawValue)
            bindInt(statement, 17, reference.pageIndex)
            bindText(statement, 18, reference.pageLabel)
            bindInt(statement, 19, reference.parserVersion)
            bindOptionalText(statement, 20, reference.fingerprint)
            if let verifiedAt = reference.verifiedAt { bindDate(statement, 21, verifiedAt) } else { sqlite3_bind_null(statement, 21) }
            bindOptionalText(statement, 22, reference.verifiedBy)
            bindOptionalText(statement, 23, reference.evidenceURL)
            bindDate(statement, 24, reference.createdAt)
            bindDate(statement, 25, reference.updatedAt)
            try stepDone(statement)
        }
    }

    private func makeReference(_ statement: OpaquePointer) throws -> PaperReference {
        let year = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 7))
        return PaperReference(
            id: try requiredText(statement, 0),
            paperID: try requiredText(statement, 1),
            label: try requiredText(statement, 2),
            entryIndex: Int(sqlite3_column_int(statement, 3)),
            authors: optionalText(statement, 4),
            firstAuthor: optionalText(statement, 5),
            title: optionalText(statement, 6),
            year: year,
            venue: optionalText(statement, 8),
            doi: optionalText(statement, 9),
            arxivID: optionalText(statement, 10),
            url: optionalText(statement, 11),
            bibtex: optionalText(statement, 12),
            rawText: try requiredText(statement, 13),
            status: PaperReferenceStatus(rawValue: try requiredText(statement, 14)) ?? .unverified,
            source: PaperReferenceSource(rawValue: try requiredText(statement, 15)) ?? .pdfBibliography,
            pageIndex: Int(sqlite3_column_int(statement, 16)),
            pageLabel: try requiredText(statement, 17),
            parserVersion: Int(sqlite3_column_int(statement, 18)),
            fingerprint: optionalText(statement, 19),
            verifiedAt: sqlite3_column_type(statement, 20) == SQLITE_NULL ? nil : date(sqlite3_column_double(statement, 20)),
            verifiedBy: optionalText(statement, 21),
            evidenceURL: optionalText(statement, 22),
            createdAt: date(sqlite3_column_double(statement, 23)),
            updatedAt: date(sqlite3_column_double(statement, 24))
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func firstAuthor(from authors: String?) -> String? {
        guard let authors = nonEmpty(authors) else { return nil }
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

    public func setProjectName(paperID: String, name: String) throws {
        _ = try paper(id: paperID)
        try transaction {
            try withStatement("UPDATE papers SET project_name = ? WHERE id = ?") { statement in
                bindText(statement, 1, name.trimmingCharacters(in: .whitespacesAndNewlines)); bindText(statement, 2, paperID); try stepDone(statement)
            }
        }
    }

    public func setReadingState(paperID: String, state: String) throws {
        _ = try paper(id: paperID)
        let normalized = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["unread", "reading", "read"].contains(normalized) else { throw PaperDeskError.invalid("阅读状态只能是 unread、reading 或 read") }
        try transaction {
            try withStatement("UPDATE papers SET reading_state = ?, updated_at = ? WHERE id = ?") { statement in
                bindText(statement, 1, normalized); bindDate(statement, 2, Date()); bindText(statement, 3, paperID); try stepDone(statement)
            }
        }
    }

    // MARK: - Contexts and notes

    public func saveContext(_ context: ContextSnapshot, imageData: Data? = nil) throws -> ContextSnapshot {
        let paper = try paper(id: context.paperID)
        guard context.documentHash == paper.fileHash else { throw PaperDeskError.conflict("选区对应的 PDF 版本不是当前文献版本") }
        guard context.pageIndex >= 0, context.pageIndex < paper.pageCount else { throw PaperDeskError.invalid("选区页码超出文献范围") }
        guard context.imageRelativePath == nil else { throw PaperDeskError.invalid("不能从调用方接受选区图片路径") }
        for region in context.regions {
            guard region.pageIndex >= 0, region.pageIndex < paper.pageCount,
                  region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
                  abs(region.x) <= 1_000_000, abs(region.y) <= 1_000_000,
                  region.width > 0, region.height > 0,
                  region.width <= 1_000_000, region.height <= 1_000_000 else {
                throw PaperDeskError.invalid("选区坐标无效")
            }
        }
        if let imageData {
            guard !imageData.isEmpty, imageData.count <= maxContextImageBytes else { throw PaperDeskError.invalid("选区图片大小无效") }
        }
        if let existing = try self.context(id: context.id) {
            let expected = ContextSnapshot(id: existing.id, paperID: context.paperID, documentHash: context.documentHash, pageIndex: context.pageIndex, pageLabel: context.pageLabel, text: context.text, regions: context.regions, imageRelativePath: existing.imageRelativePath, createdAt: existing.createdAt)
            if existing == expected { return existing }
            throw PaperDeskError.conflict("选区快照已经存在且不可修改")
        }

        var stored = context
        if let imageData {
            let relative = "contexts/\(secureFileName(context.id))\(ContextSnapshot.cropImageSuffix)"
            let destination = try safeRelativeURL(relative)
            try writeAtomically(imageData, to: destination)
            stored.imageRelativePath = relative
        }
        do {
            try transaction {
                try withStatement("INSERT INTO contexts (id,paper_id,document_hash,page_index,page_label,text,regions_json,image_relative_path,created_at) VALUES (?,?,?,?,?,?,?,?,?)") { statement in
                    bindText(statement, 1, stored.id); bindText(statement, 2, stored.paperID); bindText(statement, 3, stored.documentHash)
                    bindInt(statement, 4, stored.pageIndex); bindText(statement, 5, stored.pageLabel); bindText(statement, 6, stored.text)
                    bindText(statement, 7, try encodeRegions(stored.regions)); bindOptionalText(statement, 8, stored.imageRelativePath); bindDate(statement, 9, stored.createdAt)
                    try stepDone(statement)
                }
            }
        } catch {
            if let relative = stored.imageRelativePath, let imageURL = try? safeRelativeURL(relative) { try? fileManager.removeItem(at: imageURL) }
            throw error
        }
        guard let persisted = try self.context(id: stored.id) else { throw PaperDeskError.invalid("保存后的选区不存在") }
        return persisted
    }

    public func context(id: String) throws -> ContextSnapshot? {
        try withStatement("SELECT id,paper_id,document_hash,page_index,page_label,text,regions_json,image_relative_path,created_at FROM contexts WHERE id = ?") { statement in
            bindText(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try makeContext(statement)
        }
    }

    // MARK: - Reading state and anchored discussion

    /// Numbered citations attached to one frozen question snapshot, in
    /// footnote order.
    public func snapshotCitations(snapshotID: String) throws -> [SnapshotCitation] {
        let rows: [(number: Int, contextID: String)] = try withStatement(
            "SELECT number, context_id FROM snapshot_citations WHERE snapshot_id = ? ORDER BY number ASC"
        ) { statement in
            bindText(statement, 1, snapshotID)
            var values: [(Int, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append((Int(sqlite3_column_int(statement, 0)), try requiredText(statement, 1)))
            }
            return values
        }
        return rows.compactMap { row in
            guard let context = try? context(id: row.contextID) else { return nil }
            return SnapshotCitation(number: row.number, context: context)
        }
    }

    /// Registers a context as a footnote of one answer. The first call for a
    /// snapshot starts at 1; repeating the same context returns its existing
    /// number so a retried `cite_passage` never consumes a new footnote.
    @discardableResult
    public func addSnapshotCitation(snapshotID: String, contextID: String, maximum: Int = 32) throws -> SnapshotCitation {
        guard let snapshot = try readingSnapshot(id: snapshotID) else {
            throw PaperDeskError.missing("找不到这份阅读状态快照")
        }
        guard let context = try context(id: contextID) else {
            throw PaperDeskError.missing("找不到引用所在的固定选区")
        }
        guard context.paperID == snapshot.state.paperID,
              context.documentHash == snapshot.state.documentHash else {
            throw PaperDeskError.conflict("引用不属于这次阅读状态的文献版本")
        }
        return try transaction {
            let existingNumber: Int? = try withStatement(
                "SELECT number FROM snapshot_citations WHERE snapshot_id = ? AND context_id = ?"
            ) { statement in
                bindText(statement, 1, snapshotID)
                bindText(statement, 2, contextID)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return Int(sqlite3_column_int(statement, 0))
            }
            if let existingNumber {
                return SnapshotCitation(number: existingNumber, context: context)
            }
            let count: Int = try withStatement(
                "SELECT COUNT(*), COALESCE(MAX(number), 0) FROM snapshot_citations WHERE snapshot_id = ?"
            ) { statement in
                bindText(statement, 1, snapshotID)
                guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
                return Int(sqlite3_column_int(statement, 0))
            }
            guard count < maximum else {
                throw PaperDeskError.invalid("每条回答最多引用 \(maximum) 处原文")
            }
            let number: Int = try withStatement(
                "SELECT COALESCE(MAX(number), 0) FROM snapshot_citations WHERE snapshot_id = ?"
            ) { statement in
                bindText(statement, 1, snapshotID)
                guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
                return Int(sqlite3_column_int(statement, 0)) + 1
            }
            try withStatement(
                "INSERT INTO snapshot_citations (snapshot_id, context_id, number, created_at) VALUES (?,?,?,?)"
            ) { statement in
                bindText(statement, 1, snapshotID)
                bindText(statement, 2, contextID)
                bindInt(statement, 3, number)
                sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                try stepDone(statement)
            }
            return SnapshotCitation(number: number, context: context)
        }
    }

    public func readingState(paperID: String) throws -> PaperReadingState {
        let paper = try paper(id: paperID)
        return try withStatement("SELECT document_hash,page_index,visible_regions_json,selections_json,next_label,updated_at,focused_context_id FROM reading_states WHERE paper_id = ?") { statement in
            bindText(statement, 1, paperID)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return PaperReadingState(paperID: paper.id, documentHash: paper.fileHash,
                                         pageIndex: paper.lastPageIndex, updatedAt: paper.updatedAt)
            }
            let hash = try requiredText(statement, 0)
            guard hash == paper.fileHash else {
                throw PaperDeskError.conflict("阅读状态对应的 PDF 版本已经变化")
            }
            return PaperReadingState(
                paperID: paperID,
                documentHash: hash,
                pageIndex: Int(sqlite3_column_int(statement, 1)),
                visibleRegions: try decodeRegions(requiredText(statement, 2)),
                selections: try JSONDecoder().decode([ReadingSelection].self, from: Data(requiredText(statement, 3).utf8)),
                nextLabel: Int(sqlite3_column_int(statement, 4)),
                updatedAt: date(sqlite3_column_double(statement, 5)),
                focusedContextID: optionalText(statement, 6)
            )
        }
    }

    public func saveReadingState(_ state: PaperReadingState) throws {
        let paper = try paper(id: state.paperID)
        try validateReadingState(state, paper: paper)
        let regions = try encodeRegions(state.visibleRegions)
        let selections = String(decoding: try JSONEncoder().encode(state.selections), as: UTF8.self)
        try transaction {
            try withStatement("""
            INSERT INTO reading_states (paper_id,document_hash,page_index,visible_regions_json,selections_json,next_label,updated_at,focused_context_id)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(paper_id) DO UPDATE SET document_hash=excluded.document_hash,page_index=excluded.page_index,
              visible_regions_json=excluded.visible_regions_json,selections_json=excluded.selections_json,
              next_label=excluded.next_label,updated_at=excluded.updated_at,focused_context_id=excluded.focused_context_id
            """) { statement in
                bindText(statement, 1, state.paperID); bindText(statement, 2, state.documentHash); bindInt(statement, 3, state.pageIndex)
                bindText(statement, 4, regions); bindText(statement, 5, selections); bindInt(statement, 6, state.nextLabel); bindDate(statement, 7, state.updatedAt)
                bindOptionalText(statement, 8, state.focusedContextID)
                try stepDone(statement)
            }
            try withStatement("UPDATE papers SET last_page_index = ?, updated_at = ? WHERE id = ?") { statement in
                bindInt(statement, 1, state.pageIndex); bindDate(statement, 2, state.updatedAt); bindText(statement, 3, state.paperID); try stepDone(statement)
            }
        }
    }

    public func freezeReadingState(_ snapshot: ReadingQuestionSnapshot) throws {
        let paper = try paper(id: snapshot.state.paperID)
        try validateReadingState(snapshot.state, paper: paper)
        let goal = String(snapshot.readingGoal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
        let stateJSON = String(decoding: try JSONEncoder().encode(snapshot.state), as: UTF8.self)
        try transaction {
            if let existing = try readingSnapshot(id: snapshot.id) {
                guard existing.state == snapshot.state, existing.readingGoal == goal else {
                    throw PaperDeskError.conflict("阅读问题快照已经存在且不可修改")
                }
                return
            }
            try withStatement("INSERT INTO reading_snapshots (id,paper_id,document_hash,state_json,reading_goal,created_at) VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state_json=excluded.state_json,reading_goal=excluded.reading_goal") { statement in
                bindText(statement, 1, snapshot.id); bindText(statement, 2, paper.id); bindText(statement, 3, paper.fileHash)
                bindText(statement, 4, stateJSON); bindText(statement, 5, goal); bindDate(statement, 6, snapshot.createdAt); try stepDone(statement)
            }
        }
    }

    public func readingSnapshot(id: String) throws -> ReadingQuestionSnapshot? {
        try withStatement("SELECT state_json,reading_goal,created_at FROM reading_snapshots WHERE id = ?") { statement in
            bindText(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let state = try JSONDecoder().decode(PaperReadingState.self, from: Data((try requiredText(statement, 0)).utf8))
            return ReadingQuestionSnapshot(id: id, state: state, readingGoal: try requiredText(statement, 1), createdAt: date(sqlite3_column_double(statement, 2)))
        }
    }

    public func appendDiscussion(paperID: String, snapshotID: String, question: String, answer: String,
                                 sourceContextIDs: [String], idempotencyKey: String,
                                 citations: [MessageCitation] = [],
                                 origin: RecordOrigin? = nil, manuallyRecorded: Bool = false,
                                 sharedWithAI: Bool = false,
                                 conversationID: String? = nil, conversationTitle: String? = nil,
                                 continuingFrom previousDiscussionID: String? = nil,
                                 feedbackKind: ReadingFeedbackKind? = nil,
                                 feedbackEvidence: String? = nil,
                                 referencedWorks: [MessageReference]? = nil,
                                 citationWarnings: [String]? = nil,
                                 answerMode: ReadingAnswerMode? = nil) throws -> PaperChatMessage {
        let paper = try paper(id: paperID)
        let snapshot = try readingSnapshot(id: snapshotID)
        guard let snapshot, snapshot.state.paperID == paperID, snapshot.state.documentHash == paper.fileHash else {
            throw PaperDeskError.conflict("讨论所用的阅读状态不属于当前文献版本")
        }
        let questionKey = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answerKey = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !questionKey.isEmpty, !answerKey.isEmpty else { throw PaperDeskError.invalid("讨论内容不能为空") }
        let hasFeedbackKind = feedbackKind != nil
        let hasFeedbackEvidence = feedbackEvidence != nil
        guard hasFeedbackKind == hasFeedbackEvidence else {
            throw PaperDeskError.invalid("反馈类型和证据必须同时提供")
        }
        if feedbackKind != nil {
            guard !manuallyRecorded else { throw PaperDeskError.invalid("手动记录不能附加阅读反馈") }
            guard let feedbackEvidence,
                  !feedbackEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  feedbackEvidence.count <= 240 else {
                throw PaperDeskError.invalid("反馈证据长度必须为 1 到 240 个字符")
            }
            guard questionKey.contains(feedbackEvidence) else {
                throw PaperDeskError.invalid("反馈证据必须逐字来自当前问题")
            }
        }
        let ids = uniqueStrings(sourceContextIDs)
        let allowed = Set(snapshot.state.selections.map(\.id))
        guard ids.allSatisfy({ allowed.contains($0) }) else { throw PaperDeskError.conflict("讨论引用了本次阅读状态之外的选区") }
        let storedCitations = try snapshotCitations(snapshotID: snapshotID)
        let citationContextIDs = Set(storedCitations.map(\.context.id))
        let normalizedCitations: [MessageCitation] = citations.compactMap { citation in
            let contextID = citation.contextID.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = citation.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contextID.isEmpty, !label.isEmpty else { return nil }
            return MessageCitation(contextID: contextID, label: label, pageLabel: citation.pageLabel)
        }
        guard normalizedCitations.count == citations.count,
              Set(normalizedCitations.map(\.label)).count == normalizedCitations.count,
              normalizedCitations.allSatisfy({ citationContextIDs.contains($0.contextID) }) else {
            throw PaperDeskError.conflict("讨论引用了不属于这份阅读状态的出处")
        }
        let normalizedReferences = referencedWorks.map { works in
            works.filter { !$0.referenceID.isEmpty && !$0.label.isEmpty }
        }
        guard normalizedReferences?.count == referencedWorks?.count,
              (normalizedReferences?.count ?? 0) <= 500,
              Set(normalizedReferences?.map(\.referenceID) ?? []).count == (normalizedReferences?.count ?? 0) else {
            throw PaperDeskError.invalid("讨论包含重复或无效的参考文献链接")
        }
        if let normalizedReferences {
            let availableReferenceIDs = Set(try references(paperID: paperID).map(\.id))
            guard normalizedReferences.allSatisfy({ availableReferenceIDs.contains($0.referenceID) }) else {
                throw PaperDeskError.conflict("讨论引用了不属于当前文献的参考文献条目")
            }
        }
        let normalizedCitationWarnings = citationWarnings?.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        }.filter { !$0.isEmpty }
        guard normalizedCitationWarnings?.count ?? 0 <= 20 else {
            throw PaperDeskError.invalid("引用核对提示不能超过 20 条")
        }
        let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 256 else { throw PaperDeskError.invalid("讨论缺少有效的幂等标识") }
        let effectiveOrigin = normalizedOrigin(origin)
        let normalizedConversationID = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveConversationID = normalizedConversationID?.isEmpty == false ? normalizedConversationID : nil
        let normalizedTitle = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = normalizedTitle?.isEmpty == false ? normalizedTitle : nil
        // Client provenance belongs to the first successful write. Keep the
        // original retry key shape so upgrades and reconnections can replay it.
        var payloadObject: [String: Any] = [
            "paperID": paperID,
            "snapshotID": snapshotID,
            "question": questionKey,
            "answer": answerKey,
            "sourceContextIDs": ids,
            "citations": normalizedCitations.map { ["contextID": $0.contextID, "label": $0.label] }
        ]
        if manuallyRecorded {
            payloadObject["manuallyRecorded"] = true
            payloadObject["sharedWithAI"] = sharedWithAI
        }
        if let previousDiscussionID { payloadObject["previousDiscussionID"] = previousDiscussionID }
        if let feedbackKind, let feedbackEvidence {
            payloadObject["feedbackKind"] = feedbackKind.rawValue
            payloadObject["feedbackEvidence"] = feedbackEvidence
        }
        if let answerMode { payloadObject["answerMode"] = answerMode.rawValue }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]), as: UTF8.self)
        return try transaction {
            var session = try chatSession(paperID: paperID)
            if let existing = try discussionRequest(key: key) {
                guard existing.paperID == paperID, existing.payload == payload else { throw PaperDeskError.conflict("相同请求标识对应了不同的讨论") }
                guard let archived = session.messages.first(where: { $0.id == existing.responseID }) else {
                    throw PaperDeskError.missing("找不到这条已归档的讨论")
                }
                return archived
            }
            var resolvedConversationID = effectiveConversationID
            if let previousDiscussionID {
                guard !manuallyRecorded,
                      let previous = session.messages.first(where: { $0.id == previousDiscussionID }),
                      previous.role == .assistant, previous.manuallyRecorded != true, !previous.isExtractiveSummary,
                      previous.origin?.clientSourceLabel == effectiveOrigin?.clientSourceLabel,
                      let previousConversationID = previous.conversationID, !previousConversationID.isEmpty else {
                    throw PaperDeskError.conflict("无法续接此对话。请使用同一篇文献、同一客户端的已归档回答编号。")
                }
                resolvedConversationID = previousConversationID
            }
            let readingFeedback: ReadingFeedback?
            if let feedbackKind, let feedbackEvidence {
                guard let resolvedConversationID = normalizedConversationIdentifier(resolvedConversationID) else {
                    throw PaperDeskError.conflict("无法为反馈找到所属的外部对话")
                }
                let latestAssistant = session.messages.last { message in
                    message.role == .assistant && !message.isExtractiveSummary
                        && normalizedConversationIdentifier(message.conversationID) == resolvedConversationID
                }
                guard let latestAssistant,
                      latestAssistant.manuallyRecorded != true,
                      latestAssistant.origin?.clientSourceLabel == effectiveOrigin?.clientSourceLabel,
                      latestAssistant.origin != nil, effectiveOrigin != nil else {
                    throw PaperDeskError.conflict("无法为反馈找到同一文献、对话和客户端的上一条回答")
                }
                if let previousDiscussionID {
                    guard previousDiscussionID == latestAssistant.id else {
                        throw PaperDeskError.conflict("反馈只能关联同一对话中最新的上一条回答")
                    }
                }
                readingFeedback = ReadingFeedback(kind: feedbackKind, evidence: feedbackEvidence, answerID: latestAssistant.id)
            } else {
                readingFeedback = nil
            }
            let first = snapshot.state.selections.first(where: { ids.contains($0.id) })
            let user = PaperChatMessage(role: .user, text: question, pageLabel: first?.context.pageLabel, contextID: first?.id,
                                        sourcePageIndex: first?.context.pageIndex, readingSnapshotID: snapshotID, sourceContextIDs: ids,
                                        origin: effectiveOrigin, manuallyRecorded: manuallyRecorded, sharedWithAI: sharedWithAI,
                                        conversationID: resolvedConversationID, conversationTitle: effectiveTitle,
                                        readingFeedback: readingFeedback)
            let assistant = PaperChatMessage(role: .assistant, text: answer, pageLabel: first?.context.pageLabel, contextID: first?.id,
                                             sourcePageIndex: first?.context.pageIndex, readingSnapshotID: snapshotID, sourceContextIDs: ids,
                                             origin: effectiveOrigin, manuallyRecorded: manuallyRecorded, sharedWithAI: sharedWithAI,
                                             conversationID: resolvedConversationID, conversationTitle: effectiveTitle,
                                             citations: normalizedCitations.isEmpty ? nil : normalizedCitations,
                                             referencedWorks: normalizedReferences,
                                             citationWarnings: normalizedCitationWarnings?.isEmpty == false ? normalizedCitationWarnings : nil,
                                             answerMode: answerMode)
            session.messages.append(contentsOf: [user, assistant])
            try saveChatSession(session, paperID: paperID)
            try withStatement("INSERT INTO discussion_requests (idempotency_key,paper_id,payload,response_id) VALUES (?,?,?,?)") { statement in
                bindText(statement, 1, key); bindText(statement, 2, paperID); bindText(statement, 3, payload); bindText(statement, 4, assistant.id); try stepDone(statement)
            }
            return assistant
        }
    }

    /// Changes whether a manually recorded discussion may be returned to an
    /// AI client. The identifier is the assistant answer ID returned by
    /// `appendDiscussion`, so callers do not need to rely on message order.
    /// The adjacent user message is updated as part of the same pair so a
    /// later search can return the complete question-and-answer entry.
    public func setManualDiscussionSharing(paperID: String, discussionID: String, shared: Bool) throws {
        _ = try paper(id: paperID)
        guard !discussionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PaperDeskError.invalid("讨论 ID 不能为空")
        }
        try transaction {
            var session = try chatSession(paperID: paperID)
            guard let answerIndex = session.messages.firstIndex(where: { $0.id == discussionID && $0.role == .assistant }) else {
                throw PaperDeskError.missing("找不到这条讨论")
            }
            guard session.messages[answerIndex].manuallyRecorded == true else {
                throw PaperDeskError.invalid("只有手动记录的讨论可以设置共享权限")
            }
            session.messages[answerIndex].sharedWithAI = shared

            // `appendDiscussion` stores the question immediately before its
            // answer. Restrict the pairing to the same snapshot/context so a
            // malformed historical session cannot accidentally modify an
            // unrelated question.
            if answerIndex > 0,
               session.messages[answerIndex - 1].role == .user,
               session.messages[answerIndex - 1].manuallyRecorded == true,
               session.messages[answerIndex - 1].readingSnapshotID == session.messages[answerIndex].readingSnapshotID,
               session.messages[answerIndex - 1].sourceContextIDs == session.messages[answerIndex].sourceContextIDs {
                session.messages[answerIndex - 1].sharedWithAI = shared
            }
            try saveChatSession(session, paperID: paperID)
        }
    }

    public func insertAnchoredNote(_ note: ReadingNote, contextIDs: [String], idempotencyKey: String) throws -> ReadingNote {
        let paper = try paper(id: note.paperID)
        guard note.pageIndex >= 0, note.pageIndex < paper.pageCount, !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PaperDeskError.invalid("笔记内容或页码无效") }
        guard ["human", "ai"].contains(note.source), ["draft", "accepted"].contains(note.status), note.revision == 1 else { throw PaperDeskError.invalid("笔记字段无效") }
        var ids = contextIDs
        if ids.isEmpty, let contextID = note.contextID { ids = [contextID] }
        ids = uniqueStrings(ids)
        var contexts: [ContextSnapshot] = []
        for id in ids {
            guard let context = try context(id: id), context.paperID == paper.id, context.documentHash == paper.fileHash else { throw PaperDeskError.conflict("笔记引用了不属于当前文献版本的选区") }
            contexts.append(context)
        }
        if let contextID = note.contextID, !ids.contains(contextID) { throw PaperDeskError.conflict("笔记主来源不在引用列表中") }
        let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 256 else { throw PaperDeskError.invalid("笔记缺少有效的幂等标识") }
        let payload = try notePayload(note) + String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        var stored = note
        stored.origin = normalizedOrigin(note.origin)
        stored.updatedAt = Date()
        return try transaction {
            if let existing = try self.note(idempotencyKey: key) {
                guard existing.requestPayload == payload else { throw PaperDeskError.conflict("相同请求标识对应了不同的笔记") }
                return existing.note
            }
            guard try self.note(id: stored.id) == nil else { throw PaperDeskError.conflict("笔记 ID 已存在") }
            try insertNoteRow(stored, idempotencyKey: key, payload: payload)
            for (index, id) in ids.enumerated() {
                try withStatement("INSERT INTO note_contexts (note_id,context_id,context_index) VALUES (?,?,?)") { statement in
                    bindText(statement, 1, stored.id); bindText(statement, 2, id); bindInt(statement, 3, index); try stepDone(statement)
                }
            }
            return stored
        }
    }

    public func noteContextIDs(noteID: String) throws -> [String] {
        guard let note = try note(id: noteID) else { throw PaperDeskError.missing("找不到笔记") }
        return try withStatement("SELECT context_id FROM note_contexts WHERE note_id = ? ORDER BY context_index ASC") { statement in
            bindText(statement, 1, noteID); var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(try requiredText(statement, 0)) }
            try checkLastStep(statement)
            return result.isEmpty ? (note.contextID.map { [$0] } ?? []) : result
        }
    }

    private func validateReadingState(_ state: PaperReadingState, paper: Paper) throws {
        guard state.paperID == paper.id, state.documentHash == paper.fileHash else { throw PaperDeskError.conflict("阅读状态与文献版本不匹配") }
        guard state.pageIndex >= 0, state.pageIndex < paper.pageCount else { throw PaperDeskError.invalid("阅读页码超出文献范围") }
        for region in state.visibleRegions {
            guard region.pageIndex >= 0, region.pageIndex < paper.pageCount, region.width > 0, region.height > 0 else { throw PaperDeskError.invalid("阅读区域无效") }
        }
        var ids = Set<String>()
        for selection in state.selections {
            guard ids.insert(selection.id).inserted, !selection.label.isEmpty,
                  let context = try context(id: selection.id), context == selection.context,
                  context.paperID == paper.id, context.documentHash == paper.fileHash else { throw PaperDeskError.conflict("阅读选区已失效") }
        }
        if let focusedContextID = state.focusedContextID, !ids.contains(focusedContextID) {
            throw PaperDeskError.conflict("当前指向的选区已失效")
        }
    }

    private struct DiscussionRequest { let paperID: String; let payload: String; let responseID: String }
    private func discussionRequest(key: String) throws -> DiscussionRequest? {
        try withStatement("SELECT paper_id,payload,response_id FROM discussion_requests WHERE idempotency_key = ?") { statement in
            bindText(statement, 1, key); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return DiscussionRequest(paperID: try requiredText(statement, 0), payload: try requiredText(statement, 1), responseID: try requiredText(statement, 2))
        }
    }

    public func insertNote(_ note: ReadingNote, idempotencyKey: String? = nil) throws -> ReadingNote {
        let paper = try paper(id: note.paperID)
        guard note.pageIndex >= 0, note.pageIndex < paper.pageCount else { throw PaperDeskError.invalid("笔记页码超出文献范围") }
        guard !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PaperDeskError.invalid("笔记内容不能为空") }
        guard ["human", "ai"].contains(note.source) else { throw PaperDeskError.invalid("笔记来源只能是 human 或 ai") }
        guard ["draft", "accepted"].contains(note.status) else { throw PaperDeskError.invalid("笔记状态只能是 draft 或 accepted") }
        guard note.revision == 1 else { throw PaperDeskError.invalid("新笔记的版本必须为 1") }
        if let contextID = note.contextID {
            guard let context = try context(id: contextID) else { throw PaperDeskError.missing("找不到笔记来源选区") }
            guard context.paperID == note.paperID, context.pageIndex == note.pageIndex, context.documentHash == paper.fileHash else { throw PaperDeskError.conflict("笔记来源与文献版本不匹配") }
        }
        let payload = try notePayload(note)
        if let key = normalizedKey(idempotencyKey), let existing = try self.note(idempotencyKey: key) {
            guard existing.requestPayload == payload else { throw PaperDeskError.conflict("相同请求标识对应了不同的笔记内容") }
            return existing.note
        }
        if try self.note(id: note.id) != nil { throw PaperDeskError.conflict("笔记 ID 已存在") }

        var stored = note
        stored.origin = normalizedOrigin(note.origin)
        stored.updatedAt = Date()
        try transaction {
            try insertNoteRow(stored, idempotencyKey: normalizedKey(idempotencyKey), payload: payload)
        }
        guard let persisted = try self.note(id: stored.id) else { throw PaperDeskError.invalid("保存后的笔记不存在") }
        return persisted
    }

    private func insertNoteRow(_ note: ReadingNote, idempotencyKey: String?, payload: String) throws {
        try withStatement("""
        INSERT INTO notes (id,paper_id,context_id,page_index,page_label,quote,content,source,status,revision,created_at,updated_at,idempotency_key,request_payload,origin_json,kind,discussion_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """) { statement in
            bindText(statement, 1, note.id); bindText(statement, 2, note.paperID); bindOptionalText(statement, 3, note.contextID)
            bindInt(statement, 4, note.pageIndex); bindText(statement, 5, note.pageLabel); bindText(statement, 6, note.quote); bindText(statement, 7, note.content)
            bindText(statement, 8, note.source); bindText(statement, 9, note.status); bindInt(statement, 10, note.revision); bindDate(statement, 11, note.createdAt)
            bindDate(statement, 12, note.updatedAt); bindOptionalText(statement, 13, idempotencyKey); bindText(statement, 14, payload)
            bindOptionalText(statement, 15, try encodeOrigin(note.origin)); bindOptionalText(statement, 16, note.kind); bindOptionalText(statement, 17, note.discussionID)
            try stepDone(statement)
        }
    }

    /// Persists a model-selected extractive summary as source-only material.
    ///
    /// The note body is assembled here from the already verified PDF strings.
    /// The model never supplies prose to this method. The source rows are kept
    /// separately so the reader can show and navigate to every cited passage.
    public func recordExtractiveSummary(paperID: String, documentHash: String, sources: [ExtractiveSource],
                                        coverage: ExtractiveCoverage? = nil,
                                        origin: RecordOrigin? = nil,
                                        status: String = "accepted") throws -> ReadingNote {
        let paper = try paper(id: paperID)
        guard paper.fileHash == documentHash else { throw PaperDeskError.conflict("摘录对应的 PDF 版本不是当前文献版本") }
        guard !sources.isEmpty else { throw PaperDeskError.invalid("没有可保存的原文摘录") }
        guard status == "draft" || status == "accepted" else {
            throw PaperDeskError.invalid("原文摘录状态无效")
        }

        var seenIDs = Set<String>()
        for source in sources {
            guard !source.id.isEmpty, seenIDs.insert(source.id).inserted else {
                throw PaperDeskError.invalid("原文摘录的来源标识重复或为空")
            }
            guard source.pageIndex >= 0, source.pageIndex < paper.pageCount else {
                throw PaperDeskError.invalid("原文摘录页码超出文献范围")
            }
            guard !source.pageLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PaperDeskError.invalid("原文摘录缺少页码")
            }
            guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !source.text.contains("\0") else {
                throw PaperDeskError.invalid("原文摘录含有无法完整保存的字符")
            }
        }

        let content = extractiveContent(sources)
        let first = sources[0]
        let note = ReadingNote(
            paperID: paperID,
            pageIndex: first.pageIndex,
            pageLabel: first.pageLabel,
            quote: "",
            content: content,
            source: "ai",
            status: status,
            origin: normalizedOrigin(origin),
            kind: "excerpt"
        )

        // A stable request key makes clicking the action twice idempotent for
        // the same verified source list while allowing a changed list to be
        // recorded as a new reading entry.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let sourcePayload = try encoder.encode(sources)
        let coveragePayload = try coverage.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let digest = SHA256.hash(data: sourcePayload).map { String(format: "%02x", $0) }.joined()
        let idempotencyKey = "extractive:\(paperID):\(documentHash):\(digest)"
        let payload = try notePayload(note)
        var stored = note
        stored.updatedAt = Date()

        return try transaction {
            if let existing = try self.note(idempotencyKey: idempotencyKey) {
                // The deterministic key is computed from the verified source
                // payload. A later user review may deliberately reorder or
                // remove source rows, so a retry of the original request must
                // return that authoritative edited record rather than treating
                // the review as an idempotency conflict.
                if let coveragePayload { try storeExtractiveCoverage(coveragePayload, noteID: existing.note.id) }
                guard let current = try self.note(id: existing.note.id) else {
                    throw PaperDeskError.missing("原文摘录记录不存在")
                }
                return current
            }
            try insertNoteRow(stored, idempotencyKey: idempotencyKey, payload: payload)
            try withStatement("INSERT INTO extractive_summary_sources (note_id,source_index,source_id,page_index,page_label,text) VALUES (?,?,?,?,?,?)") { statement in
                for (index, source) in sources.enumerated() {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindText(statement, 1, stored.id)
                    bindInt(statement, 2, index)
                    bindText(statement, 3, source.id)
                    bindInt(statement, 4, source.pageIndex)
                    bindText(statement, 5, source.pageLabel)
                    bindText(statement, 6, source.text)
                    try stepDone(statement)
                }
            }
            if let coveragePayload { try storeExtractiveCoverage(coveragePayload, noteID: stored.id) }
            return stored
        }
    }

    /// Updates an unapproved extractive summary using only source IDs that are
    /// already attached to that summary. The source rows are rewritten in the
    /// caller's order and the note body is rebuilt from their stored PDF text;
    /// no caller-provided prose can enter an extractive record.
    public func updateExtractiveDraft(noteID: String, orderedSourceIDs: [String], status: String,
                                      expectedRevision: Int) throws -> ReadingNote {
        guard status == "draft" || status == "accepted" else {
            throw PaperDeskError.invalid("原文摘录状态无效")
        }
        guard let current = try note(id: noteID) else { throw PaperDeskError.missing("找不到原文摘录") }
        guard try hasExtractiveSummary(noteID: noteID) else { throw PaperDeskError.invalid("这条笔记不是原文摘录") }
        guard current.status == "draft" else {
            throw PaperDeskError.invalid("已确认的原文摘录不能修改")
        }
        guard current.revision == expectedRevision else { throw PaperDeskError.conflict("原文摘录已被修改，请重新读取后再保存") }

        let originalSources = try extractiveSummary(noteID: noteID)
        guard !orderedSourceIDs.isEmpty else { throw PaperDeskError.invalid("原文摘录至少需要保留一句原文") }
        guard Set(orderedSourceIDs).count == orderedSourceIDs.count else {
            throw PaperDeskError.invalid("原文摘录来源不能重复")
        }
        let byID = Dictionary(uniqueKeysWithValues: originalSources.map { ($0.id, $0) })
        guard orderedSourceIDs.allSatisfy({ byID[$0] != nil }) else {
            throw PaperDeskError.conflict("原文摘录只能使用已核验的来源编号")
        }
        let orderedSources = orderedSourceIDs.compactMap { byID[$0] }
        let content = extractiveContent(orderedSources)
        let firstSource = orderedSources[0]
        let updatedAt = Date()

        try transaction {
            try withStatement("UPDATE notes SET page_index = ?, page_label = ?, content = ?, status = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?") { statement in
                bindInt(statement, 1, firstSource.pageIndex)
                bindText(statement, 2, firstSource.pageLabel)
                bindText(statement, 3, content)
                bindText(statement, 4, status)
                bindDate(statement, 5, updatedAt)
                bindText(statement, 6, noteID)
                bindInt(statement, 7, expectedRevision)
                try stepDone(statement)
                guard sqlite3_changes(database) == 1 else {
                    throw PaperDeskError.conflict("原文摘录已被修改，请重新读取后再保存")
                }
            }
            // Rewriting in a delete/insert pair avoids transient UNIQUE
            // conflicts when two existing source rows exchange positions.
            try withStatement("DELETE FROM extractive_summary_sources WHERE note_id = ?") { statement in
                bindText(statement, 1, noteID)
                try stepDone(statement)
            }
            try withStatement("INSERT INTO extractive_summary_sources (note_id,source_index,source_id,page_index,page_label,text) VALUES (?,?,?,?,?,?)") { statement in
                for (index, source) in orderedSources.enumerated() {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bindText(statement, 1, noteID)
                    bindInt(statement, 2, index)
                    bindText(statement, 3, source.id)
                    bindInt(statement, 4, source.pageIndex)
                    bindText(statement, 5, source.pageLabel)
                    bindText(statement, 6, source.text)
                    try stepDone(statement)
                }
            }
        }
        guard let updated = try note(id: noteID) else { throw PaperDeskError.missing("保存后的原文摘录不存在") }
        return updated
    }

    private func storeExtractiveCoverage(_ coverage: String, noteID: String) throws {
        try withStatement("INSERT OR IGNORE INTO extractive_summary_coverage (note_id, coverage_json) VALUES (?,?)") { statement in
            bindText(statement, 1, noteID); bindText(statement, 2, coverage); try stepDone(statement)
        }
    }

    public func extractiveCoverage(noteID: String) throws -> ExtractiveCoverage? {
        try withStatement("SELECT coverage_json FROM extractive_summary_coverage WHERE note_id = ?") { statement in
            bindText(statement, 1, noteID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try JSONDecoder().decode(ExtractiveCoverage.self, from: Data(requiredText(statement, 0).utf8))
        }
    }

    /// Returns the exact source strings attached to an extractive summary.
    public func extractiveSummary(noteID: String) throws -> [ExtractiveSource] {
        return try withStatement("SELECT source_id,page_index,page_label,text FROM extractive_summary_sources WHERE note_id = ? ORDER BY source_index ASC") { statement in
            bindText(statement, 1, noteID)
            var result: [ExtractiveSource] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(ExtractiveSource(
                    id: try requiredText(statement, 0),
                    pageIndex: Int(sqlite3_column_int(statement, 1)),
                    pageLabel: try requiredText(statement, 2),
                    text: try requiredText(statement, 3)
                ))
            }
            try checkLastStep(statement)
            return result
        }
    }

    /// Rehydrates source-only summary messages for the embedded chat view.
    public func extractiveSummaryMessages(paperID: String) throws -> [PaperChatMessage] {
        try withStatement("""
        SELECT id,content,page_label,page_index,created_at,origin_json FROM notes
        WHERE paper_id = ? AND EXISTS (SELECT 1 FROM extractive_summary_sources WHERE note_id = notes.id)
        ORDER BY created_at ASC
        """) { statement in
            bindText(statement, 1, paperID)
            var result: [PaperChatMessage] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = try requiredText(statement, 0)
                result.append(PaperChatMessage(
                    id: id,
                    role: .assistant,
                    text: try requiredText(statement, 1),
                    pageLabel: try requiredText(statement, 2),
                    sourcePageIndex: Int(sqlite3_column_int(statement, 3)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    summarySources: try extractiveSummary(noteID: id),
                    summaryNoteID: id,
                    origin: try decodeOrigin(optionalText(statement, 5)),
                    manuallyRecorded: false,
                    sharedWithAI: false
                ))
            }
            try checkLastStep(statement)
            return result
        }
    }

    public func notes(paperID: String) throws -> [ReadingNote] {
        _ = try paper(id: paperID)
        return try withStatement("SELECT id,paper_id,context_id,page_index,page_label,quote,content,source,status,revision,created_at,updated_at,origin_json,kind,discussion_id FROM notes WHERE paper_id = ? ORDER BY page_index ASC, created_at ASC") { statement in
            bindText(statement, 1, paperID)
            var result: [ReadingNote] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(try makeNote(statement)) }
            try checkLastStep(statement)
            return result
        }
    }

    public func updateNote(id: String, content: String, status: String, expectedRevision: Int,
                           kind: String? = nil) throws -> ReadingNote {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PaperDeskError.invalid("笔记内容不能为空") }
        guard ["draft", "accepted"].contains(status) else { throw PaperDeskError.invalid("笔记状态只能是 draft 或 accepted") }
        guard let current = try note(id: id) else { throw PaperDeskError.missing("找不到笔记") }
        if try hasExtractiveSummary(noteID: id) {
            throw PaperDeskError.invalid("原文摘录只能删除，不能改写")
        }
        guard current.revision == expectedRevision else { throw PaperDeskError.conflict("笔记已被修改，请重新读取后再保存") }
        let updatedAt = Date()
        try transaction {
            try withStatement("UPDATE notes SET content = ?, status = ?, kind = COALESCE(?, kind), revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?") { statement in
                bindText(statement, 1, content)
                bindText(statement, 2, status)
                bindOptionalText(statement, 3, kind)
                bindDate(statement, 4, updatedAt)
                bindText(statement, 5, id)
                bindInt(statement, 6, expectedRevision)
                try stepDone(statement)
                guard sqlite3_changes(database) == 1 else {
                    throw PaperDeskError.conflict("笔记已被修改，请重新读取后再保存")
                }
            }
        }
        guard let updated = try note(id: id) else { throw PaperDeskError.missing("保存后的笔记不存在") }
        return updated
    }

    public func deleteNote(id: String) throws {
        guard try note(id: id) != nil else { throw PaperDeskError.missing("找不到笔记") }
        try transaction {
            try withStatement("DELETE FROM notes WHERE id = ?") { statement in bindText(statement, 1, id); try stepDone(statement) }
        }
    }

    public func search(query: String) throws -> [Paper] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try papers() }
        let pattern = "%\(escapeLike(trimmed))%"
        return try withStatement("""
        SELECT DISTINCT p.id,p.title,p.file_name,p.file_hash,p.page_count,p.last_page_index,p.tags_json,p.reading_state,p.bibtex,p.added_at,p.updated_at,p.project_name
        FROM papers p LEFT JOIN notes n ON n.paper_id = p.id
        WHERE p.title LIKE ? ESCAPE '\\' COLLATE NOCASE
           OR p.file_name LIKE ? ESCAPE '\\' COLLATE NOCASE
           OR p.tags_json LIKE ? ESCAPE '\\' COLLATE NOCASE
           OR n.content LIKE ? ESCAPE '\\' COLLATE NOCASE
           OR n.quote LIKE ? ESCAPE '\\' COLLATE NOCASE
        ORDER BY p.updated_at DESC, p.title COLLATE NOCASE ASC
        """) { statement in
            for index in 1...5 { bindText(statement, Int32(index), pattern) }
            var result: [Paper] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(try makePaper(statement)) }
            try checkLastStep(statement)
            return result
        }
    }

    // MARK: - Per-paper chat

    public func chatSession(paperID: String) throws -> PaperChatSession {
        try withStatement("SELECT session_json FROM paper_chats WHERE paper_id = ?") { statement in
            bindText(statement, 1, paperID)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let json = try requiredText(statement, 0)
                return try JSONDecoder().decode(PaperChatSession.self, from: Data(json.utf8))
            case SQLITE_DONE:
                return PaperChatSession()
            default:
                throw PaperDeskError.invalid("无法读取文献对话。")
            }
        }
    }

    public func saveChatSession(_ session: PaperChatSession, paperID: String) throws {
        let data = try JSONEncoder().encode(session)
        let json = String(decoding: data, as: UTF8.self)
        try withStatement("""
        INSERT INTO paper_chats (paper_id, session_json) VALUES (?, ?)
        ON CONFLICT(paper_id) DO UPDATE SET session_json = excluded.session_json
        """) { statement in
            bindText(statement, 1, paperID)
            bindText(statement, 2, json)
            try stepDone(statement)
        }
    }

    /// Returns the external-client conversations bound to this paper. The
    /// binding table is separate from the chat transcript so changing a
    /// transcript never silently changes the native conversation it belongs
    /// to.
    public func questionBindings(paperID: String) throws -> [QuestionBinding] {
        let normalizedPaperID = paperID.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try paper(id: normalizedPaperID)
        return try withStatement("""
        SELECT paper_id,conversation_id,backend,project_path,external_session_id
        FROM question_bindings
        WHERE paper_id = ?
        ORDER BY updated_at DESC, conversation_id COLLATE NOCASE ASC
        """) { statement in
            bindText(statement, 1, normalizedPaperID)
            var result: [QuestionBinding] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let backendRaw = try requiredText(statement, 2)
                guard !backendRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PaperDeskError.invalid("资料库中的对话客户端类型为空")
                }
                result.append(QuestionBinding(
                    paperID: try requiredText(statement, 0),
                    conversationID: try requiredText(statement, 1),
                    backend: backendRaw,
                    projectPath: try requiredText(statement, 3),
                    externalSessionID: try requiredText(statement, 4)
                ))
            }
            try checkLastStep(statement)
            return result
        }
    }

    /// Looks up the paper conversation that owns one native session. Session
    /// identifiers are scoped to their backend and are globally unique across
    /// papers and project paths, so this read is enough to reject an unsafe
    /// pasted-session reuse before launching a question.
    public func questionBinding(backend: String, externalSessionID: String) throws -> QuestionBinding? {
        let normalizedSessionID = externalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { throw PaperDeskError.invalid("外部会话标识不能为空") }
        return try withStatement("""
        SELECT paper_id,conversation_id,backend,project_path,external_session_id
        FROM question_bindings
        WHERE backend = ? AND external_session_id = ?
        LIMIT 1
        """) { statement in
            bindText(statement, 1, backend)
            bindText(statement, 2, normalizedSessionID)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                try checkLastStep(statement)
                return nil
            }
            let backendRaw = try requiredText(statement, 2)
            guard !backendRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PaperDeskError.invalid("资料库中的对话客户端类型为空")
            }
            return QuestionBinding(
                paperID: try requiredText(statement, 0),
                conversationID: try requiredText(statement, 1),
                backend: backendRaw,
                projectPath: try requiredText(statement, 3),
                externalSessionID: try requiredText(statement, 4)
            )
        }
    }

    /// Stores one durable association between a PaperDesk conversation and a
    /// native external-client session. Replaying the exact same binding is
    /// safe. A binding already used by another client/project/session, or a
    /// native session already used by another paper, is never overwritten.
    public func saveQuestionBinding(_ binding: QuestionBinding) throws {
        let paperID = binding.paperID.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationID = binding.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectPath = binding.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let externalSessionID = binding.externalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paperID.isEmpty else { throw PaperDeskError.invalid("文献 ID 不能为空") }
        guard !conversationID.isEmpty else { throw PaperDeskError.invalid("对话标识不能为空") }
        guard !projectPath.isEmpty else { throw PaperDeskError.invalid("项目路径不能为空") }
        guard !externalSessionID.isEmpty else { throw PaperDeskError.invalid("外部会话标识不能为空") }
        _ = try paper(id: paperID)

        let normalized = QuestionBinding(paperID: paperID, conversationID: conversationID,
                                         backend: binding.backend, projectPath: projectPath,
                                         externalSessionID: externalSessionID)
        let now = Date()
        try transaction {
            let existing: QuestionBinding? = try withStatement("""
            SELECT paper_id,conversation_id,backend,project_path,external_session_id
            FROM question_bindings
            WHERE paper_id = ? AND conversation_id = ?
            """) { statement in
                bindText(statement, 1, normalized.paperID)
                bindText(statement, 2, normalized.conversationID)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    try checkLastStep(statement)
                    return nil
                }
                let backendRaw = try requiredText(statement, 2)
                guard !backendRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PaperDeskError.invalid("资料库中的对话客户端类型为空")
                }
                return QuestionBinding(
                    paperID: try requiredText(statement, 0),
                    conversationID: try requiredText(statement, 1),
                    backend: backendRaw,
                    projectPath: try requiredText(statement, 3),
                    externalSessionID: try requiredText(statement, 4)
                )
            }
            if let existing {
                guard existing == normalized else {
                    throw PaperDeskError.conflict("这条 PaperDesk 对话已经绑定了另一个外部会话，不能覆盖")
                }
                // Keep the original association intact while recording that
                // the caller successfully re-confirmed it.
                try withStatement("UPDATE question_bindings SET updated_at = ? WHERE paper_id = ? AND conversation_id = ?") { statement in
                    bindDate(statement, 1, now)
                    bindText(statement, 2, normalized.paperID)
                    bindText(statement, 3, normalized.conversationID)
                    try stepDone(statement)
                }
                return
            }

            // A native session is intentionally unique across papers and
            // project paths. This prevents a stale or copied project from
            // exposing one paper's transcript and reading state through
            // another paper binding.
            let occupied: (paperID: String, conversationID: String)? = try withStatement("""
            SELECT paper_id,conversation_id
            FROM question_bindings
            WHERE backend = ? AND external_session_id = ?
            LIMIT 1
            """) { statement in
                bindText(statement, 1, normalized.backend)
                bindText(statement, 2, normalized.externalSessionID)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    try checkLastStep(statement)
                    return nil
                }
                return (paperID: try requiredText(statement, 0), conversationID: try requiredText(statement, 1))
            }
            if occupied != nil {
                throw PaperDeskError.conflict("这个外部会话已经绑定到另一篇文献或项目，不能重复使用")
            }

            try withStatement("""
            INSERT INTO question_bindings
                (paper_id,conversation_id,backend,project_path,external_session_id,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?)
            """) { statement in
                bindText(statement, 1, normalized.paperID)
                bindText(statement, 2, normalized.conversationID)
                bindText(statement, 3, normalized.backend)
                bindText(statement, 4, normalized.projectPath)
                bindText(statement, 5, normalized.externalSessionID)
                bindDate(statement, 6, now)
                bindDate(statement, 7, now)
                try stepDone(statement)
            }
        }
    }

    /// Mirrors the title owned by the bound Codex or OpenCode conversation.
    /// The binding is checked before updating so a stale lookup can never
    /// rename a different PaperDesk conversation.
    @discardableResult
    public func synchronizeExternalConversationTitle(binding: QuestionBinding, title: String) throws -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return false }
        _ = try paper(id: binding.paperID)
        guard try questionBinding(backend: binding.backend, externalSessionID: binding.externalSessionID) == binding else {
            throw PaperDeskError.conflict("外部会话绑定已变化，未更新对话标题。")
        }

        return try transaction {
            var session = try chatSession(paperID: binding.paperID)
            var changed = false
            for index in session.messages.indices
            where session.messages[index].conversationID == binding.conversationID && session.messages[index].manuallyRecorded != true {
                if session.messages[index].conversationTitle != normalizedTitle {
                    session.messages[index].conversationTitle = normalizedTitle
                    changed = true
                }
            }
            guard changed else { return false }
            try saveChatSession(session, paperID: binding.paperID)
            return true
        }
    }

    /// Attaches legacy messages that predate conversation tracking to the
    /// explicit conversation ID used for their follow-up turns.
    public func assignLegacyConversationID(paperID: String, messageIDs: [String], conversationID: String) throws {
        _ = try paper(id: paperID)
        let targetID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetID.isEmpty else { throw PaperDeskError.invalid("对话标识不能为空") }
        let wanted = Set(messageIDs)
        guard !wanted.isEmpty else { return }
        try transaction {
            var session = try chatSession(paperID: paperID)
            var changed = false
            for index in session.messages.indices where wanted.contains(session.messages[index].id) {
                guard session.messages[index].conversationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { continue }
                session.messages[index].conversationID = targetID
                changed = true
            }
            guard changed else { return }
            try saveChatSession(session, paperID: paperID)
        }
    }

    // MARK: - Export and backup

    public func exportMarkdown(paperID: String) throws -> String {
        let paper = try paper(id: paperID)
        let paperNotes = try notes(paperID: paperID)
        var output = "# \(paper.title)\n\n"
        output += "- File: \(paper.fileName)\n- Pages: \(paper.pageCount)\n- Status: \(paper.readingState)\n"
        if !paper.tags.isEmpty { output += "- Tags: \(paper.tags.joined(separator: ", "))\n" }
        if !paper.bibtex.isEmpty { output += "\n```bibtex\n\(paper.bibtex)\n```\n" }
        for note in paperNotes {
            output += "\n## Page \(note.pageLabel.isEmpty ? String(note.pageIndex + 1) : note.pageLabel)\n\n"
            if !note.quote.isEmpty { output += "> \(note.quote.replacingOccurrences(of: "\n", with: "\n> "))\n\n" }
            output += note.content + "\n"
            var metadata = "_Source: \(note.source), status: \(note.status), note ID: \(note.id)"
            if let kind = note.kind, !kind.isEmpty { metadata += ", kind: \(kind)" }
            if let origin = note.origin {
                let name = origin.clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let version = origin.clientVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label: String
                switch (name?.isEmpty == false ? name : nil, version?.isEmpty == false ? version : nil) {
                case let (name?, version?): label = "\(name) \(version)"
                case let (name?, nil): label = name
                case let (nil, version?): label = version
                default: label = "unknown client"
                }
                metadata += ", origin: \(label)"
            }
            if let discussionID = note.discussionID, !discussionID.isEmpty { metadata += ", discussion: \(discussionID)" }
            output += "\n\(metadata)_\n"
        }
        return output
    }

    public func backup(to destination: URL) throws {
        let target = destination.standardizedFileURL
        let sourcePath = rootURL.path
        let targetPath = target.path
        guard targetPath != sourcePath,
              !targetPath.hasPrefix(sourcePath + "/"),
              !sourcePath.hasPrefix(targetPath + "/") else {
            throw PaperDeskError.invalid("备份目录不能包含资料库，也不能位于资料库内部")
        }
        if fileManager.fileExists(atPath: target.path) {
            let targetValues = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard targetValues.isSymbolicLink != true else { throw PaperDeskError.invalid("备份目标不能是符号链接") }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw PaperDeskError.invalid("备份目标必须是目录") }
            guard (try fileManager.contentsOfDirectory(atPath: target.path)).isEmpty else { throw PaperDeskError.invalid("备份目标必须为空目录") }
        }
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".paperdesk-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        try setPrivateDirectory(stage)
        var succeeded = false
        var parkedTarget: URL?
        defer {
            if !succeeded {
                try? fileManager.removeItem(at: stage)
                if let parkedTarget, !fileManager.fileExists(atPath: target.path) {
                    try? fileManager.moveItem(at: parkedTarget, to: target)
                }
            } else if let parkedTarget {
                try? fileManager.removeItem(at: parkedTarget)
            }
        }
        do {
            try copyDatabase(to: stage.appendingPathComponent("library.sqlite"))
            try copyDirectory(pdfsURL, to: stage.appendingPathComponent("pdfs", isDirectory: true))
            try copyDirectory(contextsURL, to: stage.appendingPathComponent("contexts", isDirectory: true))
            if fileManager.fileExists(atPath: target.path) {
                // The caller supplied an empty directory. Park it briefly so the
                // completed staging tree can be installed with one directory move;
                // this avoids leaving a plausible-looking partial backup on error.
                let parked = parent.appendingPathComponent(".paperdesk-empty-\(UUID().uuidString)", isDirectory: true)
                try fileManager.moveItem(at: target, to: parked)
                parkedTarget = parked
                try fileManager.moveItem(at: stage, to: target)
            } else {
                try fileManager.moveItem(at: stage, to: target)
            }
            succeeded = true
        } catch {
            throw PaperDeskError.invalid("备份失败：\(error.localizedDescription)")
        }
    }

    // MARK: - SQLite setup

    private func migrate() throws {
        try execute("CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("""
        CREATE TABLE IF NOT EXISTS papers (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            file_name TEXT NOT NULL,
            file_hash TEXT NOT NULL UNIQUE,
            page_count INTEGER NOT NULL CHECK(page_count > 0),
            last_page_index INTEGER NOT NULL DEFAULT 0 CHECK(last_page_index >= 0),
            tags_json TEXT NOT NULL DEFAULT '[]',
            reading_state TEXT NOT NULL DEFAULT 'unread',
            bibtex TEXT NOT NULL DEFAULT '',
            added_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            project_name TEXT NOT NULL DEFAULT ''
        )
        """)
        try addColumnIfMissing("papers", name: "project_name", declaration: "TEXT NOT NULL DEFAULT ''")
        try execute("""
        CREATE TABLE IF NOT EXISTS paper_project_contacts (
            paper_id TEXT PRIMARY KEY NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            document_hash TEXT NOT NULL,
            last_contact REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS contexts (
            id TEXT PRIMARY KEY NOT NULL,
            paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            document_hash TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            page_label TEXT NOT NULL,
            text TEXT NOT NULL,
            regions_json TEXT NOT NULL,
            image_relative_path TEXT,
            created_at REAL NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY NOT NULL,
            paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            context_id TEXT REFERENCES contexts(id) ON DELETE SET NULL,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            page_label TEXT NOT NULL,
            quote TEXT NOT NULL,
            content TEXT NOT NULL,
            source TEXT NOT NULL,
            status TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision > 0),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            idempotency_key TEXT UNIQUE,
            request_payload TEXT NOT NULL,
            origin_json TEXT,
            kind TEXT,
            discussion_id TEXT
        )
        """)
        // Existing libraries were created before provenance and note-kind
        // tracking existed. SQLite has no portable `ADD COLUMN IF NOT EXISTS`,
        // so inspect the table first and add only the missing columns.
        try addColumnIfMissing("notes", name: "origin_json", declaration: "TEXT")
        try addColumnIfMissing("notes", name: "kind", declaration: "TEXT")
        try addColumnIfMissing("notes", name: "discussion_id", declaration: "TEXT")
        try execute("CREATE INDEX IF NOT EXISTS notes_paper_index ON notes(paper_id, page_index, created_at)")
        try execute("CREATE INDEX IF NOT EXISTS contexts_paper_index ON contexts(paper_id, page_index)")
        try execute("""
        CREATE TABLE IF NOT EXISTS reading_states (
            paper_id TEXT PRIMARY KEY NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            document_hash TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            visible_regions_json TEXT NOT NULL,
            selections_json TEXT NOT NULL,
            next_label INTEGER NOT NULL CHECK(next_label >= 0),
            updated_at REAL NOT NULL,
            focused_context_id TEXT
        )
        """)
        try addColumnIfMissing("reading_states", name: "focused_context_id", declaration: "TEXT")
        try execute("""
        CREATE TABLE IF NOT EXISTS reading_snapshots (
            id TEXT PRIMARY KEY NOT NULL,
            paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            document_hash TEXT NOT NULL,
            state_json TEXT NOT NULL,
            reading_goal TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS reading_snapshots_paper_index ON reading_snapshots(paper_id, created_at)")
        try execute("""
        CREATE TABLE IF NOT EXISTS note_contexts (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            context_id TEXT NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
            context_index INTEGER NOT NULL CHECK(context_index >= 0),
            PRIMARY KEY(note_id, context_id),
            UNIQUE(note_id, context_index)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS note_contexts_note_index ON note_contexts(note_id, context_index)")
        try execute("""
        CREATE TABLE IF NOT EXISTS discussion_requests (
            idempotency_key TEXT PRIMARY KEY NOT NULL,
            paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            payload TEXT NOT NULL,
            response_id TEXT NOT NULL
        )
        """)
        // Per-answer citation footnotes. Numbers restart with every frozen
        // snapshot so one answer always cites 1…n.
        try execute("""
        CREATE TABLE IF NOT EXISTS snapshot_citations (
            snapshot_id TEXT NOT NULL REFERENCES reading_snapshots(id) ON DELETE CASCADE,
            context_id TEXT NOT NULL REFERENCES contexts(id) ON DELETE CASCADE,
            number INTEGER NOT NULL CHECK(number > 0),
            created_at REAL NOT NULL,
            PRIMARY KEY(snapshot_id, context_id),
            UNIQUE(snapshot_id, number)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS extractive_summary_sources (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            source_index INTEGER NOT NULL CHECK(source_index >= 0),
            source_id TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            page_label TEXT NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY(note_id, source_index),
            UNIQUE(note_id, source_id)
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS paper_references (
            id TEXT PRIMARY KEY NOT NULL,
            paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            entry_index INTEGER NOT NULL CHECK(entry_index >= 0),
            authors TEXT,
            first_author TEXT,
            title TEXT,
            year INTEGER,
            venue TEXT,
            doi TEXT,
            arxiv_id TEXT,
            url TEXT,
            bibtex TEXT,
            raw_text TEXT NOT NULL,
            status TEXT NOT NULL,
            source TEXT NOT NULL,
            page_index INTEGER NOT NULL CHECK(page_index >= 0),
            page_label TEXT NOT NULL,
            parser_version INTEGER NOT NULL,
            fingerprint TEXT,
            verified_at REAL,
            verified_by TEXT,
            evidence_url TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS paper_references_paper_index ON paper_references(paper_id, entry_index)")
        try execute("CREATE INDEX IF NOT EXISTS paper_references_label_index ON paper_references(paper_id, label COLLATE NOCASE)")
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS paper_references_fingerprint_unique ON paper_references(paper_id, fingerprint) WHERE fingerprint IS NOT NULL")
        try execute("""
        CREATE TABLE IF NOT EXISTS paper_reference_index (
            paper_id TEXT PRIMARY KEY NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            state TEXT NOT NULL,
            parser_version INTEGER NOT NULL,
            heading_page_index INTEGER,
            entry_count INTEGER NOT NULL DEFAULT 0,
            indexed_at REAL,
            error TEXT
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS paper_chats (
            paper_id TEXT PRIMARY KEY NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            session_json TEXT NOT NULL
        )
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS extractive_summary_coverage (
            note_id TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            coverage_json TEXT NOT NULL
        )
        """)
        // A binding is deliberately kept outside paper_chats: the transcript
        // can be edited or imported without changing which native external
        // conversation owns future questions. The native session key is
        // unique across papers to avoid accidentally sharing one session's
        // context with another document.
        try execute("""
        CREATE TABLE IF NOT EXISTS question_bindings (
            paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
            conversation_id TEXT NOT NULL,
            backend TEXT NOT NULL CHECK(backend IN ('codex','opencode')),
            project_path TEXT NOT NULL,
            external_session_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(paper_id, conversation_id),
            UNIQUE(backend, external_session_id)
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS question_bindings_paper_index ON question_bindings(paper_id, updated_at DESC, conversation_id COLLATE NOCASE)")
        // Keep the privacy boundary explicit even if a database was created
        // by an intermediate build whose table declaration used a weaker
        // project-scoped uniqueness rule.
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS question_bindings_backend_session_unique ON question_bindings(backend, external_session_id)")
        try execute("PRAGMA user_version = 10")
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw PaperDeskError.invalid("资料库未连接") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw PaperDeskError.invalid("资料库操作失败：\(message)")
        }
    }

    private func addColumnIfMissing(_ table: String, name: String, declaration: String) throws {
        let exists = try withStatement("PRAGMA table_info(\(table))") { statement in
            var found = false
            while sqlite3_step(statement) == SQLITE_ROW {
                if optionalText(statement, 1) == name { found = true; break }
            }
            return found
        }
        guard !exists else { return }
        // Table and column names are fixed call-site constants, not user data.
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(declaration)")
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw PaperDeskError.invalid("资料库未连接") }
        var statement: OpaquePointer?
        let preparation = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard preparation == SQLITE_OK, let statement else { throw PaperDeskError.invalid("资料库语句无法准备：\(String(cString: sqlite3_errmsg(database)))") }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "资料库写入失败"
            throw PaperDeskError.invalid("资料库写入失败：\(message)")
        }
    }

    private func checkLastStep(_ statement: OpaquePointer) throws {
        let result = sqlite3_errcode(database)
        guard result == SQLITE_OK || result == SQLITE_DONE || result == SQLITE_ROW else {
            throw PaperDeskError.invalid("资料库读取失败：\(database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误")")
        }
    }

    // MARK: - Row mapping and queries

    private func paper(withID id: String) throws -> Paper? {
        try withStatement("SELECT id,title,file_name,file_hash,page_count,last_page_index,tags_json,reading_state,bibtex,added_at,updated_at,project_name FROM papers WHERE id = ?") { statement in
            bindText(statement, 1, id); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }; return try makePaper(statement)
        }
    }

    private func paper(withFileHash hash: String) throws -> Paper? {
        try withStatement("SELECT id,title,file_name,file_hash,page_count,last_page_index,tags_json,reading_state,bibtex,added_at,updated_at,project_name FROM papers WHERE file_hash = ?") { statement in
            bindText(statement, 1, hash); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }; return try makePaper(statement)
        }
    }

    private func makePaper(_ statement: OpaquePointer) throws -> Paper {
        let rawProjectName = optionalText(statement, 11)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Paper(id: try requiredText(statement, 0), title: try requiredText(statement, 1), fileName: try requiredText(statement, 2), fileHash: try requiredText(statement, 3), pageCount: Int(sqlite3_column_int(statement, 4)), lastPageIndex: Int(sqlite3_column_int(statement, 5)), tags: try decodeTags(requiredText(statement, 6)), readingState: try requiredText(statement, 7), bibtex: try requiredText(statement, 8), projectName: rawProjectName.isEmpty ? nil : rawProjectName, addedAt: date(sqlite3_column_double(statement, 9)), updatedAt: date(sqlite3_column_double(statement, 10)))
    }

    private func makeContext(_ statement: OpaquePointer) throws -> ContextSnapshot {
        ContextSnapshot(id: try requiredText(statement, 0), paperID: try requiredText(statement, 1), documentHash: try requiredText(statement, 2), pageIndex: Int(sqlite3_column_int(statement, 3)), pageLabel: try requiredText(statement, 4), text: try requiredText(statement, 5), regions: try decodeRegions(requiredText(statement, 6)), imageRelativePath: optionalText(statement, 7), createdAt: date(sqlite3_column_double(statement, 8)))
    }

    private func makeNote(_ statement: OpaquePointer) throws -> ReadingNote {
        ReadingNote(id: try requiredText(statement, 0), paperID: try requiredText(statement, 1), contextID: optionalText(statement, 2), pageIndex: Int(sqlite3_column_int(statement, 3)), pageLabel: try requiredText(statement, 4), quote: try requiredText(statement, 5), content: try requiredText(statement, 6), source: try requiredText(statement, 7), status: try requiredText(statement, 8), revision: Int(sqlite3_column_int(statement, 9)), createdAt: date(sqlite3_column_double(statement, 10)), updatedAt: date(sqlite3_column_double(statement, 11)), origin: try decodeOrigin(optionalText(statement, 12)), kind: optionalText(statement, 13), discussionID: optionalText(statement, 14))
    }

    private struct StoredNote { let note: ReadingNote; let requestPayload: String }
    private func hasExtractiveSummary(noteID: String) throws -> Bool {
        try withStatement("SELECT 1 FROM extractive_summary_sources WHERE note_id = ? LIMIT 1") { statement in
            bindText(statement, 1, noteID)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func note(id: String) throws -> ReadingNote? {
        try withStatement("SELECT id,paper_id,context_id,page_index,page_label,quote,content,source,status,revision,created_at,updated_at,origin_json,kind,discussion_id FROM notes WHERE id = ?") { statement in
            bindText(statement, 1, id); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }; return try makeNote(statement)
        }
    }
    private func note(idempotencyKey: String) throws -> StoredNote? {
        try withStatement("SELECT id,paper_id,context_id,page_index,page_label,quote,content,source,status,revision,created_at,updated_at,origin_json,kind,discussion_id,request_payload FROM notes WHERE idempotency_key = ?") { statement in
            bindText(statement, 1, idempotencyKey); guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return StoredNote(note: try makeNote(statement), requestPayload: try requiredText(statement, 15))
        }
    }

    // MARK: - Files and serialization

    private func isPDF(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return try handle.read(upToCount: 5) == Data("%PDF-".utf8)
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(); while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func safeRelativeURL(_ relative: String) throws -> URL {
        let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.path + "/") else { throw PaperDeskError.invalid("路径超出资料库范围") }
        return candidate
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try setPrivateFile(temporary)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        try setPrivateFile(destination)
    }

    private func copyDirectory(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try setPrivateDirectory(destination)
        for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let copy = destination.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: copy)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: copy.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try setPrivateDirectory(copy)
            } else {
                try setPrivateFile(copy)
            }
        }
    }

    private func setPrivateDirectory(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func setPrivateFile(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func copyDatabase(to destination: URL) throws {
        guard let database else { throw PaperDeskError.invalid("资料库未连接") }
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let target else {
            throw PaperDeskError.invalid("无法创建备份资料库")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", database, "main") else { throw PaperDeskError.invalid("无法开始资料库备份") }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else { throw PaperDeskError.invalid("SQLite 一致性备份失败") }
        try setPrivateFile(destination)
    }

    private func encodeTags(_ tags: [String]) throws -> String { String(decoding: try JSONEncoder().encode(tags), as: UTF8.self) }
    private func decodeTags(_ value: String) throws -> [String] { try JSONDecoder().decode([String].self, from: Data(value.utf8)) }
    private func encodeRegions(_ regions: [PageRegion]) throws -> String { String(decoding: try JSONEncoder().encode(regions), as: UTF8.self) }
    private func decodeRegions(_ value: String) throws -> [PageRegion] { try JSONDecoder().decode([PageRegion].self, from: Data(value.utf8)) }
    private func encodeOrigin(_ origin: RecordOrigin?) throws -> String? {
        guard let origin = normalizedOrigin(origin) else { return nil }
        return String(decoding: try JSONEncoder().encode(origin), as: UTF8.self)
    }
    private func decodeOrigin(_ value: String?) throws -> RecordOrigin? {
        guard let value, !value.isEmpty else { return nil }
        return normalizedOrigin(try JSONDecoder().decode(RecordOrigin.self, from: Data(value.utf8)))
    }
    private func normalizedOrigin(_ origin: RecordOrigin?) -> RecordOrigin? {
        guard let origin else { return nil }
        let name = origin.clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = origin.clientVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name?.isEmpty == false || version?.isEmpty == false else { return nil }
        return RecordOrigin(clientName: name?.isEmpty == false ? name : nil,
                            clientVersion: version?.isEmpty == false ? version : nil)
    }
    private func extractiveContent(_ sources: [ExtractiveSource]) -> String {
        sources.map { "PDF 第 \($0.pageIndex + 1) 页\n\($0.text)" }.joined(separator: "\n\n")
    }
    private func notePayload(_ note: ReadingNote) throws -> String {
        var object: [String: Any] = ["paperID": note.paperID, "contextID": note.contextID ?? "", "pageIndex": String(note.pageIndex), "pageLabel": note.pageLabel, "quote": note.quote, "content": note.content, "source": note.source, "status": note.status]
        if let origin = normalizedOrigin(note.origin) {
            var originObject: [String: String] = [:]
            if let clientName = origin.clientName { originObject["clientName"] = clientName }
            if let clientVersion = origin.clientVersion { originObject["clientVersion"] = clientVersion }
            object["origin"] = originObject
        }
        if let kind = note.kind { object["kind"] = kind }
        if let discussionID = note.discussionID { object["discussionID"] = discussionID }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private func normalizedKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
    private func normalizedConversationIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    private func escapeLike(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }

    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func bindDate(_ statement: OpaquePointer, _ index: Int32, _ value: Date) { sqlite3_bind_double(statement, index, value.timeIntervalSince1970) }
    private func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int) { sqlite3_bind_int(statement, index, Int32(clamping: value)) }
    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) }
    private func bindOptionalText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) { if let value { bindText(statement, index, value) } else { sqlite3_bind_null(statement, index) } }
    private func requiredText(_ statement: OpaquePointer, _ index: Int32) throws -> String { guard let value = sqlite3_column_text(statement, index) else { throw PaperDeskError.invalid("资料库字段为空") }; return String(cString: value) }
    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? { guard let value = sqlite3_column_text(statement, index) else { return nil }; return String(cString: value) }
    private func secureFileName(_ value: String) -> String { value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

