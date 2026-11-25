import AppKit
import Combine
import Foundation
import PDFKit
import PaperDeskCore
import PaperDeskStorage

enum PDFZoomMode: Equatable {
    case fitWidth
    case fitPage
    case fixed(CGFloat)
}

/// One live MCP connection from an external client. The connection is kept
/// alive by the `paperdesk-mcp` child process's heartbeat.
struct MCPClientConnection: Identifiable, Equatable, Sendable {
    let id: String
    let paperID: String
    let documentHash: String?
    let clientName: String
    let clientVersion: String?
    let clientID: String?
    let processID: Int32?
    let lastSeen: Date

    var displayName: String {
        QuestionClientRegistry.displayName(clientName: clientName)
    }
}

struct ProjectNamePrompt: Identifiable, Equatable {
    let id: String
    let paperID: String
    let paperTitle: String
    let defaultName: String
    let openTerminalAfterCreate: Bool

    init(paperID: String, paperTitle: String, defaultName: String, openTerminalAfterCreate: Bool) {
        self.id = UUID().uuidString
        self.paperID = paperID
        self.paperTitle = paperTitle
        self.defaultName = defaultName
        self.openTerminalAfterCreate = openTerminalAfterCreate
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public let store: LibraryStore

    @Published public private(set) var papers: [Paper] = []
    @Published public private(set) var selectedPaper: Paper?
    @Published public private(set) var document: PDFDocument?
    @Published public private(set) var notes: [ReadingNote] = []
    @Published private(set) var pdfAnnotationNoteIDs: Set<String> = []
    @Published private(set) var activeSelections: [ReadingSelection] = []
    @Published private(set) var readingGoal = ""
    @Published private(set) var discussion: [PaperChatMessage] = []
    @Published var activeReadingConversationID: String?
    let questions = PaperQuestions()
    @Published public private(set) var context: ContextSnapshot?
    /// The answer whose citation footnotes are currently painted on the PDF.
    /// Only one answer is highlighted at a time.
    @Published public private(set) var activeCitationMessageID: String?
    @Published public private(set) var activeCitationMarks: [CitationMark] = []
    /// New papers start with the narrowest sharing scope. Users can widen it
    /// from the More menu or the MCP connection sheet for the current paper.
    @Published public var scope: ContextScope = .selection {
        didSet { if let id = selectedPaper?.id { paperScopes[id] = scope } }
    }
    @Published public var shareNotesWithAI: Bool = false {
        didSet {
            guard let id = selectedPaper?.id else { return }
            paperNoteSharing[id] = shareNotesWithAI
            synchronizeProjectFiles(paperID: id)
        }
    }
    private var paperScopes: [String: ContextScope] = [:]
    private var paperNoteSharing: [String: Bool] = [:]
    private var externalTitleRefreshTask: Task<Void, Never>?
    private var externalTitleRefreshPaperID: String?
    @Published public var bridgeConnected: Bool = false
    @Published var projectNamePrompt: ProjectNamePrompt?
    @Published private(set) var codexProjectURL: URL?
    @Published private(set) var codexProjectBindingValid = false
    @Published private(set) var codexLastContact: [String: Date] = [:]
    @Published private(set) var mcpConnections: [String: MCPClientConnection] = [:]
    @Published private(set) var detectedMCPProcesses: [DetectedMCPProcess] = []
    private let mcpConnectionTTL: TimeInterval = 30
    @Published public var formulaCaptureMode: Bool = false
    @Published public private(set) var currentPageIndex: Int = 0
    @Published public private(set) var navigationRequest: Int?
    private(set) var restoredViewport: PageRegion?
    /// Increments for every explicit navigation request, including a second
    /// request to the same page. Views use this as an event token so selecting
    /// two notes on one page still replays the requested highlight.
    @Published public private(set) var navigationSerial: Int = 0
    /// Optional geometry supplied by a bridge navigation request. PDFView can
    /// use this later for a visual highlight without changing the durable
    /// context that the user selected.
    @Published public private(set) var navigationRegions: [PageRegion] = []
    @Published var zoomMode: PDFZoomMode = .fitWidth
    private var displayedPDFScale: CGFloat = 1
    private let repairedSelectionImages = NSCache<NSString, NSData>()
    @Published public var errorMessage: String?
    @Published public var statusMessage: String?

    public init(store: LibraryStore) throws {
        self.store = store
        repairedSelectionImages.totalCostLimit = 8 * 1024 * 1024
        refreshLibrary()
    }

    func recordClientConnection(connectionID: String, paperID: String, documentHash: String?,
                                clientName: String?, clientVersion: String?, processID: Int32? = nil) {
        let name = clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = name.isEmpty ? L("未知客户端") : name
        let clientID = QuestionClientRegistry.adapter(clientName: displayName)?.id
        mcpConnections[connectionID] = MCPClientConnection(
            id: connectionID, paperID: paperID, documentHash: documentHash,
            clientName: displayName, clientVersion: clientVersion,
            clientID: clientID, processID: processID, lastSeen: Date())
        pruneExpiredConnections()
    }

    func removeClientConnection(connectionID: String) {
        guard mcpConnections.removeValue(forKey: connectionID) != nil else { return }
    }

    func pruneExpiredConnections(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-mcpConnectionTTL)
        let fresh = mcpConnections.filter { $0.value.lastSeen >= cutoff }
        if fresh.count != mcpConnections.count { mcpConnections = fresh }
    }

    func refreshDetectedMCPProcesses() {
        guard let paper = selectedPaper else {
            if !detectedMCPProcesses.isEmpty { detectedMCPProcesses = [] }
            return
        }
        let detected = MCPProcessScanner.detect(library: store.rootURL, paperID: paper.id)
        if detected != detectedMCPProcesses { detectedMCPProcesses = detected }
    }

    /// Refreshes the two local signals used by the reader's connection badge
    /// and question composer. This keeps them current when the inspector is
    /// hidden or showing another tab.
    func refreshMCPConnectionState() {
        pruneExpiredConnections()
        refreshDetectedMCPProcesses()
    }

    func connectedClients(forPaperID paperID: String, documentHash: String? = nil) -> [MCPClientConnection] {
        let cutoff = Date().addingTimeInterval(-mcpConnectionTTL)
        let hash = documentHash ?? selectedPaper.flatMap { $0.id == paperID ? $0.fileHash : nil }
        func matchesHash(_ bound: String?) -> Bool {
            guard let hash, let bound, bound != hash else { return true }
            return false
        }
        let heartbeat = mcpConnections.values.filter { connection in
            connection.paperID == paperID && connection.lastSeen >= cutoff && matchesHash(connection.documentHash)
        }
        let heartbeatProcessIDs = Set(heartbeat.compactMap(\.processID))
        // Older `paperdesk-mcp` helpers do not send heartbeats yet. A live
        // helper process bound to this paper is still a real MCP connection.
        let detected = detectedMCPProcesses.filter { process in
            process.paperID == paperID && matchesHash(process.documentHash) && !heartbeatProcessIDs.contains(process.pid)
        }
        .map { process in
            MCPClientConnection(id: "process:\(process.pid)", paperID: process.paperID,
                                documentHash: process.documentHash,
                                clientName: process.clientName ?? L("未知客户端"),
                                clientVersion: nil, clientID: process.clientID,
                                processID: process.pid,
                                lastSeen: Date())
        }
        // Heartbeats from older helpers do not identify their process. Keep
        // the historical name fallback only for those older records.
        let heartbeatNames = Set(heartbeat.filter { $0.processID == nil }.map(\.displayName))
        let extra = detected.filter { !heartbeatNames.contains($0.displayName) }
        return (heartbeat + extra).sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    func connectedClientIDs(forPaperID paperID: String) -> Set<String> {
        Set(connectedClients(forPaperID: paperID).compactMap(\.clientID))
    }

    func recordDisplayedPDFScale(_ scale: CGFloat) {
        if scale.isFinite, scale > 0 { displayedPDFScale = scale }
    }

    func adjustPDFZoom(by multiplier: CGFloat) {
        zoomMode = .fixed(min(max(displayedPDFScale * multiplier, 0.15), 6))
    }

    public func refreshLibrary() {
        do {
            papers = try store.papers()
            if let selectedPaper, let refreshed = papers.first(where: { $0.id == selectedPaper.id }) {
                self.selectedPaper = refreshed
            } else if let first = papers.first, selectedPaper == nil {
                openPaper(first)
            }
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    public func refreshNotes() {
        guard let selectedPaper else {
            notes = []
            return
        }
        do {
            notes = try store.notes(paperID: selectedPaper.id)
            synchronizeProjectFiles(paperID: selectedPaper.id)
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    public func openPaper(_ paper: Paper) {
        do {
            let freshPaper = try store.paper(id: paper.id)
            let url = store.readingPDFURL(for: freshPaper)
            guard let loaded = PDFDocument(url: url) else {
                throw PaperDeskError.invalid(L("无法打开这份 PDF：\(freshPaper.fileName)", "Could not open this PDF: \(freshPaper.fileName)"))
            }
            let state = try store.readingState(paperID: freshPaper.id)
            if selectedPaper?.id != freshPaper.id { activeReadingConversationID = nil }
            selectedPaper = freshPaper
            loadCodexProjectContact(for: freshPaper)
            refreshCodexProjectStatus()
            scope = scope(forPaperID: freshPaper.id)
            shareNotesWithAI = sharesNotes(forPaperID: freshPaper.id)
            document = loaded
            pdfAnnotationNoteIDs = NativePDFAnnotations.noteIDs(in: loaded)
            currentPageIndex = min(max(state.pageIndex, 0), max(loaded.pageCount - 1, 0))
            activeSelections = state.selections
            context = state.focusedSelection?.context
            restoredViewport = state.visibleRegions.first { $0.pageIndex == currentPageIndex }
            navigationRequest = currentPageIndex
            navigationSerial &+= 1
            navigationRegions = []
            clearCitationMarks()
            refreshNotes()
            refreshDiscussion()
            refreshDetectedMCPProcesses()
            // Reopening a completed paper must not silently move it back to
            // the in-progress state. The store calls this state "read".
            if freshPaper.readingState != "read" {
                try store.setReadingState(paperID: freshPaper.id, state: "reading")
            }
            if let updated = try? store.paper(id: freshPaper.id) { selectedPaper = updated }
            statusMessage = L("已打开：\(freshPaper.title)", "Opened: \(freshPaper.title)")
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    func refreshCodexProjectStatus() {
        let paper = selectedPaper
        let project = paper.flatMap { try? CodexPaperProject.existing(paper: $0, library: store.rootURL) }
        if let paper, project != nil, (paper.projectName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? store.setProjectName(paperID: paper.id, name: paper.effectiveProjectName)
            if let updated = try? store.paper(id: paper.id) { selectedPaper = updated }
        }
        if let paper {
            synchronizeProjectConfiguration(paper: paper)
        }
        codexProjectURL = project
        codexProjectBindingValid = if let project, let paper {
            CodexPaperProject.hasLocalBinding(in: project, paper: paper, library: store.rootURL)
        } else { false }
        if let paper, project != nil {
            synchronizeProjectFiles(paperID: paper.id)
        }
    }

    func recordCodexProjectContact(paperID: String) {
        do {
            let paper = try store.paper(id: paperID)
            let date = Date()
            try store.recordProjectContact(paperID: paperID, documentHash: paper.fileHash, at: date)
            codexLastContact[paperID] = date
        } catch {
            // A successful MCP response must not be turned into a false
            // connection state when the local history could not be saved.
            errorMessage = error.localizedDescription
        }
    }

    private func loadCodexProjectContact(for paper: Paper) {
        if let contact = try? store.projectContact(paperID: paper.id) {
            codexLastContact[paper.id] = contact
        } else {
            codexLastContact.removeValue(forKey: paper.id)
        }
    }

    func scope(forPaperID id: String) -> ContextScope { paperScopes[id] ?? .selection }
    func sharesNotes(forPaperID id: String) -> Bool { paperNoteSharing[id] ?? false }

    public func openPDF(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let loaded = PDFDocument(url: url), loaded.pageCount > 0 else {
                throw PaperDeskError.invalid(L("这份文件不是可读取的 PDF，或没有页面。"))
            }
            let title = url.deletingPathExtension().lastPathComponent
            let paper = try store.importPDF(from: url, title: title, pageCount: loaded.pageCount)
            refreshLibrary()
            openPaper(paper)
            statusMessage = L("已加入资料库：\(paper.title)", "Added to library: \(paper.title)")
            if (try? CodexPaperProject.existing(paper: paper, library: store.rootURL)) == nil {
                projectNamePrompt = ProjectNamePrompt(
                    paperID: paper.id,
                    paperTitle: paper.title,
                    defaultName: defaultProjectName(for: paper),
                    openTerminalAfterCreate: false
                )
            }
        } catch {
            report(error)
        }
    }

    func defaultProjectName(for paper: Paper) -> String {
        let fileTitle = (paper.fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fileTitle.isEmpty ? paper.effectiveProjectName : fileTitle
    }

    func cancelProjectNamePrompt() {
        projectNamePrompt = nil
    }

    public func captureSelection(_ selection: PDFSelection, document: PDFDocument) {
        guard let selectedPaper, self.document === document else { return }
        guard let snapshot = Self.textSelectionContext(selection, in: document, paper: selectedPaper) else { return }
        appendSelection(snapshot)
    }

    static func textSelectionContext(_ selection: PDFSelection, in document: PDFDocument, paper: Paper) -> ContextSnapshot? {
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let page = selection.pages.first else { return nil }
        let pageIndex = document.index(for: page)
        let pageLabel = page.label ?? String(pageIndex + 1)
        // A PDF selection can span lines and page breaks. Keep the complete
        // text, but persist one rectangle per selected line/page so both the
        // reader and exported PDF can reproduce the full geometry.
        let lineSelections = selection.selectionsByLine()
        let geometrySelections = lineSelections.isEmpty ? [selection] : lineSelections
        var regions: [PageRegion] = []
        for lineSelection in geometrySelections {
            for selectedPage in lineSelection.pages {
                let index = document.index(for: selectedPage)
                let bounds = lineSelection.bounds(for: selectedPage)
                guard index >= 0, bounds.width.isFinite, bounds.height.isFinite,
                      bounds.width > 0, bounds.height > 0 else { continue }
                let region = PageRegion(pageIndex: index, x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
                if !regions.contains(region) { regions.append(region) }
            }
        }
        guard pageIndex >= 0, !regions.isEmpty else { return nil }
        return ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash, pageIndex: pageIndex, pageLabel: pageLabel, text: text, regions: regions)
    }

    /// Stores a single-page formula/equation rectangle together with a small
    /// rendered image. The rectangle is already in PDF page coordinates; the
    /// view is responsible for keeping it inside the crop box and for limiting
    /// the PNG size before calling this method.
    public func captureRegion(pageIndex: Int, bounds: CGRect, imageData: Data) {
        guard let selectedPaper, let document else { return }
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else {
            errorMessage = L("公式区域所在页无效。")
            return
        }
        guard !imageData.isEmpty, imageData.count <= 2 * 1024 * 1024 else {
            errorMessage = L("公式区域图片过大，请缩小框选范围。")
            return
        }
        let crop = page.bounds(for: .cropBox)
        let clipped = bounds.standardized.intersection(crop)
        guard clipped.width > 0, clipped.height > 0, clipped.width.isFinite, clipped.height.isFinite else {
            errorMessage = L("公式区域没有落在当前页面内。")
            return
        }
        let text = page.selection(for: clipped)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = page.label ?? String(pageIndex + 1)
        let region = PageRegion(pageIndex: pageIndex, x: clipped.origin.x, y: clipped.origin.y, width: clipped.width, height: clipped.height)
        let snapshot = ContextSnapshot(paperID: selectedPaper.id, documentHash: selectedPaper.fileHash, pageIndex: pageIndex, pageLabel: label, text: text, regions: [region])
        appendSelection(snapshot, imageData: imageData)
    }

    private func appendSelection(_ snapshot: ContextSnapshot, imageData: Data? = nil) {
        do {
            var state = try store.readingState(paperID: snapshot.paperID)
            // PDFKit can deliver the same text selection more than once.
            if imageData == nil, let last = state.selections.last(where: { !$0.isAI })?.context, last.imageRelativePath == nil,
               last.pageIndex == snapshot.pageIndex, last.text == snapshot.text, last.regions == snapshot.regions { return }
            _ = try saveNewSelection(snapshot, imageData: imageData, aiOrigin: nil, in: &state)
            navigationRegions = snapshot.regions
        } catch { report(error) }
    }
    private func saveNewSelection(_ snapshot: ContextSnapshot, imageData: Data?, aiOrigin: RecordOrigin?,
                                  in state: inout PaperReadingState) throws -> ReadingSelection {
        let saved = try store.saveContext(snapshot, imageData: imageData)
        let item = ReadingSelection(label: PaperReadingState.label(for: state.nextLabel), context: saved, aiOrigin: aiOrigin)
        state.selections.append(item)
        state.nextLabel += 1
        if !item.isAI { state.focusedContextID = item.id }
        try saveSelections(state)
        return item
    }

    func selectionImage(for context: ContextSnapshot) throws -> Data? {
        guard let path = context.imageRelativePath else { return nil }
        let library = store.rootURL.resolvingSymlinksInPath()
        let root = library.appendingPathComponent("contexts").resolvingSymlinksInPath()
        let url = store.rootURL.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == library.appendingPathComponent("contexts").path,
              url.deletingLastPathComponent().path == root.path, url.pathExtension == "png" else {
            throw PaperDeskError.invalid(L("选区图片位置无效。"))
        }

        // Old image files may be blank on rotated or offset pages. Regenerate
        // those crops from the saved geometry without rewriting past records.
        if !path.hasSuffix(ContextSnapshot.cropImageSuffix) {
            let key = context.id as NSString
            if let cached = repairedSelectionImages.object(forKey: key) { return cached as Data }
            let paper = try store.paper(id: context.paperID)
            guard paper.fileHash == context.documentHash else { throw PaperDeskError.conflict(L("选区与 PDF 版本不匹配。")) }
            let source = selectedPaper?.id == paper.id ? document : PDFDocument(url: store.readingPDFURL(for: paper))
            if let source, let page = source.page(at: context.pageIndex),
               page.rotation != 0 || page.bounds(for: .cropBox).origin != .zero,
               context.regions.count == 1, let region = context.regions.first, region.pageIndex == context.pageIndex {
                let bounds = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
                let image = try PDFRegionRenderer.render(page: page, bounds: bounds)
                repairedSelectionImages.setObject(image as NSData, forKey: key, cost: image.count)
                return image
            }
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 2 * 1024 * 1024 else {
            throw PaperDeskError.invalid(L("选区图片大小无效。"))
        }
        return try Data(contentsOf: url)
    }

    func removeSelection(id: String) {
        changeSelections(activeSelections.filter { $0.id != id })
    }

    func clearSelections() {
        changeSelections([])
    }

    private func changeSelections(_ selections: [ReadingSelection]) {
        guard let paper = selectedPaper else { return }
        do {
            var state = try store.readingState(paperID: paper.id)
            state.selections = selections
            state.focusedContextID = state.focusedSelection?.id
            if selections.isEmpty { state.nextLabel = 0 }
            try saveSelections(state)
            navigationRegions = []
        } catch { report(error) }
    }

    private func saveSelections(_ proposedState: PaperReadingState) throws {
        var state = proposedState
        state.updatedAt = Date()
        try store.saveReadingState(state)
        guard selectedPaper?.id == state.paperID else { return }
        activeSelections = state.selections
        context = state.focusedSelection?.context
        errorMessage = nil
    }

    func showSelection(_ snapshot: ContextSnapshot) {
        do {
            let paper = try store.paper(id: snapshot.paperID)
            guard paper.fileHash == snapshot.documentHash else { throw PaperDeskError.conflict(L("原文 PDF 已更换。")) }
            if selectedPaper?.id != paper.id { openPaper(paper) }
            guard selectedPaper?.id == paper.id else { return }
            let focused = activeSelections.first { $0.id == snapshot.id }
            navigate(pageIndex: snapshot.pageIndex, regions: snapshot.regions, focusing: focused)
        } catch { report(error) }
    }

    func refreshDiscussion() {
        do {
            let session = try selectedPaper.map { try store.chatSession(paperID: $0.id) }
            discussion = session?.messages ?? []
            readingGoal = session?.readingInstructions ?? ""
        } catch { report(error) }
    }

    /// Refreshes locally cached conversation names from their bound external
    /// client. Titles are read-only in PaperDesk and remain owned by Codex or
    /// OpenCode.
    func refreshExternalConversationTitles() {
        guard let paperID = selectedPaper?.id, externalTitleRefreshPaperID != paperID else { return }
        externalTitleRefreshTask?.cancel()
        externalTitleRefreshPaperID = paperID

        externalTitleRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    self.externalTitleRefreshPaperID = nil
                    self.externalTitleRefreshTask = nil
                }
            }
            guard let bindings = try? self.store.questionBindings(paperID: paperID) else { return }
            let grouped = Dictionary(grouping: bindings, by: { "\($0.backend)|\($0.projectPath)" })
            var changed = false
            for group in grouped.values {
                guard !Task.isCancelled else { return }
                guard let first = group.first,
                      let adapter = QuestionClientRegistry.adapter(id: first.backend) else { continue }
                let titles = await adapter.conversationTitles(
                    sessionIDs: group.map(\.externalSessionID),
                    project: URL(fileURLWithPath: first.projectPath, isDirectory: true)
                )
                guard !Task.isCancelled else { return }
                for binding in group {
                    guard let title = titles[binding.externalSessionID] else { continue }
                    do {
                        changed = try self.store.synchronizeExternalConversationTitle(binding: binding, title: title) || changed
                    } catch {
                        // A stale/unavailable external binding should not interrupt reading.
                    }
                }
            }
            if changed, self.selectedPaper?.id == paperID { self.refreshDiscussion() }
        }
    }

    /// Paints one answer's numbered citations on the PDF. The previous
    /// answer's marks disappear, so the reader always sees exactly the
    /// sources of the answer being read.
    func activateCitations(for message: PaperChatMessage) {
        guard message.role == .assistant, let citations = message.citations, !citations.isEmpty,
              let paper = selectedPaper else {
            clearCitationMarks()
            return
        }
        var marks: [CitationMark] = []
        for citation in citations {
            guard let context = try? store.context(id: citation.contextID),
                  context.paperID == paper.id,
                  context.documentHash == paper.fileHash,
                  !context.regions.isEmpty else { continue }
            marks.append(CitationMark(label: citation.label, contextID: context.id, regions: context.regions))
        }
        activeCitationMessageID = message.id
        activeCitationMarks = marks
    }

    func toggleCitationMarks(for message: PaperChatMessage) {
        if activeCitationMessageID == message.id {
            clearCitationMarks()
        } else {
            activateCitations(for: message)
        }
    }

    func clearCitationMarks() {
        guard activeCitationMessageID != nil || !activeCitationMarks.isEmpty else { return }
        activeCitationMessageID = nil
        activeCitationMarks = []
    }

    func saveManualDiscussion(question: String, answer: String, attachSelections: Bool, sharedWithAI: Bool) -> Bool {
        guard let paper = selectedPaper else {
            errorMessage = L("请先打开一篇文献。")
            return false
        }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("请填写问题和回答。")
            return false
        }
        do {
            var state = try store.readingState(paperID: paper.id)
            if !attachSelections {
                state.selections = []
                state.focusedContextID = nil
            }
            let snapshot = ReadingQuestionSnapshot(state: state, readingGoal: readingGoal)
            try store.freezeReadingState(snapshot)
            _ = try store.appendDiscussion(paperID: paper.id, snapshotID: snapshot.id, question: question,
                                           answer: answer, sourceContextIDs: state.selections.map(\.id),
                                           idempotencyKey: "manual-\(snapshot.id)", manuallyRecorded: true,
                                           sharedWithAI: sharedWithAI, conversationID: "manual",
                                           conversationTitle: L("手动记录"))
            refreshDiscussion()
            errorMessage = nil
            statusMessage = L("问答已记录。")
            return true
        } catch {
            report(error)
            return false
        }
    }

    func setManualDiscussionSharing(discussionID: String, shared: Bool) {
        guard let paper = selectedPaper else { return }
        do {
            try store.setManualDiscussionSharing(paperID: paper.id, discussionID: discussionID, shared: shared)
            refreshDiscussion()
            errorMessage = nil
            statusMessage = shared ? L("AI 可以检索这条问答。") : L("这条问答仅在本机可见。")
        } catch { report(error) }
    }

    func reviewExtractiveDraft(_ note: ReadingNote, sourceIDs: [String], confirm: Bool) -> Bool {
        guard note.paperID == selectedPaper?.id, note.status == "draft" else { return false }
        do {
            _ = try store.updateExtractiveDraft(noteID: note.id, orderedSourceIDs: sourceIDs,
                                                status: confirm ? "accepted" : "draft", expectedRevision: note.revision)
            refreshNotes()
            synchronizeProjectFiles(paperID: note.paperID)
            statusMessage = confirm ? L("原文摘录已确认。") : L("原文摘录草稿已更新。")
            return true
        } catch {
            report(error)
            return false
        }
    }

    func saveExcerptAsNote(_ note: ReadingNote, content: String) -> Bool {
        guard note.paperID == selectedPaper?.id else { return false }
        do {
            let sources = try store.extractiveSummary(noteID: note.id)
            guard !sources.isEmpty else { throw PaperDeskError.invalid(L("找不到原文摘录。")) }
            let rewritten = ReadingNote(paperID: note.paperID, pageIndex: note.pageIndex, pageLabel: note.pageLabel,
                                        quote: note.quote, content: content, source: note.source, status: "accepted",
                                        origin: note.origin, kind: "note", discussionID: note.discussionID)
            _ = try store.insertNote(rewritten)
            refreshNotes()
            synchronizeProjectFiles(paperID: note.paperID)
            statusMessage = L("已另存为普通笔记。")
            return true
        } catch {
            report(error)
            return false
        }
    }

    func setReadingGoal(_ goal: String) {
        guard let paper = selectedPaper else { return }
        do {
            var session = try store.chatSession(paperID: paper.id)
            session.readingInstructions = String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
            try store.saveChatSession(session, paperID: paper.id)
            refreshDiscussion()
            synchronizeProjectFiles(paperID: paper.id)
            statusMessage = L("阅读目标已保存。")
            errorMessage = nil
        } catch { report(error) }
    }

    public func navigate(pageIndex: Int, regions: [PageRegion] = []) {
        navigate(pageIndex: pageIndex, regions: regions, focusing: nil)
    }

    private func navigate(pageIndex: Int, regions: [PageRegion], focusing selection: ReadingSelection?) {
        guard let selectedPaper, let document else { return }
        let clamped = min(max(pageIndex, 0), max(document.pageCount - 1, 0))
        do {
            try savePosition(paper: selectedPaper, pageIndex: clamped, visibleRegions: [], focusedContextID: selection?.id)
        } catch {
            report(error)
            return
        }
        if let selection { context = selection.context }
        currentPageIndex = clamped
        restoredViewport = nil
        navigationRequest = clamped
        navigationSerial &+= 1
        navigationRegions = regions
    }

    func navigate(to source: ExtractiveSource) {
        let index = source.pageIndex
        guard let page = document?.page(at: index) else { return }
        guard let text = page.string as NSString? else { navigate(pageIndex: index); return }
        let range = text.range(of: source.text, options: .literal)
        guard range.location != NSNotFound, NSMaxRange(range) <= page.numberOfCharacters,
              let selection = page.selection(for: range), selection.string == source.text else {
            navigate(pageIndex: index)
            return
        }
        let lines = selection.selectionsByLine()
        let regions = (lines.isEmpty ? [selection] : lines).compactMap { line -> PageRegion? in
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
            return PageRegion(pageIndex: index, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        }
        navigate(pageIndex: index, regions: regions)
    }

    /// Records the page PDFView has reached while the user scrolls. This is
    /// intentionally separate from `navigate`: a page-change notification is
    /// observational and must not create a new navigation request that makes
    /// PDFView scroll back to the same page.
    func recordDisplayedPage(_ pageIndex: Int, visibleRegions: [PageRegion] = []) {
        guard let selectedPaper, let document, pageIndex >= 0, pageIndex < document.pageCount else { return }
        if pageIndex != currentPageIndex { currentPageIndex = pageIndex }
        do {
            try savePosition(paper: selectedPaper, pageIndex: pageIndex, visibleRegions: visibleRegions)
        } catch {
            report(error)
        }
    }

    private func savePosition(paper: Paper, pageIndex: Int, visibleRegions: [PageRegion], focusedContextID: String? = nil) throws {
        var state = try store.readingState(paperID: paper.id)
        let nextFocus = focusedContextID ?? state.focusedContextID
        guard state.pageIndex != pageIndex || state.visibleRegions != visibleRegions || state.focusedContextID != nextFocus else { return }
        state.pageIndex = pageIndex
        state.visibleRegions = visibleRegions
        state.focusedContextID = nextFocus
        state.updatedAt = Date()
        try store.saveReadingState(state)
    }

    @discardableResult
    public func saveHumanNote(content: String, inPDF: Bool = false) -> Bool {
        guard let selectedPaper else {
            errorMessage = L("请先打开一篇文献。")
            return false
        }
        let contextForPaper = context?.paperID == selectedPaper.id ? context : nil
        if inPDF {
            let anchors = activeSelections.isEmpty ? [contextForPaper].compactMap { $0 } : activeSelections.map(\.context)
            return saveManualPDFAnnotation(content: content, paperID: selectedPaper.id, pageIndex: currentPageIndex, anchors: anchors)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = L("笔记内容不能为空。")
            return false
        }
        let notePageIndex = contextForPaper?.pageIndex ?? currentPageIndex
        let page = document?.page(at: notePageIndex)
        let label = contextForPaper?.pageLabel ?? page?.label ?? String(notePageIndex + 1)
        let note = ReadingNote(paperID: selectedPaper.id, contextID: contextForPaper?.id,
                               pageIndex: notePageIndex, pageLabel: label, quote: contextForPaper?.text ?? "",
                               content: trimmed, source: "human", status: "accepted",
                               kind: "note")
        do {
            _ = try store.insertNote(note)
            refreshNotes()
            synchronizeProjectFiles(paperID: selectedPaper.id)
            statusMessage = L("笔记已保存。")
            return true
        } catch {
            report(error)
            return false
        }
    }

    func saveManualPDFAnnotation(content: String, paperID: String, pageIndex: Int, selections: [ReadingSelection]) -> Bool {
        saveManualPDFAnnotation(content: content, paperID: paperID, pageIndex: pageIndex, anchors: selections.map(\.context))
    }

    private func saveManualPDFAnnotation(content: String, paperID: String, pageIndex: Int, anchors: [ContextSnapshot]) -> Bool {
        guard selectedPaper?.id == paperID, let document else {
            errorMessage = L("请打开这条批注所属的文献。")
            return false
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = L("批注内容不能为空。"); return false }
        let first = anchors.first
        let anchorPage = first?.pageIndex ?? pageIndex
        guard anchorPage >= 0, anchorPage < document.pageCount, let page = document.page(at: anchorPage) else {
            errorMessage = L("找不到批注所在页。")
            return false
        }
        let note = ReadingNote(paperID: paperID, contextID: first?.id, pageIndex: anchorPage,
                               pageLabel: first?.pageLabel ?? page.label ?? String(anchorPage + 1),
                               quote: first?.text ?? "", content: trimmed, kind: "annotation")
        do {
            try editPDFAnnotation(note, contexts: anchors) {
                if anchors.isEmpty {
                    _ = try store.insertNote(note)
                } else {
                    _ = try store.insertAnchoredNote(note, contextIDs: anchors.map(\.id), idempotencyKey: "human-pdf-\(note.id)")
                }
            }
            refreshNotes()
            synchronizeProjectFiles(paperID: paperID)
            statusMessage = L("批注已写入 PDF。")
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    public func updateNote(_ note: ReadingNote, content: String, status: String? = nil) -> Bool {
        if note.status == "draft", status == "accepted", note.kind == "annotation" || note.kind == nil {
            return writeNoteToPDF(note, content: content)
        }
        return saveNoteEdit(note, content: content, status: status ?? note.status,
                            writeToPDF: pdfAnnotationNoteIDs.contains(note.id))
    }

    @discardableResult
    func writeNoteToPDF(_ note: ReadingNote, content: String) -> Bool {
        guard note.kind != "excerpt", note.kind != "note" || note.status == "accepted" else {
            errorMessage = L("请先确认笔记草稿，再选择写入 PDF。")
            return false
        }
        return saveNoteEdit(note, content: content, status: "accepted", writeToPDF: true)
    }

    private func saveNoteEdit(_ note: ReadingNote, content: String, status: String, writeToPDF: Bool) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = L("笔记内容不能为空。"); return false }
        do {
            let save = {
                _ = try self.store.updateNote(id: note.id, content: trimmed, status: status,
                                              expectedRevision: note.revision,
                                              kind: writeToPDF ? "annotation" : nil)
            }
            if writeToPDF {
                var edited = note
                edited.content = trimmed
                let snapshots = try store.noteContextIDs(noteID: note.id).compactMap { try store.context(id: $0) }
                try editPDFAnnotation(edited, contexts: snapshots, save: save)
            } else {
                try save()
            }
            refreshNotes()
            synchronizeProjectFiles(paperID: note.paperID)
            statusMessage = writeToPDF ? L("批注已写入 PDF。") : L("笔记已更新。")
            return true
        } catch {
            report(error)
            return false
        }
    }

    public func acceptNote(_ note: ReadingNote) {
        writeNoteToPDF(note, content: note.content)
    }

    @discardableResult
    public func deleteNote(_ note: ReadingNote) -> Bool {
        do {
            let wasInPDF = pdfAnnotationNoteIDs.contains(note.id)
            if wasInPDF {
                try editPDFAnnotation(note, contexts: [], remove: true) {
                    try store.deleteNote(id: note.id)
                }
            } else {
                try store.deleteNote(id: note.id)
            }
            refreshNotes()
            synchronizeProjectFiles(paperID: note.paperID)
            statusMessage = wasInPDF ? L("已从 PDF 删除批注。") : L("笔记已删除。")
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func editPDFAnnotation(_ note: ReadingNote, contexts: [ContextSnapshot], remove: Bool = false, save: () throws -> Void) throws {
        guard let paper = selectedPaper, note.paperID == paper.id else {
            throw PaperDeskError.conflict(L("请打开这条批注所属的文献。"))
        }
        let workingURL = store.annotatedPDFURL(for: paper)
        let sourceURL = store.readingPDFURL(for: paper)
        let bytes = try Data(contentsOf: sourceURL)
        guard let edited = PDFDocument(data: bytes), !edited.isLocked, edited.allowsCommenting else {
            throw PaperDeskError.invalid(L("这份 PDF 无法编辑批注。"))
        }
        let anchors = contexts.filter { $0.paperID == paper.id && $0.documentHash == paper.fileHash }
        guard anchors.count == contexts.count else {
            throw PaperDeskError.conflict(L("这条批注的选区与当前 PDF 版本不匹配。"))
        }
        try NativePDFAnnotations.edit(edited, note: note, contexts: anchors, remove: remove)
        guard let updatedBytes = edited.dataRepresentation(),
              let updatedDocument = PDFDocument(data: updatedBytes),
              updatedDocument.pageCount == paper.pageCount else {
            throw PaperDeskError.invalid(L("无法保存批注后的 PDF。"))
        }
        let updatedIDs = NativePDFAnnotations.noteIDs(in: updatedDocument)
        guard updatedIDs.contains(note.id) != remove else {
            throw PaperDeskError.invalid(L("PDF 批注写入后无法核对。"))
        }
        let viewport = try store.readingState(paperID: paper.id)
        try updatedBytes.write(to: workingURL, options: .atomic)
        do {
            try save()
        } catch let saveError {
            do {
                if sourceURL == workingURL {
                    try bytes.write(to: workingURL, options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: workingURL)
                }
            } catch {
                throw PaperDeskError.conflict(L("阅读记录保存失败，PDF 也未能恢复。请保留当前文件并检查批注。"))
            }
            throw saveError
        }

        document = updatedDocument
        pdfAnnotationNoteIDs = updatedIDs
        restoredViewport = viewport.visibleRegions.first { $0.pageIndex == currentPageIndex }
        navigationRegions = []
        navigationRequest = currentPageIndex
        navigationSerial &+= 1
    }

    func revealCurrentPDF() {
        guard let selectedPaper else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.readingPDFURL(for: selectedPaper)])
    }

    public func readPages(paperID: String, pageIndices: [Int]) throws -> JSONValue {
        let paper = try store.paper(id: paperID)
        let pdf = selectedPaper?.id == paperID ? document : PDFDocument(url: store.pdfURL(for: paper))
        guard let document = pdf else { throw PaperDeskError.missing(L("无法打开请求中的文献。")) }
        guard !pageIndices.isEmpty else { throw PaperDeskError.invalid(L("至少需要指定一页。")) }
        let uniquePages = Array(Set(pageIndices)).sorted()
        guard uniquePages.count <= 10 else { throw PaperDeskError.invalid(L("一次最多读取 10 页。")) }
        let readingScope = scope(forPaperID: paperID)
        switch readingScope {
        case .selection:
            // read_pages is deliberately page-oriented. In selection mode it
            // must never widen a fixed excerpt into the entire page; callers
            // should use get_context with the context ID instead.
            throw PaperDeskError.invalid(L("当前范围为“仅选区”，请使用固定选区继续讨论。"))
        case .page:
            let allowedPage = try store.readingState(paperID: paperID).pageIndex
            guard uniquePages.allSatisfy({ $0 == allowedPage }) else { throw PaperDeskError.invalid(L("当前范围为“当前页”，只能读取当前页。")) }
        case .document:
            break
        }
        var total = 0
        var wasTruncated = false
        var items: [JSONValue] = []
        for pageIndex in uniquePages {
            guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { throw PaperDeskError.invalid(L("页码超出文献范围：\(pageIndex + 1)", "Page out of range: \(pageIndex + 1)")) }
            let fullText = page.string ?? ""
            let remaining = max(0, 40_000 - total)
            let clipped = String(fullText.prefix(remaining))
            let itemTruncated = clipped.count < fullText.count
            total += clipped.count
            wasTruncated = wasTruncated || itemTruncated
            items.append(.object(["pageIndex": .number(Double(pageIndex)), "pageLabel": .string(page.label ?? String(pageIndex + 1)), "text": .string(clipped), "truncated": .bool(itemTruncated)]))
            if total >= 40_000 { break }
        }
        return .object(["paperID": .string(paper.id), "scope": .string(readingScope.rawValue), "pages": .array(items), "truncated": .bool(wasTruncated)])
    }

    public func discussionPrompt() -> String {
        guard let selectedPaper else { return L("请先在 PaperDesk 中打开一篇文献。") }
        guard let context else { return L("请使用 PaperDesk 的阅读工具读取当前文献的选区，然后回答我的问题。文献：\(selectedPaper.title)", "Use PaperDesk reading tools to read the current paper's selection, then answer my question. Paper: \(selectedPaper.title)") }
        let imageInstruction = context.imageRelativePath == nil ? "" : L("请在读取选区时带上公式图片（include_image=true）。")
        return L("请用 PaperDesk 读取固定选区 \(context.id)，对应《\(selectedPaper.title)》第 \(context.pageLabel) 页。\(imageInstruction)请根据原文回答，并区分作者陈述与补充推导。", "Use PaperDesk to read pinned selection \(context.id) in “\(selectedPaper.title)”, page \(context.pageLabel). \(imageInstruction)Answer from the source text, and distinguish the author's statements from your own derivations.")
    }

    public func exportMarkdown() {
        guard let selectedPaper else { return }
        do {
            let text = try store.exportMarkdown(paperID: selectedPaper.id)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(selectedPaper.title).md"
            panel.allowedContentTypes = [.text]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = L("笔记已导出。")
        } catch { report(error) }
    }

    public func backupLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("备份")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.backup(to: url)
            statusMessage = L("资料库已备份。")
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    public func exportAnnotatedPDF() {
        guard let selectedPaper else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("\(selectedPaper.title)-批注.pdf", "\(selectedPaper.title)-annotated.pdf")
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeAnnotatedPDF(to: url)
            statusMessage = L("批注 PDF 已导出。")
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    /// Copies the current reading PDF to a destination outside the library.
    public func writeAnnotatedPDF(to outputURL: URL) throws {
        guard let selectedPaper else {
            throw PaperDeskError.missing(L("请先打开一篇文献。"))
        }
        let sourceURL = store.readingPDFURL(for: selectedPaper)
        let managedRoot = store.rootURL.standardizedFileURL
        let canonicalOutput = canonicalFileURL(outputURL)
        let protectedURLs = [store.pdfURL(for: selectedPaper), store.annotatedPDFURL(for: selectedPaper)]
        guard !protectedURLs.contains(where: { isSameFile(canonicalOutput, canonicalFileURL($0)) }) else {
            throw PaperDeskError.invalid(L("导出副本不能覆盖资料库里的 PDF。"))
        }
        guard !isPath(outputURL.standardizedFileURL, inside: managedRoot),
              !isPath(canonicalOutput, inside: canonicalFileURL(managedRoot)) else {
            throw PaperDeskError.invalid(L("导出副本必须保存到资料库之外。"))
        }
        try Data(contentsOf: sourceURL).write(to: outputURL, options: .atomic)
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isPath(_ url: URL, inside root: URL) -> Bool {
        let path = url.path
        let rootPath = root.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: lhs.path), FileManager.default.fileExists(atPath: rhs.path),
              let left = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let right = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let leftDevice = left[.systemNumber] as? NSNumber,
              let rightDevice = right[.systemNumber] as? NSNumber,
              let leftInode = left[.systemFileNumber] as? NSNumber,
              let rightInode = right[.systemFileNumber] as? NSNumber else { return false }
        return leftDevice == rightDevice && leftInode == rightInode
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = nil
    }
}
