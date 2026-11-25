import Combine
import Foundation
import PaperDeskCore

struct PaperQuestionTarget: Identifiable, Equatable {
    var id: String { "\(clientID)|\(project.path)|\(conversationID ?? "new")" }
    let clientID: String
    let displayName: String
    let iconName: String
    let title: String
    let project: URL
    let conversationID: String?
    let externalSessionID: String?
    let legacyMessageIDs: [String]
    var readingRecordID: String? {
        guard let conversationID else { return nil }
        return legacyMessageIDs.isEmpty ? "conversation:" + conversationID : conversationID
    }
    var isKnownConversation: Bool { conversationID != nil }
    var needsManualSessionBinding: Bool { isKnownConversation && externalSessionID == nil }

    func bindingSession(_ externalID: String) -> PaperQuestionTarget {
        let id = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = QuestionClientRegistry.adapter(id: clientID)?.normalize(sessionID: id) ?? id
        return PaperQuestionTarget(clientID: clientID, displayName: displayName, iconName: iconName,
                                   title: title, project: project, conversationID: conversationID,
                                   externalSessionID: normalized,
                                   legacyMessageIDs: legacyMessageIDs)
    }
}

struct PaperQuestionTargets {
    let active: PaperQuestionTarget?
    let choices: [PaperQuestionTarget]
    let activeUnavailableReason: String?
    let connectedClients: [MCPClientConnection]
    let hasProject: Bool
}

struct PendingPaperQuestion {
    let id: String
    let question: String
    let snapshot: ReadingQuestionSnapshot
    let conversationID: String
    let readingRecordID: String?
    let legacyMessageIDs: [String]
    let clientID: String
    let displayName: String
    let externalSessionID: String?

    var archiveKey: String { "paperdesk-question-" + id }
    var paperID: String { snapshot.state.paperID }
    var documentHash: String { snapshot.state.documentHash }
}

@MainActor
final class PaperQuestions: ObservableObject {
    @Published var drafts: [String: String] = [:]
    @Published private(set) var runningPaperIDs: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var completedConversationIDs: [String: String] = [:]
    private var pending: [String: PendingPaperQuestion] = [:]
    private var archived: [String: String] = [:]

    func request(id: String) -> PendingPaperQuestion? { pending[id] }

    func recordArchive(requestID: String, messageID: String) {
        archived[requestID] = messageID
    }

    func acknowledge(paperID: String) {
        completedConversationIDs.removeValue(forKey: paperID)
    }

    @discardableResult
    func send(_ text: String, to target: PaperQuestionTarget, in model: AppModel) -> Bool {
        guard let paper = model.selectedPaper, !runningPaperIDs.contains(paper.id) else { return false }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        do {
            guard question.count <= 20_000 else { throw PaperDeskError.invalid(L("问题最多可输入 20,000 个字符。")) }
            guard let adapter = QuestionClientRegistry.adapter(id: target.clientID) else {
                throw PaperDeskError.invalid(L("不支持的客户端类型：\(target.displayName)。", "Unsupported client type: \(target.displayName)."))
            }
            guard adapter.isAvailable() else {
                throw PaperDeskError.missing(L("找不到 \(target.displayName)。草稿已保留。", "\(target.displayName) could not be found. Your draft was kept."))
            }
            guard model.bridgeConnected else { throw PaperDeskError.missing(L("PaperDesk 的本机连接尚未启动。")) }
            let current = try model.questionTargets()
            guard let candidate = current.choices.first(where: { $0.id == target.id }),
                  candidate.externalSessionID == nil || candidate.externalSessionID == target.externalSessionID else {
                throw PaperDeskError.conflict(L("此发送目标已变化，请重新选择。"))
            }
            if let conversationID = target.conversationID {
                guard let id = target.externalSessionID, adapter.isValidSessionID(id) else {
                    throw PaperDeskError.invalid(L("请填写这条 \(target.displayName) 对话的有效会话编号。", "Enter a valid session ID for this \(target.displayName) conversation."))
                }
                if let binding = try model.store.questionBinding(backend: target.clientID, externalSessionID: id),
                   binding.paperID != paper.id || binding.conversationID != conversationID || binding.projectPath != target.project.path {
                    throw PaperDeskError.conflict(L("这个外部会话已经绑定另一条阅读记录。"))
                }
                guard !pending.values.contains(where: { $0.clientID == target.clientID && $0.externalSessionID == id }) else {
                    throw PaperDeskError.conflict(L("这个外部会话正处理另一条提问。"))
                }
            }
            let state = try model.store.readingState(paperID: paper.id)
            let snapshot = ReadingQuestionSnapshot(state: state, readingGoal: model.readingGoal)
            try model.store.freezeReadingState(snapshot)
            let request = PendingPaperQuestion(id: UUID().uuidString, question: question, snapshot: snapshot,
                                               conversationID: target.conversationID ?? "paperdesk-" + UUID().uuidString,
                                               readingRecordID: target.readingRecordID,
                                               legacyMessageIDs: target.legacyMessageIDs,
                                               clientID: target.clientID, displayName: target.displayName,
                                               externalSessionID: target.externalSessionID)
            let launch = try model.mcpLaunchConfiguration(bound: true, clientLabel: target.displayName)
            pending[request.id] = request
            errors.removeValue(forKey: paper.id)
            drafts[paper.id] = question
            runningPaperIDs.insert(paper.id)
            Task { await run(request, to: target, connector: launch, adapter: adapter, in: model) }
            return true
        } catch {
            drafts[paper.id] = text
            errors[paper.id] = error.localizedDescription
            return false
        }
    }

    private func run(_ request: PendingPaperQuestion, to target: PaperQuestionTarget,
                     connector: (command: String, arguments: [String]),
                     adapter: any QuestionClientAdapter, in model: AppModel) async {
        defer {
            pending.removeValue(forKey: request.id)
            archived.removeValue(forKey: request.id)
            runningPaperIDs.remove(request.paperID)
        }
        do {
            let reply = try await adapter.send(
                project: target.project, sessionID: target.externalSessionID,
                prompt: prompt(for: request), connector: connector.command,
                connectorArguments: connector.arguments + ["--question-request", request.id])
            let sessionID = adapter.normalize(sessionID: reply.sessionID)
            guard adapter.isValidSessionID(sessionID),
                  target.externalSessionID == nil || target.externalSessionID == sessionID else {
                throw PaperDeskError.conflict(L("客户端返回了不同的会话，无法绑定这次提问。"))
            }
            if archived[request.id] == nil {
                try ReaderTools(model: model).archiveQuestionFallback(request, answer: reply.answer)
            }
            if !request.legacyMessageIDs.isEmpty {
                try model.store.assignLegacyConversationID(paperID: request.paperID, messageIDs: request.legacyMessageIDs,
                                                           conversationID: request.conversationID)
            }
            let binding = QuestionBinding(paperID: request.paperID, conversationID: request.conversationID,
                                          backend: request.clientID, projectPath: target.project.path,
                                          externalSessionID: sessionID)
            try model.store.saveQuestionBinding(binding)
            if let title = reply.conversationTitle {
                _ = try? model.store.synchronizeExternalConversationTitle(binding: binding, title: title)
            }
            if let oldRecordID = request.readingRecordID, model.activeReadingConversationID == oldRecordID {
                model.activeReadingConversationID = "conversation:" + request.conversationID
            }
            finish(request)
        } catch {
            if archived[request.id] != nil { finish(request) }
            errors[request.paperID] = error.localizedDescription
        }
        if model.selectedPaper?.id == request.paperID { model.refreshDiscussion() }
    }

    private func finish(_ request: PendingPaperQuestion) {
        if drafts[request.paperID] == request.question { drafts.removeValue(forKey: request.paperID) }
        completedConversationIDs[request.paperID] = "conversation:" + request.conversationID
    }

    private func prompt(for request: PendingPaperQuestion) -> String {
        """
        This question was sent from PaperDesk. The reader froze snapshot \(request.snapshot.id) at send time. Call PaperDesk capture_reading_state to get that fixed snapshot and use it for citations. Archive the original question and the final answer with save_discussion on that snapshot. Use the actual referenced context IDs.

        User's question:
        \(request.question)
        """
    }
}

extension AppModel {
    func questionTargets() throws -> PaperQuestionTargets {
        guard let paper = selectedPaper else {
            return PaperQuestionTargets(active: nil, choices: [], activeUnavailableReason: nil,
                                        connectedClients: [], hasProject: false)
        }
        let bindings = try store.questionBindings(paperID: paper.id)
        let project = try CodexPaperProject.existing(paper: paper, library: store.rootURL)?.standardizedFileURL
        refreshDetectedMCPProcesses()
        let connected = connectedClients(forPaperID: paper.id)
        let connectedIDs = Set(connected.compactMap(\.clientID))
        let availableIDs = Set(QuestionClientRegistry.adapters.filter { $0.isAvailable() }.map(\.id))
        let conversations = ConversationGrouping.group(discussion)

        func makeTarget(clientID: String, title: String, project: URL,
                        conversationID: String?, externalSessionID: String?,
                        legacyMessageIDs: [String]) -> PaperQuestionTarget? {
            guard connectedIDs.contains(clientID), availableIDs.contains(clientID),
                  let adapter = QuestionClientRegistry.adapter(id: clientID) else { return nil }
            return PaperQuestionTarget(clientID: clientID, displayName: adapter.displayName,
                                       iconName: adapter.iconName, title: title, project: project,
                                       conversationID: conversationID, externalSessionID: externalSessionID,
                                       legacyMessageIDs: legacyMessageIDs)
        }

        let existingTargets = conversations.compactMap { group -> PaperQuestionTarget? in
            guard !group.isManual else { return nil }
            if let binding = bindings.first(where: { $0.conversationID == group.stableConversationID }) {
                let url = URL(fileURLWithPath: binding.projectPath, isDirectory: true).standardizedFileURL
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
                return makeTarget(clientID: binding.backend, title: group.title, project: url,
                                  conversationID: binding.conversationID,
                                  externalSessionID: binding.externalSessionID,
                                  legacyMessageIDs: group.isLegacy ? group.messages.map(\.id) : [])
            }
            guard let project,
                  let adapter = QuestionClientRegistry.adapter(clientName: group.origin?.clientName ?? group.sourceLabel) else { return nil }
            return makeTarget(clientID: adapter.id, title: group.title, project: project,
                              conversationID: group.stableConversationID, externalSessionID: nil,
                              legacyMessageIDs: group.isLegacy ? group.messages.map(\.id) : [])
        }
        // Only the record the reader is currently continuing is offered as an
        // existing target, and only while its client is connected through MCP.
        let active = existingTargets.first { $0.readingRecordID == activeReadingConversationID && $0.isKnownConversation }
        let unavailable = conversations.first { $0.id == activeReadingConversationID }
        let reason: String?
        if active == nil, let unavailable {
            reason = L("「\(unavailable.title)」· \(unavailable.sourceLabel) 暂时不可用：客户端未通过 MCP 连接，或对应程序不可用。", "“\(unavailable.title)” · \(unavailable.sourceLabel) is unavailable: the client is not connected over MCP, or the program is unavailable.")
        } else {
            reason = nil
        }
        var choices: [PaperQuestionTarget] = []
        if let active {
            choices = [active]
        } else if let project {
            choices = QuestionClientRegistry.adapters
                .filter { connectedIDs.contains($0.id) && availableIDs.contains($0.id) }
                .map { adapter in
                    PaperQuestionTarget(clientID: adapter.id, displayName: adapter.displayName,
                                        iconName: adapter.iconName, title: L("新对话"), project: project,
                                        conversationID: nil, externalSessionID: nil, legacyMessageIDs: [])
                }
        }
        return PaperQuestionTargets(active: active, choices: choices, activeUnavailableReason: reason,
                                    connectedClients: connected, hasProject: project != nil)
    }

    func prepareQuestionProject() throws {
        guard let paper = selectedPaper else { throw PaperDeskError.missing(L("请先打开一篇文献。")) }
        let launch = try mcpLaunchConfiguration(bound: true, clientLabel: "PaperDesk")
        _ = try CodexPaperProject.create(paper: paper, projectName: paper.effectiveProjectName,
                                         library: store.rootURL, connector: URL(fileURLWithPath: launch.command))
        if (paper.projectName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? store.setProjectName(paperID: paper.id, name: paper.effectiveProjectName)
            refreshLibrary()
        }
        refreshCodexProjectStatus()
    }
}
