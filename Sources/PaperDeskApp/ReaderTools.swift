import Foundation
import PDFKit
import PaperDeskCore
import PaperDeskStorage

/// Operations exposed to the Codex MCP process.
///
/// A bound MCP process carries one paper ID and one PDF hash. Every operation
/// checks both values before reading or writing local data. An unbound process
/// keeps the legacy behaviour and follows the paper currently open in the
/// reader.
@MainActor
final class ReaderTools {
    private let model: AppModel
    private var boundPaperID: String?
    private var boundDocumentHash: String?
    /// Attribution supplied by the MCP transport, never by a model tool
    /// argument. It is scoped to one bridge request in `handle` so one
    /// client's label cannot leak into a later connection.
    private var clientOrigin: RecordOrigin?
    /// The transport's connection ID is the default group for a new chat.
    /// A follow-up can continue a previously archived answer after reconnecting.
    private var clientConversationID: String?
    /// PID supplied by the transport, used to distinguish two helpers that
    /// happen to share a client label while their parent process is changing.
    private var clientProcessID: Int32?
    private var pendingQuestion: PendingPaperQuestion?

    init(model: AppModel, boundPaperID: String? = nil, boundDocumentHash: String? = nil,
         clientOrigin: RecordOrigin? = nil, clientConversationID: String? = nil) {
        self.model = model
        self.boundPaperID = boundPaperID
        self.boundDocumentHash = boundDocumentHash
        self.clientOrigin = clientOrigin
        self.clientConversationID = clientConversationID
    }

    func handle(_ request: BridgeRequest) -> BridgeResponse {
        let previousBinding = (boundPaperID, boundDocumentHash, clientOrigin, clientConversationID, clientProcessID)
        let previousQuestion = pendingQuestion
        if let injected = request.arguments.objectValue {
            boundPaperID = injected["_bound_paper_id"]?.stringValue ?? boundPaperID
            boundDocumentHash = injected["_bound_document_hash"]?.stringValue ?? boundDocumentHash
            let name = injected["_client_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = injected["_client_version"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientName = name?.isEmpty == false ? name : nil
            let clientVersion = version?.isEmpty == false ? version : nil
            clientOrigin = (clientName != nil || clientVersion != nil)
                ? RecordOrigin(clientName: clientName, clientVersion: clientVersion)
                : nil
            let conversation = injected["_conversation_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            clientConversationID = conversation?.isEmpty == false ? conversation : clientConversationID
            if let rawProcessID = injected["_client_pid"]?.intValue,
               rawProcessID > 0, rawProcessID <= Int(Int32.max) {
                clientProcessID = Int32(rawProcessID)
            } else if injected["_client_pid"] != nil {
                clientProcessID = nil
            }
        }
        defer {
            boundPaperID = previousBinding.0
            boundDocumentHash = previousBinding.1
            clientOrigin = previousBinding.2
            clientConversationID = previousBinding.3
            clientProcessID = previousBinding.4
            pendingQuestion = previousQuestion
        }
        do {
            if request.method == "__mcp_client_connected" || request.method == "__mcp_client_heartbeat" {
                registerLiveConnection()
                if request.method == "__mcp_client_heartbeat" {
                    return BridgeResponse(id: request.id, result: .object([:]))
                }
            }
            if request.method == "__mcp_client_disconnected" {
                if let id = clientConversationID { model.removeClientConnection(connectionID: id) }
                return BridgeResponse(id: request.id, result: .object([:]))
            }
            if let id = request.arguments["_question_request"].stringValue {
                guard let pending = model.questions.request(id: id), pending.paperID == boundPaperID,
                      pending.documentHash == boundDocumentHash else {
                    throw PaperDeskError.conflict("这次 PaperDesk 提问已结束或与当前文献不匹配。")
                }
                pendingQuestion = pending
            }
            let result = try execute(request.method, arguments: request.arguments)
            if (!request.method.hasPrefix("__mcp_") || request.method == "__mcp_resources_read"
                || request.method == "__mcp_client_connected"),
               let paperID = boundPaperID, let hash = boundDocumentHash,
               result["isError"].boolValue != true,
               (try? model.store.paper(id: paperID).fileHash) == hash {
                model.recordCodexProjectContact(paperID: paperID)
            }
            return BridgeResponse(id: request.id, result: result)
        } catch {
            model.errorMessage = error.localizedDescription
            let message = error is PaperDeskError ? error.localizedDescription : "操作未完成，请在阅读窗口查看详情。"
            return BridgeResponse(id: request.id, result: .textResult(message, isError: true))
        }
    }

    private func result(_ data: JSONValue) throws -> JSONValue {
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(try data.encodedText())])]),
            "structuredContent": data,
            "isError": .bool(false)
        ])
    }

    /// Records a live MCP connection announced by a client process. Stale PDF
    /// bindings are ignored so a replaced document never shows as connected.
    private func registerLiveConnection() {
        guard let paperID = boundPaperID, let hash = boundDocumentHash,
              (try? model.store.paper(id: paperID).fileHash) == hash else { return }
        let key = clientConversationID ?? "\(paperID)|\(clientOrigin?.clientName ?? "unknown")"
        model.recordClientConnection(connectionID: key, paperID: paperID, documentHash: hash,
                                     clientName: clientOrigin?.clientName,
                                     clientVersion: clientOrigin?.clientVersion,
                                     processID: clientProcessID)
    }

    private func required(_ key: String, _ arguments: JSONValue, maximum: Int = 256) throws -> String {
        guard let value = arguments[key].stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum else {
            throw PaperDeskError.invalid("缺少或无效的参数：\(key)")
        }
        return value
    }

    private func optional(_ key: String, _ arguments: JSONValue, maximum: Int = 256) throws -> String? {
        guard arguments[key] != .null else { return nil }
        return try required(key, arguments, maximum: maximum)
    }

    private func paperInfo(_ paper: Paper) -> JSONValue {
        .object([
            "paper_id": .string(paper.id),
            "title": .string(paper.title),
            "file_name": .string(paper.fileName),
            "document_hash": .string(paper.fileHash),
            "page_count": .number(Double(paper.pageCount)),
            "tags": .array(paper.tags.map(JSONValue.string)),
            "reading_state": .string(paper.readingState)
        ])
    }

    private func resolvePaper(id: String? = nil) throws -> Paper {
        if let boundPaperID {
            if let id, id != boundPaperID {
                throw PaperDeskError.conflict("当前 Codex 项目绑定的是另一篇文献")
            }
            let paper = try model.store.paper(id: boundPaperID)
            guard boundDocumentHash == nil || boundDocumentHash == paper.fileHash else {
                throw PaperDeskError.conflict("Codex 项目绑定的 PDF 版本已经变化")
            }
            return paper
        }
        if let id { return try model.store.paper(id: id) }
        guard let paper = model.selectedPaper else { throw PaperDeskError.missing("当前没有打开文献") }
        return paper
    }

    private func checkPaper(_ paper: Paper) throws {
        if let boundPaperID, paper.id != boundPaperID {
            throw PaperDeskError.conflict("当前 Codex 项目绑定的是另一篇文献")
        }
        if let boundDocumentHash, paper.fileHash != boundDocumentHash {
            throw PaperDeskError.conflict("Codex 项目绑定的 PDF 版本已经变化")
        }
    }

    /// Search/detail tools deliberately have a narrower paper scope than the
    /// legacy library search. A bound MCP process can only see its bound
    /// paper; an unbound connection can only see the paper currently open in
    /// PaperDesk. This prevents a generic Codex chat from accidentally
    /// browsing another project's private notes.
    private func resolveCurrentPaper(id: String? = nil) throws -> Paper {
        if boundPaperID != nil {
            return try resolvePaper(id: id)
        }
        guard let current = model.selectedPaper else {
            throw PaperDeskError.missing("当前没有打开文献")
        }
        if let id, id != current.id {
            throw PaperDeskError.conflict("未绑定的连接只能访问当前正在阅读的文献")
        }
        return current
    }

    private func originObject(_ origin: RecordOrigin?) -> JSONValue {
        guard let origin else { return .null }
        return .object([
            "client_name": origin.clientName.map(JSONValue.string) ?? .null,
            "client_version": origin.clientVersion.map(JSONValue.string) ?? .null
        ])
    }

    private func messageContextIDs(_ message: PaperChatMessage) -> [String] {
        var result: [String] = []
        for id in (message.sourceContextIDs ?? []) where !id.isEmpty && !result.contains(id) {
            result.append(id)
        }
        if result.isEmpty, let id = message.contextID, !id.isEmpty {
            result.append(id)
        }
        return result
    }

    private func messageIsReadable(_ message: PaperChatMessage) -> Bool {
        // Manual conversations are local by default. They become visible to
        // an AI client only after the user explicitly shares that record.
        !(message.manuallyRecorded == true && message.sharedWithAI != true)
    }

    private struct DiscussionRecord {
        let id: String
        let paperID: String
        let snapshotID: String?
        let question: String?
        let answer: String?
        let role: String?
        let messages: [PaperChatMessage]
        let sourceContextIDs: [String]
        let createdAt: Date
        let paired: Bool
    }

    private func discussionRecords(for paper: Paper) throws -> [DiscussionRecord] {
        // Keep the original positions while filtering. Otherwise a private
        // manual message or a source-excerpt message could disappear and make
        // two originally non-contiguous messages look like a discussion pair.
        let messages = try model.store.chatSession(paperID: paper.id).messages
        var records: [DiscussionRecord] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            if message.isExtractiveSummary || !messageIsReadable(message) {
                index += 1
                continue
            }
            if index + 1 < messages.count {
                let next = messages[index + 1]
                if message.role == .user,
                   next.role == .assistant,
                   !next.isExtractiveSummary,
                   messageIsReadable(next),
                   let snapshotID = message.readingSnapshotID,
                   !snapshotID.isEmpty,
                   next.readingSnapshotID == snapshotID {
                    let ids = messageContextIDs(message) + messageContextIDs(next).filter { !messageContextIDs(message).contains($0) }
                    records.append(DiscussionRecord(id: next.id,
                                                    paperID: paper.id,
                                                    snapshotID: snapshotID,
                                                    question: message.text,
                                                    answer: next.text,
                                                    role: nil,
                                                    messages: [message, next],
                                                    sourceContextIDs: ids,
                                                    createdAt: next.createdAt,
                                                    paired: true))
                    index += 2
                    continue
                }
            }
            records.append(DiscussionRecord(id: message.id,
                                            paperID: paper.id,
                                            snapshotID: message.readingSnapshotID,
                                            question: message.role == .user ? message.text : nil,
                                            answer: message.role == .assistant ? message.text : nil,
                                            role: message.role.rawValue,
                                            messages: [message],
                                            sourceContextIDs: messageContextIDs(message),
                                            createdAt: message.createdAt,
                                            paired: false))
            index += 1
        }
        return records
    }

    private func citationObject(_ citation: MessageCitation) -> JSONValue {
        .object([
            "context_id": .string(citation.contextID),
            "label": .string(citation.label),
            "page_label": citation.pageLabel.map(JSONValue.string) ?? .null
        ])
    }

    private func messageObject(_ message: PaperChatMessage) -> JSONValue {
        var value: [String: JSONValue] = [
            "message_id": .string(message.id),
            "role": .string(message.role.rawValue),
            "page_label": message.pageLabel.map(JSONValue.string) ?? .null,
            "context_id": message.contextID.map(JSONValue.string) ?? .null,
            "source_context_ids": .array(messageContextIDs(message).map(JSONValue.string)),
            "source_page_index": message.sourcePageIndex.map { .number(Double($0)) } ?? .null,
            "reading_snapshot_id": message.readingSnapshotID.map(JSONValue.string) ?? .null,
            "created_at": .string(ISO8601DateFormatter().string(from: message.createdAt)),
            "origin": originObject(message.origin),
            "conversation_id": message.conversationID.map(JSONValue.string) ?? .null,
            "manually_recorded": message.manuallyRecorded.map(JSONValue.bool) ?? .null,
            "shared_with_ai": message.sharedWithAI.map(JSONValue.bool) ?? .null,
            "citations": .array((message.citations ?? []).map(citationObject))
        ]
        if message.isExtractiveSummary {
            value["is_extractive_summary"] = .bool(true)
        }
        return .object(value)
    }

    private func discussionObject(_ record: DiscussionRecord, includeMessages: Bool = false) -> JSONValue {
        let boundedQuestion = record.question.map { boundedText($0, maximum: 120_000) }
        let boundedAnswer = record.answer.map { boundedText($0, maximum: 120_000) }
        var value: [String: JSONValue] = [
            "discussion_id": .string(record.id),
            "paper_id": .string(record.paperID),
            "snapshot_id": record.snapshotID.map(JSONValue.string) ?? .null,
            "question": boundedQuestion.map(JSONValue.string) ?? .null,
            "answer": boundedAnswer.map(JSONValue.string) ?? .null,
            "role": record.role.map(JSONValue.string) ?? .null,
            "source_context_ids": .array(record.sourceContextIDs.map(JSONValue.string)),
            "context_ids": .array(record.sourceContextIDs.map(JSONValue.string)),
            "created_at": .string(ISO8601DateFormatter().string(from: record.createdAt)),
            "paired": .bool(record.paired),
            "citations": .array((record.messages.last(where: { $0.role == .assistant })?.citations ?? []).map(citationObject))
        ]
        value["question_truncated"] = .bool(record.question.map { $0.count > (boundedQuestion?.count ?? 0) } ?? false)
        value["answer_truncated"] = .bool(record.answer.map { $0.count > (boundedAnswer?.count ?? 0) } ?? false)
        if let first = record.messages.first {
            value["origin"] = originObject(first.origin)
            value["conversation_id"] = first.conversationID.map(JSONValue.string) ?? .null
            value["manually_recorded"] = first.manuallyRecorded.map(JSONValue.bool) ?? .null
            value["shared_with_ai"] = first.sharedWithAI.map(JSONValue.bool) ?? .null
        } else {
            value["origin"] = .null
        }
        if includeMessages {
            value["messages"] = .array(record.messages.map(messageObject))
        }
        return .object(value)
    }

    private func paged<T>(_ values: [T], arguments: JSONValue, maximumPageSize: Int = 50) -> (page: Int, pageSize: Int, pageValues: [T], hasMore: Bool) {
        let requestedPage = max(1, arguments["page"].intValue ?? 1)
        let pageSize = min(max(1, arguments["page_size"].intValue ?? arguments["limit"].intValue ?? 20), maximumPageSize)
        let maximumPage = values.isEmpty ? 1 : ((values.count - 1) / pageSize) + 1
        let page = min(requestedPage, maximumPage)
        let start = min(values.count, (page - 1) * pageSize)
        let end = min(values.count, start + pageSize)
        return (page, pageSize, Array(values[start..<end]), end < values.count)
    }

    private func noteIsReadable(_ note: ReadingNote, paperID: String, includeDrafts: Bool = false) -> Bool {
        note.paperID == paperID && (includeDrafts || note.status == "accepted") &&
            (note.source == "ai" || model.sharesNotes(forPaperID: paperID))
    }

    private func boundedText(_ text: String, maximum: Int) -> String {
        String(text.prefix(maximum))
    }

    /// Split at Unicode scalar boundaries and bound bytes before JSON escaping.
    private func recordFragment(_ text: String?, offset: JSONValue, maximumBytes: Int) throws -> (text: JSONValue, next: JSONValue) {
        let startOffset = offset == .null ? 0 : (offset.intValue ?? -1)
        guard startOffset >= 0 else { throw PaperDeskError.invalid("记录的续读位置无效。") }
        guard let text else { return (.null, .null) }
        let scalars = text.unicodeScalars
        guard let start = scalars.index(scalars.startIndex, offsetBy: startOffset, limitedBy: scalars.endIndex) else {
            throw PaperDeskError.invalid("记录的续读位置超出内容范围。")
        }
        var end = start
        var usedBytes = 0
        var nextOffset = startOffset
        while end < scalars.endIndex {
            let width = String(scalars[end]).utf8.count
            guard usedBytes + width <= maximumBytes else { break }
            usedBytes += width
            nextOffset += 1
            scalars.formIndex(after: &end)
        }
        return (.string(String(scalars[start..<end])), end == scalars.endIndex ? .null : .number(Double(nextOffset)))
    }

    private func searchSnippet(_ text: String, query: String, maximum: Int) -> (text: String, truncated: Bool) {
        guard text.count > maximum else { return (text, false) }
        guard !query.isEmpty, let match = text.range(of: query, options: [.caseInsensitive]) else {
            return (boundedText(text, maximum: maximum), true)
        }
        let matchStart = text.distance(from: text.startIndex, to: match.lowerBound)
        let matchEnd = text.distance(from: text.startIndex, to: match.upperBound)
        let context = max(0, (maximum - (matchEnd - matchStart)) / 2)
        let startOffset = max(0, matchStart - context)
        let endOffset = min(text.count, max(matchEnd + context, startOffset + maximum))
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        var snippet = String(text[start..<end])
        if startOffset > 0 { snippet = "…" + snippet }
        if endOffset < text.count { snippet += "…" }
        return (snippet, true)
    }

    private func discussionSearchObject(_ record: DiscussionRecord, query: String) -> JSONValue {
        var value = discussionObject(record).objectValue ?? [:]
        if let question = record.question {
            let snippet = searchSnippet(question, query: query, maximum: 1_000)
            value["question"] = .string(snippet.text)
            value["question_truncated"] = .bool(snippet.truncated)
        }
        if let answer = record.answer {
            let snippet = searchSnippet(answer, query: query, maximum: 1_000)
            value["answer"] = .string(snippet.text)
            value["answer_truncated"] = .bool(snippet.truncated)
        }
        return .object(value)
    }

    private func noteSearchObject(_ note: ReadingNote, paper: Paper, query: String) throws -> JSONValue {
        var value = try noteObject(note, paper: paper).objectValue ?? [:]
        let content = searchSnippet(note.content, query: query, maximum: 1_000)
        let quote = searchSnippet(note.quote, query: query, maximum: 400)
        value["content"] = .string(content.text)
        value["quote"] = .string(quote.text)
        value["content_truncated"] = .bool(content.truncated)
        value["quote_truncated"] = .bool(quote.truncated)
        value.removeValue(forKey: "extractive_sources")
        value.removeValue(forKey: "extractive_coverage")
        return .object(value)
    }

    private func noteObject(_ note: ReadingNote, paper: Paper, includeExtractiveSources: Bool = false) throws -> JSONValue {
        let ids = (try? model.store.noteContextIDs(noteID: note.id)) ?? []
        let extractiveSources = (try? model.store.extractiveSummary(noteID: note.id)) ?? []
        // Older databases predate `kind`; infer the two historical forms so
        // clients can still distinguish a pending annotation from a verified
        // original excerpt.
        let kind = note.kind ?? (extractiveSources.isEmpty
            ? (note.source == "ai" && note.status == "draft" ? "annotation" : "note")
            : "excerpt")
        var value: [String: JSONValue] = [
            "note_id": .string(note.id),
            "paper_id": .string(note.paperID),
            "document_hash": .string(paper.fileHash),
            "context_id": note.contextID.map(JSONValue.string) ?? .null,
            "source_context_ids": .array(ids.map(JSONValue.string)),
            "context_ids": .array(ids.map(JSONValue.string)),
            "page_index": .number(Double(note.pageIndex)),
            "page_label": .string(note.pageLabel),
            "quote": .string(boundedText(note.quote, maximum: 40_000)),
            "content": .string(boundedText(note.content, maximum: 200_000)),
            "quote_truncated": .bool(note.quote.count > 40_000),
            "content_truncated": .bool(note.content.count > 200_000),
            "status": .string(note.status),
            "source": .string(note.source),
            "kind": .string(kind),
            "discussion_id": note.discussionID.map(JSONValue.string) ?? .null,
            "origin": originObject(note.origin),
            "revision": .number(Double(note.revision)),
            "created_at": .string(ISO8601DateFormatter().string(from: note.createdAt)),
            "updated_at": .string(ISO8601DateFormatter().string(from: note.updatedAt))
        ]
        if includeExtractiveSources || kind == "excerpt" {
            var sourceValues: [JSONValue] = []
            for source in extractiveSources {
                let fragment = try recordFragment(source.text, offset: .null, maximumBytes: 360)
                sourceValues.append(.object(["source_id": .string(source.id), "page_index": .number(Double(source.pageIndex)),
                                             "page_label": .string(source.pageLabel), "text": fragment.text,
                                             "text_truncated": .bool(fragment.next != .null)]))
            }
            value["extractive_sources"] = .array(sourceValues)
            if let coverage = try? model.store.extractiveCoverage(noteID: note.id) {
                value["extractive_coverage"] = (try? JSONValue.from(coverage)) ?? .null
            }
        }
        return .object(value)
    }

    private func pageAnchor(for paper: Paper, pageIndex: Int) throws -> (index: Int, label: String) {
        let page = try pdfPages(paper: paper, indices: [pageIndex]).first
        guard let page else { throw PaperDeskError.invalid("阅读页码超出文献范围") }
        return (page.index, page.label)
    }

    private func snapshot(id: String, paperID: String? = nil) throws -> ContextSnapshot {
        guard let context = try model.store.context(id: id) else {
            throw PaperDeskError.missing("找不到这份固定选区，请在阅读窗口重新选择。")
        }
        let paper = try resolvePaper(id: paperID ?? context.paperID)
        guard context.paperID == paper.id, context.documentHash == paper.fileHash else {
            throw PaperDeskError.conflict("选区与当前文献版本不匹配")
        }
        return context
    }

    private func contextObject(_ context: ContextSnapshot, label: String? = nil) -> JSONValue {
        let text = context.sourceText
        return .object([
            "context_id": .string(context.id),
            "label": label.map(JSONValue.string) ?? .null,
            "page_index": .number(Double(context.pageIndex)),
            "page_label": .string(context.pageLabel),
            "text": .string(String(text.prefix(40_000))),
            "text_available": .bool(!text.isEmpty),
            "truncated": .bool(text.count > 40_000),
            "regions": (try? JSONValue.from(context.regions)) ?? .array([]),
            "image_available": .bool(context.imageRelativePath != nil),
            "source_role": .string("untrusted_document")
        ])
    }

    private func contextResult(_ context: ContextSnapshot, includeImage: Bool) throws -> JSONValue {
        let image = includeImage ? try model.selectionImage(for: context) : nil
        let state = try model.store.readingState(paperID: context.paperID)
        let selection = state.selections.first { $0.id == context.id }
        let value = selection.map(selectionObject) ?? contextObject(context)
        var data = value.objectValue ?? [:]
        data["paper"] = paperInfo(try resolvePaper(id: context.paperID))
        data["image_included"] = .bool(image != nil)
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(try JSONValue.object(data).encodedText())])]
        if let image {
            blocks.append(imageBlock(image, contextID: context.id))
        }
        return .object(["content": .array(blocks), "structuredContent": .object(data), "isError": .bool(false)])
    }

    private func selectionArray(_ state: PaperReadingState) -> JSONValue {
        .array(state.selections.map(selectionObject))
    }

    private func selectionObject(_ selection: ReadingSelection) -> JSONValue {
        var value = contextObject(selection.context, label: selection.label).objectValue ?? [:]
        value["selection_id"] = .string(selection.id)
        value["source"] = .string(selection.isAI ? "ai" : "human")
        value["origin"] = originObject(selection.aiOrigin)
        return .object(value)
    }

    private func stateObject(_ state: PaperReadingState, paper: Paper, readingGoal: String, live: Bool) throws -> JSONValue {
        return .object([
            "paper": paperInfo(paper),
            "active_in_reader": .bool(live),
            "context_id": state.focusedSelection.map { .string($0.id) } ?? .null,
            "scope": .string(model.scope(forPaperID: paper.id).rawValue),
            "share_human_notes": .bool(model.sharesNotes(forPaperID: paper.id)),
            "current_page_index": .number(Double(state.pageIndex)),
            "visible_regions": (try? JSONValue.from(state.visibleRegions)) ?? .array([]),
            "selections": selectionArray(state),
            "next_selection_label": .string(PaperReadingState.label(for: state.nextLabel)),
            "reading_goal": .string(readingGoal),
            "updated_at": .string(ISO8601DateFormatter().string(from: state.updatedAt))
        ])
    }

    private func snapshotResult(_ snapshot: ReadingQuestionSnapshot, paper: Paper) throws -> JSONValue {
        let state = snapshot.state
        let focusedID = state.focusedSelection?.id
        let imageSelections = state.selections.filter { $0.context.imageRelativePath != nil }
        var metadata: [String: JSONValue] = [
            "snapshot_id": .string(snapshot.id),
            "paper": paperInfo(paper),
            "reading_goal": .string(snapshot.readingGoal),
            "created_at": .string(ISO8601DateFormatter().string(from: snapshot.createdAt)),
            "updated_at": .string(ISO8601DateFormatter().string(from: state.updatedAt)),
            "active_in_reader": .bool(model.selectedPaper?.id == paper.id),
            "context_id": focusedID.map(JSONValue.string) ?? .null,
            "current_page_index": .number(Double(state.pageIndex)),
            "visible_regions": (try? JSONValue.from(state.visibleRegions)) ?? .array([]),
            "selections": selectionArray(state),
            "contexts": selectionArray(state),
            "source_document_hash": .string(state.documentHash),
            "image_context_ids": .array([]),
            "deferred_image_context_ids": .array(imageSelections.map { .string($0.id) }),
            "unavailable_image_context_ids": .array([])
        ]

        // Both transports wrap the tool result. Leave room for their envelope
        // and measure the encoded blocks, including base64 and JSON overhead.
        let encoder = MCPLineCodec.responseEncoder()
        let budget = MCPLineCodec.maximumResponseBytes - 16 * 1024
        let metadataBytes = try encoder.encode(result(.object(metadata))).count
        guard metadataBytes <= budget else {
            throw PaperDeskError.invalid("选区内容过多，请移除部分选区后重试。")
        }
        var remainingBytes = budget - metadataBytes
        var images: [String: [JSONValue]] = [:]
        var unavailable: Set<String> = []
        var priority = imageSelections
        if let index = priority.firstIndex(where: { $0.id == focusedID }), index > 0 {
            let item = priority.remove(at: index)
            priority.insert(item, at: 0)
        }
        for item in priority {
            guard let image = try? model.selectionImage(for: item.context) else {
                unavailable.insert(item.id)
                continue
            }
            let heading = "Selection \(item.label) · PDF page \(item.context.pageIndex + 1)"
                + (item.isAI ? " · AI mark" : "") + (item.id == focusedID ? " · Current focus" : "")
            let blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(heading)]), imageBlock(image, contextID: item.id)]
            let bytes = try encoder.encode(JSONValue.array(blocks)).count
            guard bytes <= remainingBytes else { continue }
            remainingBytes -= bytes
            images[item.id] = blocks
        }

        metadata["image_context_ids"] = .array(imageSelections.filter { images[$0.id] != nil }.map { .string($0.id) })
        metadata["deferred_image_context_ids"] = .array(imageSelections.filter { images[$0.id] == nil && !unavailable.contains($0.id) }.map { .string($0.id) })
        metadata["unavailable_image_context_ids"] = .array(imageSelections.filter { unavailable.contains($0.id) }.map { .string($0.id) })
        let data = JSONValue.object(metadata)
        let summary: JSONValue = .object(["type": .string("text"), "text": .string(try data.encodedText())])
        let imageBlocks = imageSelections.flatMap { images[$0.id] ?? [] }
        return .object(["content": .array([summary] + imageBlocks), "structuredContent": data, "isError": .bool(false)])
    }

    private func imageBlock(_ image: Data, contextID: String) -> JSONValue {
        .object(["type": .string("image"), "mimeType": .string("image/png"),
                 "data": .string(image.base64EncodedString()), "context_id": .string(contextID)])
    }

    private func resourceResult(_ value: JSONValue, uri: String) throws -> JSONValue {
        let text = try value.encodedText()
        return .object(["contents": .array([.object(["uri": .string(uri), "mimeType": .string("application/json"), "text": .string(text)])])])
    }

    private func resourcePaper(_ uri: String) throws -> Paper {
        let prefix = "paperdesk://reading-status"
        if uri == prefix { return try resolvePaper() }
        guard uri.hasPrefix(prefix + "/") else { throw PaperDeskError.missing("找不到阅读状态资源") }
        return try resolvePaper(id: String(uri.dropFirst(prefix.count + 1)))
    }

    private func execute(_ method: String, arguments: JSONValue) throws -> JSONValue {
        switch method {
        case "__mcp_client_connected":
            _ = try resolvePaper()
            return .object([:])
        case "__mcp_resources_list":
            let resources: [JSONValue]
            if let paper = try? resolvePaper() {
                resources = [.object(["uri": .string("paperdesk://reading-status/\(paper.id)"), "name": .string("Current reading state"), "title": .string(paper.title), "description": .string("Current page and selected PDF passages"), "mimeType": .string("application/json")])]
            } else {
                resources = []
            }
            return .object(["resources": .array(resources)])
        case "__mcp_resources_templates_list":
            return .object(["resourceTemplates": .array([.object(["uriTemplate": .string("paperdesk://reading-status/{paper_id}"), "name": .string("PaperDesk reading state"), "mimeType": .string("application/json")])])])
        case "__mcp_resources_read":
            guard let uri = arguments["uri"].stringValue else { throw PaperDeskError.invalid("缺少资源 URI") }
            let paper = try resourcePaper(uri)
            let state = try model.store.readingState(paperID: paper.id)
            let goal = try model.store.chatSession(paperID: paper.id).readingInstructions
            let value = try stateObject(state, paper: paper, readingGoal: goal, live: model.selectedPaper?.id == paper.id)
            return try resourceResult(value, uri: uri)
        case "__mcp_resource_revision":
            let paper = try resourcePaper(try required("uri", arguments, maximum: 512))
            let state = try model.store.readingState(paperID: paper.id)
            return .object(["paper_id": .string(paper.id), "updated_at": .number(state.updatedAt.timeIntervalSince1970),
                            "active": .bool(model.selectedPaper?.id == paper.id)])
        case "reading_status":
            let paper = try resolvePaper()
            if let pendingQuestion {
                return try result(try stateObject(pendingQuestion.snapshot.state, paper: paper,
                                                  readingGoal: pendingQuestion.snapshot.readingGoal,
                                                  live: model.selectedPaper?.id == paper.id))
            }
            let state = try model.store.readingState(paperID: paper.id)
            let goal = (try? model.store.chatSession(paperID: paper.id).readingInstructions) ?? ""
            return try result(try stateObject(state, paper: paper, readingGoal: goal, live: model.selectedPaper?.id == paper.id))
        case "capture_reading_state":
            let paper = try resolvePaper()
            if let pendingQuestion { return try snapshotResult(pendingQuestion.snapshot, paper: paper) }
            let state = try model.store.readingState(paperID: paper.id)
            let goal = (try? model.store.chatSession(paperID: paper.id).readingInstructions) ?? ""
            let snapshot = ReadingQuestionSnapshot(state: state, readingGoal: goal)
            let response = try snapshotResult(snapshot, paper: paper)
            try model.store.freezeReadingState(snapshot)
            // A new question ends the previous answer's citation view.
            model.clearCitationMarks()
            return response
        case "get_reading_snapshot":
            let id = try required("snapshot_id", arguments)
            guard let snapshot = try model.store.readingSnapshot(id: id) else { throw PaperDeskError.missing("找不到这份阅读状态快照") }
            let paper = try resolvePaper(id: snapshot.state.paperID)
            return try snapshotResult(snapshot, paper: paper)
        case "get_context":
            let context = try snapshot(id: required("context_id", arguments))
            return try contextResult(context, includeImage: arguments["include_image"].boolValue == true)
        case "cite_passage":
            if let pendingQuestion, arguments["snapshot_id"].stringValue != pendingQuestion.snapshot.id {
                throw PaperDeskError.conflict("请使用发送时固定的阅读快照来引用原文。")
            }
            return try citePassage(arguments)
        case "read_pages":
            let paper = try resolvePaper(id: arguments["paper_id"].stringValue)
            guard let values = arguments["page_indices"].arrayValue,
                  !values.isEmpty, values.count <= 10,
                  values.allSatisfy({ $0.intValue != nil }) else {
                throw PaperDeskError.invalid("请指定一至十个整数页码索引")
            }
            return try result(try readPages(paper: paper, pageIndices: values.compactMap(\.intValue)))
        case "save_discussion":
            let snapshotID = try required("snapshot_id", arguments)
            if let pendingQuestion, pendingQuestion.snapshot.id != snapshotID {
                throw PaperDeskError.conflict("请使用发送时固定的阅读快照来保存回答。")
            }
            let question = try pendingQuestion?.question ?? required("question", arguments, maximum: 20_000)
            let answer = try required("answer", arguments, maximum: 100_000)
            let key = try pendingQuestion?.archiveKey ?? required("idempotency_key", arguments, maximum: 256)
            let sourceIDs = try stringArray("source_context_ids", arguments, maximum: 32)
            var citations = try citationArray(arguments["citations"], maximum: 8)
            guard let snapshot = try model.store.readingSnapshot(id: snapshotID) else { throw PaperDeskError.missing("找不到这份阅读状态快照") }
            let paper = try resolvePaper(id: snapshot.state.paperID)
            let allowed = Set(snapshot.state.selections.map(\.id))
            guard Set(sourceIDs).isSubset(of: allowed) else { throw PaperDeskError.conflict("讨论引用了不属于这次阅读状态的选区") }
            let markerLabels = citationLabels(in: answer)
            if citations.isEmpty {
                guard markerLabels.isEmpty else {
                    throw PaperDeskError.conflict("回答包含出处编号，但没有提交对应的 citations。请一并提交每个 ⟦n⟧ 的出处。")
                }
            } else {
                let numbered = Dictionary(uniqueKeysWithValues: try model.store.snapshotCitations(snapshotID: snapshotID).map { ($0.context.id, $0) })
                var normalized: [MessageCitation] = []
                var seenContextIDs = Set<String>()
                for citation in citations {
                    guard seenContextIDs.insert(citation.contextID).inserted else {
                        throw PaperDeskError.invalid("citations 不能重复提交同一处原文。")
                    }
                    guard let row = numbered[citation.contextID] else {
                        throw PaperDeskError.conflict("讨论引用了不属于这份阅读状态的出处")
                    }
                    let expectedLabel = String(row.number)
                    guard citation.label == expectedLabel else {
                        throw PaperDeskError.conflict("出处 \(citation.contextID) 的编号应为 ⟦\(expectedLabel)⟧，实际收到 ⟦\(citation.label)⟧；请按 cite_passage 返回的编号提交。")
                    }
                    normalized.append(MessageCitation(contextID: citation.contextID, label: expectedLabel, pageLabel: row.context.pageLabel))
                }
                let citationLabels = Set(normalized.map(\.label))
                guard !markerLabels.isEmpty, markerLabels == citationLabels else {
                    throw PaperDeskError.conflict("回答中的出处编号必须与 citations 完全对应；请检查 ⟦n⟧ 标记和提交的出处列表。")
                }
                citations = normalized.sorted { (Int($0.label) ?? .max) < (Int($1.label) ?? .max) }
            }
            let previous = pendingQuestion == nil ? try optional("previous_discussion_id", arguments) : nil
            let archived = try model.store.appendDiscussion(paperID: paper.id, snapshotID: snapshotID, question: question, answer: answer, sourceContextIDs: sourceIDs, idempotencyKey: key, citations: citations,
                                                            origin: clientOrigin, manuallyRecorded: false, sharedWithAI: true,
                                                            conversationID: pendingQuestion?.conversationID ?? clientConversationID,
                                                            continuingFrom: previous)
            if let pendingQuestion { model.questions.recordArchive(requestID: pendingQuestion.id, messageID: archived.id) }
            if model.selectedPaper?.id == paper.id { model.refreshDiscussion() }
            return try result(.object(["saved": .bool(true), "message_id": .string(archived.id), "paper_id": .string(paper.id),
                                       "snapshot_id": .string(snapshotID), "source_context_ids": .array(sourceIDs.map(JSONValue.string)),
                                       "citation_context_ids": .array(citations.map { .string($0.contextID) }),
                                       "conversation_id": archived.conversationID.map(JSONValue.string) ?? .null,
                                       "origin": originObject(archived.origin)]))
        case "set_reading_goal":
            let paper = try resolveCurrentPaper(id: arguments["paper_id"].stringValue)
            let goal = try required("goal", arguments, maximum: 12_000)
            var session = try model.store.chatSession(paperID: paper.id)
            session.readingInstructions = String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
            try model.store.saveChatSession(session, paperID: paper.id)
            if model.selectedPaper?.id == paper.id { model.refreshDiscussion() }
            model.synchronizeProjectFiles(paperID: paper.id)
            return try result(.object([
                "saved": .bool(true),
                "paper_id": .string(paper.id),
                "reading_goal": .string(session.readingInstructions)
            ]))
        case "list_notes":
            let paper = try resolveCurrentPaper(id: arguments["paper_id"].stringValue)
            // Preserve the historical preview of PDF annotation proposals.
            // New summary and reading note drafts only appear in the reader.
            let notes = try model.store.notes(paperID: paper.id).filter { note in
                let isAnnotationDraft = note.status == "draft" && (note.kind == nil || note.kind == "annotation")
                return noteIsReadable(note, paperID: paper.id, includeDrafts: isAnnotationDraft)
            }
            var remaining = 40_000
            var output: [JSONValue] = []
            for note in notes.prefix(100) {
                if remaining <= 0 { break }
                let text = String(note.content.prefix(remaining)); remaining -= text.count
                var object = try noteObject(note, paper: paper).objectValue ?? [:]
                object["content"] = .string(text)
                object["context_ids"] = object["source_context_ids"] ?? .array([])
                output.append(.object(object))
            }
            return try result(.object(["notes": .array(output), "human_notes_included": .bool(model.sharesNotes(forPaperID: paper.id)), "truncated": .bool(output.count < notes.count || remaining <= 0)]))
        case "search_discussions":
            let paper = try resolveCurrentPaper(id: arguments["paper_id"].stringValue)
            let query = String(arguments["query"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000) ?? "")
            let all = try discussionRecords(for: paper).filter { record in
                query.isEmpty || [record.question, record.answer, record.snapshotID]
                    .compactMap { $0 }
                    .contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }.sorted { $0.createdAt > $1.createdAt }
            let page = paged(all, arguments: arguments)
            return try result(.object([
                "paper": paperInfo(paper),
                "paper_id": .string(paper.id),
                "document_hash": .string(paper.fileHash),
                "query": .string(query),
                "page": .number(Double(page.page)),
                "page_size": .number(Double(page.pageSize)),
                "total": .number(Double(all.count)),
                "has_more": .bool(page.hasMore),
                "next_page": page.hasMore ? .number(Double(page.page + 1)) : .null,
                "discussions": .array(page.pageValues.map { discussionSearchObject($0, query: query) })
            ]))
        case "get_discussion":
            let paper = try resolveCurrentPaper(id: arguments["paper_id"].stringValue)
            let id = try required("discussion_id", arguments, maximum: 512)
            guard let record = try discussionRecords(for: paper).first(where: { $0.id == id || $0.messages.contains(where: { $0.id == id }) }) else {
                throw PaperDeskError.missing("找不到这条讨论，或它尚未与当前 AI 连接共享")
            }
            let question = try recordFragment(record.question, offset: arguments["question_offset"], maximumBytes: 48_000)
            let answer = try recordFragment(record.answer, offset: arguments["answer_offset"], maximumBytes: 48_000)
            var detail = discussionObject(record, includeMessages: true).objectValue ?? [:]
            detail["question"] = question.text
            detail["answer"] = answer.text
            detail["question_next_offset"] = question.next
            detail["answer_next_offset"] = answer.next
            detail["question_truncated"] = .bool(question.next != .null)
            detail["answer_truncated"] = .bool(answer.next != .null)
            return try result(.object(detail))
        case "search_notes":
            let paper = try resolveCurrentPaper(id: arguments["paper_id"].stringValue)
            let query = String(arguments["query"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000) ?? "")
            let matching = try model.store.notes(paperID: paper.id).filter { note in
                guard noteIsReadable(note, paperID: paper.id) else { return false }
                guard !query.isEmpty else { return true }
                return [note.content, note.quote, note.kind, note.source, note.discussionID]
                    .compactMap { $0 }
                    .contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }
            let all = matching.sorted { $0.updatedAt > $1.updatedAt }
            let page = paged(all, arguments: arguments)
            return try result(.object([
                "paper": paperInfo(paper),
                "paper_id": .string(paper.id),
                "document_hash": .string(paper.fileHash),
                "query": .string(query),
                "page": .number(Double(page.page)),
                "page_size": .number(Double(page.pageSize)),
                "total": .number(Double(all.count)),
                "has_more": .bool(page.hasMore),
                "next_page": page.hasMore ? .number(Double(page.page + 1)) : .null,
                "notes": .array(try page.pageValues.map { try noteSearchObject($0, paper: paper, query: query) })
            ]))
        case "get_note":
            let paper = try resolveCurrentPaper(id: arguments["paper_id"].stringValue)
            let noteID = try required("note_id", arguments, maximum: 512)
            guard let note = try model.store.notes(paperID: paper.id).first(where: { $0.id == noteID && noteIsReadable($0, paperID: paper.id) }) else {
                throw PaperDeskError.missing("找不到这条笔记，或它尚未与当前 AI 连接共享")
            }
            let content = try recordFragment(note.content, offset: arguments["content_offset"], maximumBytes: 48_000)
            let quote = try recordFragment(note.quote, offset: arguments["quote_offset"], maximumBytes: 16_000)
            var detail = try noteObject(note, paper: paper, includeExtractiveSources: true).objectValue ?? [:]
            detail["content"] = content.text
            detail["quote"] = quote.text
            detail["content_next_offset"] = content.next
            detail["quote_next_offset"] = quote.next
            detail["content_truncated"] = .bool(content.next != .null)
            detail["quote_truncated"] = .bool(quote.next != .null)
            return try result(.object(detail))
        case "submit_note_draft":
            let paper = try resolveCurrentPaper(id: arguments["paper_id"].stringValue)
            let content = try required("content", arguments, maximum: 100_000)
            let key = try required("idempotency_key", arguments, maximum: 256)
            let explicitSnapshotID = try optional("snapshot_id", arguments, maximum: 512)
            let linkedDiscussionID = try optional("linked_discussion_id", arguments, maximum: 512)
            var sourceIDs = try stringArray("source_context_ids", arguments, maximum: 256, required: false)
            if sourceIDs.isEmpty {
                sourceIDs = try stringArray("context_ids", arguments, maximum: 256, required: false)
            }

            var linkedRecord: DiscussionRecord?
            if let linkedDiscussionID {
                guard let record = try discussionRecords(for: paper).first(where: { $0.id == linkedDiscussionID || $0.messages.contains(where: { $0.id == linkedDiscussionID }) }) else {
                    throw PaperDeskError.missing("找不到要关联的讨论，或该讨论尚未共享")
                }
                linkedRecord = record
                if sourceIDs.isEmpty { sourceIDs = record.sourceContextIDs }
            }
            sourceIDs = sourceIDs.reduce(into: [String]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }

            var snapshotValue: ReadingQuestionSnapshot?
            var snapshotID = explicitSnapshotID
            if let linkedSnapshot = linkedRecord?.snapshotID {
                if let explicitSnapshotID, explicitSnapshotID != linkedSnapshot {
                    throw PaperDeskError.conflict("笔记关联的讨论与 snapshot_id 不一致")
                }
                snapshotID = explicitSnapshotID ?? linkedSnapshot
            }
            if let snapshotID {
                guard let snapshot = try model.store.readingSnapshot(id: snapshotID),
                      snapshot.state.paperID == paper.id,
                      snapshot.state.documentHash == paper.fileHash else {
                    throw PaperDeskError.conflict("阅读快照不属于当前文献版本")
                }
                snapshotValue = snapshot
                // A linked discussion with no source contexts intentionally
                // remains page-anchored; do not silently turn it into a note
                // for every selection in the snapshot.
                if sourceIDs.isEmpty && linkedRecord == nil { sourceIDs = snapshot.state.selections.map(\.id) }
                let allowed = Set(snapshot.state.selections.map(\.id))
                guard Set(sourceIDs).isSubset(of: allowed) else {
                    throw PaperDeskError.conflict("笔记引用了不属于这份阅读快照的选区")
                }
            }

            let contexts = try sourceIDs.map { contextID -> ContextSnapshot in
                guard let context = try model.store.context(id: contextID),
                      context.paperID == paper.id,
                      context.documentHash == paper.fileHash else {
                    throw PaperDeskError.conflict("笔记引用了不属于当前文献版本的选区")
                }
                return context
            }
            let pageIndex: Int
            let pageLabel: String
            let quote: String
            if let first = contexts.first {
                pageIndex = first.pageIndex
                pageLabel = first.pageLabel
                quote = String(first.text.prefix(4_000))
            } else {
                let fallbackPage: Int
                if let snapshotPage = snapshotValue?.state.pageIndex {
                    fallbackPage = snapshotPage
                } else {
                    fallbackPage = try model.store.readingState(paperID: paper.id).pageIndex
                }
                let anchor = try pageAnchor(for: paper, pageIndex: fallbackPage)
                pageIndex = anchor.index
                pageLabel = anchor.label
                quote = ""
            }
            let note = ReadingNote(paperID: paper.id,
                                   contextID: contexts.first?.id,
                                   pageIndex: pageIndex,
                                   pageLabel: pageLabel,
                                   quote: quote,
                                   content: content,
                                   source: "ai",
                                   status: "draft",
                                   origin: clientOrigin,
                                   kind: "note",
                                   discussionID: linkedDiscussionID)
            let saved = try model.store.insertAnchoredNote(note, contextIDs: sourceIDs, idempotencyKey: key)
            if model.selectedPaper?.id == paper.id { model.refreshNotes() }
            model.synchronizeProjectFiles(paperID: paper.id)
            return try result(.object([
                "saved": .bool(true),
                "note": try noteObject(saved, paper: paper),
                "note_id": .string(saved.id),
                "paper_id": .string(paper.id),
                "source_context_ids": .array(sourceIDs.map(JSONValue.string)),
                "snapshot_id": snapshotID.map(JSONValue.string) ?? .null,
                "linked_discussion_id": linkedDiscussionID.map(JSONValue.string) ?? .null,
                "status": .string(saved.status),
                "draft": .bool(saved.status == "draft")
            ]))
        case "search_library":
            let query = try required("query", arguments)
            let all = try model.store.papers()
            let papers = all.filter { paper in
                (boundPaperID == nil || paper.id == boundPaperID) && (paper.title.localizedCaseInsensitiveContains(query) || paper.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }))
            }
            return try result(.object(["papers": .array(papers.prefix(50).map(paperInfo)), "truncated": .bool(papers.count > 50)]))
        case "navigate_to_source":
            let context = try snapshot(id: required("context_id", arguments))
            model.showSelection(context)
            return try result(.object(["navigated": .bool(true), "paper_id": .string(context.paperID), "context_id": .string(context.id), "page_index": .number(Double(context.pageIndex))]))
        case "extractive_candidates":
            let paper = try resolvePaper(id: arguments["paper_id"].stringValue)
            guard let values = arguments["page_indices"].arrayValue, !values.isEmpty, values.count <= 10,
                  values.allSatisfy({ $0.intValue != nil }) else { throw PaperDeskError.invalid("请指定一至十个整数页码索引") }
            let cursor = arguments["cursor"].intValue ?? 0
            guard cursor >= 0 else { throw PaperDeskError.invalid("cursor 无效") }
            let pages = try pdfPages(paper: paper, indices: values.compactMap(\.intValue))
            let candidates = pages.flatMap { page in ExtractiveSummary.candidates(pageIndex: page.index, pageLabel: page.label, text: page.text) }
            let pageSlice = Array(candidates.dropFirst(cursor).prefix(100))
            let next: JSONValue = cursor + pageSlice.count < candidates.count ? .number(Double(cursor + pageSlice.count)) : .null
            return try result(.object(["paper_id": .string(paper.id), "document_hash": .string(paper.fileHash), "candidates": .array(pageSlice.map { .object(["id": .string($0.id), "page_index": .number(Double($0.pageIndex)), "page_label": .string($0.pageLabel), "text": .string($0.text)]) }), "next_cursor": next, "truncated": .bool(next != .null)]))
        case "save_extractive_summary":
            let paper = try resolvePaper(id: required("paper_id", arguments))
            let hash = try required("document_hash", arguments)
            guard hash == paper.fileHash else { throw PaperDeskError.conflict("PDF 版本已变化，请重新读取原文") }
            let ids = try stringArray("candidate_ids", arguments, maximum: 100)
            let key = try required("idempotency_key", arguments, maximum: 256)
            var pageIndices = Set<Int>()
            for id in ids {
                guard let page = pageFromCandidateID(id) else { throw PaperDeskError.invalid("原文编号无效：\(id)") }
                pageIndices.insert(page)
            }
            let candidates = try pdfPages(paper: paper, indices: pageIndices.sorted()).flatMap { page in ExtractiveSummary.candidates(pageIndex: page.index, pageLabel: page.label, text: page.text) }
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            guard Set(ids).count == ids.count, ids.allSatisfy({ byID[$0] != nil }) else { throw PaperDeskError.conflict("原文编号不存在或重复，请重新读取候选句") }
            let sources = ids.compactMap { byID[$0] }
            let coverage = try extractionCoverage(paper: paper)
            let note = try model.store.recordExtractiveSummary(paperID: paper.id, documentHash: hash, sources: sources, coverage: coverage,
                                                               origin: clientOrigin, status: "draft")
            if model.selectedPaper?.id == paper.id { model.refreshNotes() }
            model.synchronizeProjectFiles(paperID: paper.id)
            return try result(.object(["saved": .bool(true), "note_id": .string(note.id), "paper_id": .string(paper.id),
                                       "source_count": .number(Double(sources.count)),
                                       "pages": .array(pageIndices.sorted().map { .number(Double($0)) }),
                                       "idempotency_key": .string(key), "status": .string(note.status),
                                       "kind": .string(note.kind ?? "excerpt")]))
        default:
            throw PaperDeskError.invalid("不支持的阅读操作")
        }
    }

    /// Only prose can display links. Formula delimiters and nonnumeric double
    /// brackets may be part of the author's notation.
    private func citationLabels(in answer: String) -> Set<String> {
        var labels = Set<String>()
        for block in LatexDocument.blocks(answer) {
            guard case .inline(let parts) = block else { continue }
            for part in parts {
                guard case .text(let text) = part else { continue }
                var rest = text[...]
                while let open = rest.firstIndex(of: "⟦"), let close = rest[open...].firstIndex(of: "⟧") {
                    let label = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty, label.utf8.allSatisfy({ (48...57).contains($0) }) {
                        labels.insert(label)
                    }
                    rest = rest[rest.index(after: close)...]
                }
            }
        }
        return labels
    }

    /// An external client may finish successfully without calling save_discussion.
    /// Preserve its reply and any numbered sources actually created for this turn.
    func archiveQuestionFallback(_ request: PendingPaperQuestion, answer: String) throws {
        let labels = citationLabels(in: answer)
        let rows = try model.store.snapshotCitations(snapshotID: request.snapshot.id)
        let citations = rows.filter { labels.contains(String($0.number)) }.map {
            MessageCitation(contextID: $0.context.id, label: String($0.number), pageLabel: $0.context.pageLabel)
        }
        guard citations.count == labels.count else {
            throw PaperDeskError.conflict("回答中的出处缺少对应位置，草稿已保留。")
        }
        _ = try model.store.appendDiscussion(paperID: request.paperID, snapshotID: request.snapshot.id,
                                             question: request.question, answer: answer, sourceContextIDs: [],
                                             idempotencyKey: request.archiveKey, citations: citations,
                                             origin: RecordOrigin(clientName: request.displayName), sharedWithAI: true,
                                             conversationID: request.conversationID)
    }

    private func citationArray(_ value: JSONValue?, maximum: Int) throws -> [MessageCitation] {
        guard let value, value != .null else { return [] }
        guard let values = value.arrayValue, values.count <= maximum else {
            throw PaperDeskError.invalid("citations 参数无效或超过上限")
        }
        let citations = try values.map { item in
            guard let contextID = item["context_id"].stringValue,
                  let label = item["label"].stringValue,
                  !contextID.isEmpty, contextID.count <= 512,
                  !label.isEmpty, label.count <= 16 else {
                throw PaperDeskError.invalid("citations 含有无效项目")
            }
            return MessageCitation(contextID: contextID, label: label)
        }
        guard Set(citations.map(\.contextID)).count == citations.count else {
            throw PaperDeskError.invalid("citations 不能重复提交同一处原文")
        }
        return citations
    }

    private func stringArray(_ key: String, _ arguments: JSONValue, maximum: Int, required: Bool = true) throws -> [String] {
        guard let values = arguments[key].arrayValue else {
            if !required { return [] }
            throw PaperDeskError.invalid("缺少或无效的参数：\(key)")
        }
        guard values.count <= maximum else { throw PaperDeskError.invalid("参数 \(key) 太长") }
        let strings = values.compactMap(\.stringValue)
        guard strings.count == values.count, strings.allSatisfy({ !$0.isEmpty && $0.count <= 512 }) else { throw PaperDeskError.invalid("参数 \(key) 含有无效项目") }
        return strings
    }

    private struct PDFPageText {
        var index: Int
        var label: String
        var text: String
    }

    private func pdfDocument(for paper: Paper) throws -> PDFDocument {
        let url = model.store.pdfURL(for: paper)
        guard let document = PDFDocument(url: url) else { throw PaperDeskError.missing("无法打开这篇 PDF") }
        return document
    }

    private func citePassage(_ arguments: JSONValue) throws -> JSONValue {
        let snapshotID = try required("snapshot_id", arguments, maximum: 512)
        guard let snapshot = try model.store.readingSnapshot(id: snapshotID) else {
            throw PaperDeskError.missing("找不到这份阅读状态快照")
        }
        let paper = try resolvePaper(id: snapshot.state.paperID)
        let hash = try optional("document_hash", arguments)
        if let hash, hash != paper.fileHash { throw PaperDeskError.conflict("PDF 版本已变化，请重新读取文献。") }
        guard snapshot.state.documentHash == paper.fileHash else {
            throw PaperDeskError.conflict("这份阅读状态对应的 PDF 版本已经变化")
        }
        guard let pageIndex = arguments["page_index"].intValue, (0..<paper.pageCount).contains(pageIndex) else {
            throw PaperDeskError.invalid("引用所在的 PDF 页码无效。")
        }
        let quote = try optional("quote", arguments, maximum: 1_200)
        let hasRegion = arguments["region"] != .null
        guard (quote != nil) != hasRegion else {
            throw PaperDeskError.invalid("原句和矩形坐标只能指定一种。")
        }
        try checkPageScope(paper: paper, indices: [pageIndex])
        let existing = try model.store.snapshotCitations(snapshotID: snapshotID)
        let document = try pdfDocument(for: paper)
        guard let page = document.page(at: pageIndex) else { throw PaperDeskError.missing("找不到引用所在的 PDF 页。") }

        let target: ContextSnapshot
        let image: Data?
        if let quote {
            target = try focusForQuote(quote, page: page, in: document, paper: paper)
            image = nil
        } else {
            let rect = try focusRect(arguments["region"], on: page)
            let region = PageRegion(pageIndex: pageIndex, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            let text = page.selection(for: rect)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            target = ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash, pageIndex: pageIndex,
                                     pageLabel: page.label ?? String(pageIndex + 1), text: text, regions: [region])
            image = try PDFRegionRenderer.render(page: page, bounds: rect)
        }

        // Retrying the same passage reuses its footnote instead of consuming
        // the next number.
        if let duplicate = existing.first(where: {
            $0.context.pageIndex == target.pageIndex &&
                $0.context.regions == target.regions &&
                $0.context.sourceText == target.sourceText
        }) {
            return try result(citationObject(duplicate, paper: paper))
        }
        guard existing.count < 8 else {
            throw PaperDeskError.invalid("每条回答最多引用 8 处原文")
        }
        let saved = try model.store.saveContext(target, imageData: image)
        let citation = try model.store.addSnapshotCitation(snapshotID: snapshotID, contextID: saved.id, maximum: 8)
        return try result(citationObject(citation, paper: paper))
    }

    private func citationObject(_ citation: SnapshotCitation, paper: Paper) -> JSONValue {
        .object([
            "citation_id": .string(citation.context.id),
            "number": .number(Double(citation.number)),
            "label": .string(String(citation.number)),
            "page_index": .number(Double(citation.context.pageIndex)),
            "page_label": .string(citation.context.pageLabel),
            "quote": .string(String(citation.context.sourceText.prefix(4_000))),
            "paper": paperInfo(paper)
        ])
    }

    private func focusForQuote(_ quote: String, page: PDFPage, in document: PDFDocument, paper: Paper) throws -> ContextSnapshot {
        guard let text = page.string as NSString? else { throw PaperDeskError.missing("该页没有可匹配的 PDF 原文。") }
        let range = text.range(of: quote, options: .literal)
        guard range.location != NSNotFound, NSMaxRange(range) <= page.numberOfCharacters else {
            throw PaperDeskError.missing("在指定页找不到这段原文。")
        }
        let remainder = NSRange(location: range.location + 1, length: text.length - range.location - 1)
        guard text.range(of: quote, options: .literal, range: remainder).location == NSNotFound else {
            throw PaperDeskError.conflict("原句在该页出现多次，请提供更完整的原文或指定矩形。")
        }
        guard let selection = page.selection(for: range), selection.string == quote,
              let context = AppModel.textSelectionContext(selection, in: document, paper: paper) else {
            throw PaperDeskError.missing("无法把这段原文精确定位到页面。")
        }
        return context
    }

    private func focusRect(_ value: JSONValue, on page: PDFPage) throws -> CGRect {
        let fields = ["x", "y", "width", "height"].compactMap { key -> Double? in
            guard case let .number(number) = value[key], number.isFinite else { return nil }
            return number
        }
        guard fields.count == 4, fields[2] >= 4, fields[3] >= 4 else {
            throw PaperDeskError.invalid("请提供能定位引用的原句或有效的页内矩形。")
        }
        let rect = CGRect(x: fields[0], y: fields[1], width: fields[2], height: fields[3])
        guard page.bounds(for: .cropBox).contains(rect) else { throw PaperDeskError.invalid("矩形超出指定的 PDF 页面范围。") }
        return rect
    }

    private func pdfPages(paper: Paper, indices: [Int]) throws -> [PDFPageText] {
        try checkPaper(paper)
        let document = try pdfDocument(for: paper)
        var result: [PDFPageText] = []
        for index in Array(Set(indices)).sorted() {
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { throw PaperDeskError.invalid("页码超出文献范围：\(index + 1)") }
            result.append(PDFPageText(index: index, label: page.label ?? String(index + 1), text: String((page.string ?? "").prefix(40_000))))
        }
        return result
    }

    private func extractionCoverage(paper: Paper) throws -> ExtractiveCoverage {
        let document = try pdfDocument(for: paper)
        var textPages: [Int] = []
        var unavailable: [Int] = []
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { unavailable.append(index) } else { textPages.append(index) }
        }
        return ExtractiveCoverage(textPageIndices: textPages, unavailablePageIndices: unavailable)
    }

    private func checkPageScope(paper: Paper, indices: [Int]) throws {
        switch model.scope(forPaperID: paper.id) {
        case .selection:
            throw PaperDeskError.invalid("当前范围为“仅选区”，请使用阅读状态快照或固定选区")
        case .page:
            let pageIndex = try pendingQuestion?.snapshot.state.pageIndex ?? model.store.readingState(paperID: paper.id).pageIndex
            guard indices.allSatisfy({ $0 == pageIndex }) else { throw PaperDeskError.invalid("当前范围为“当前页”，只能读取当前页") }
        case .document:
            break
        }
    }

    private func readPages(paper: Paper, pageIndices: [Int]) throws -> JSONValue {
        let scope = model.scope(forPaperID: paper.id)
        try checkPageScope(paper: paper, indices: pageIndices)
        let pages = try pdfPages(paper: paper, indices: pageIndices)
        var total = 0
        var truncated = false
        var values: [JSONValue] = []
        for page in pages {
            let remaining = max(0, 40_000 - total)
            let text = String(page.text.prefix(remaining))
            total += text.count
            truncated = truncated || text.count < page.text.count
            values.append(.object(["pageIndex": .number(Double(page.index)), "pageLabel": .string(page.label), "text": .string(text), "truncated": .bool(text.count < page.text.count)]))
            if total >= 40_000 { break }
        }
        return .object(["paperID": .string(paper.id), "scope": .string(scope.rawValue), "pages": .array(values), "truncated": .bool(truncated)])
    }

    private func pageFromCandidateID(_ id: String) -> Int? {
        guard id.first == "P", let separator = id.firstIndex(of: "S") else { return nil }
        let page = String(id[id.index(after: id.startIndex)..<separator])
        guard let oneBased = Int(page), oneBased > 0 else { return nil }
        return oneBased - 1
    }
}
