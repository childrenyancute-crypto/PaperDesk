import AppKit
import Combine
import Foundation
import ImageIO
import PDFKit
import PaperDeskCore
import PaperDeskStorage
import PaperDeskBridge
import SwiftUI
import SwiftMath

@MainActor
enum ReaderSelfCheck {
    static func checkMathFonts() throws {
        var inline = MathImage(latex: #"E_n \psi_n"#, fontSize: 16, textColor: .black, labelMode: .text)
        var display = MathImage(latex: #"\frac{\alpha_i^2}{\sqrt{x}} + \int_0^\infty e^{-t^2}\,dt"#,
                                fontSize: 18, textColor: .black, labelMode: .display)
        let (_, inlineImage, _) = inline.asImage()
        let (_, displayImage, _) = display.asImage()
        guard let inlineImage, let displayImage, inlineImage.size.width > 0,
              displayImage.size.height > inlineImage.size.height,
              displayImage.tiffRepresentation != nil else {
            throw PaperDeskError.invalid("无法用应用内公式字体排版 LaTeX。")
        }
        print("PASS: bundled fonts render native inline math and display fractions, scripts and integrals")
    }

    private static func projectFixture(at directory: URL) throws -> (AppModel, Paper) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Synthetic quantum reading sample.pdf")
        try SamplePDF.create(at: source)
        guard let preferences = UserDefaults(suiteName: "paperdesk.selfcheck." + directory.lastPathComponent) else {
            throw PaperDeskError.invalid("无法打开自检设置。")
        }
        let model = try AppModel(store: LibraryStore(rootURL: directory.appendingPathComponent("library")), preferences: preferences)
        model.openPDF(url: source)
        guard model.scope == .document else {
            throw PaperDeskError.invalid("新打开的文献未默认允许读取全文。")
        }
        model.scope = .selection
        guard let paper = model.selectedPaper, let pdf = model.document,
              let assumptions = pdf.findString("For a time-independent Hamiltonian", withOptions: []).first else {
            throw PaperDeskError.invalid("测试 PDF 的条件段落无法定位。")
        }
        let targets = [CGRect(x: 43, y: 533, width: 460, height: 25), CGRect(x: 43, y: 640, width: 460, height: 29)]
        for (index, bounds) in targets.enumerated() {
            guard let page = pdf.page(at: index) else { throw PaperDeskError.missing("缺少公式测试页。") }
            model.captureRegion(pageIndex: index, bounds: bounds, imageData: try PDFRegionRenderer.render(page: page, bounds: bounds))
        }
        model.captureSelection(assumptions, document: pdf)
        model.setReadingGoal("比较本征态关系和时间演化式，指出时不变条件。")
        let viewport = PageRegion(pageIndex: 1, x: 0, y: 300, width: 612, height: 460)
        model.recordDisplayedPage(1, visibleRegions: [viewport])
        guard model.activeSelections.map(\.label) == ["A", "B", "C"],
              model.activeSelections.map(\.context.pageIndex) == [0, 1, 1] else {
            throw PaperDeskError.invalid("跨页公式选区顺序或页码有误。")
        }
        return (model, paper)
    }

    static func serveProjectCheck(at directory: URL) throws {
        let (model, paper) = try projectFixture(at: directory)
        let connector = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("paperdesk-mcp")
        let project = try CodexPaperProject.create(paper: paper, library: model.store.rootURL, connector: connector)
        let service = ReaderTools(model: model)
        let server = LocalBridgeServer(socketURL: LibraryPaths.socket(root: model.store.rootURL)) { request in
            await MainActor.run { service.handle(request) }
        }
        try server.start()
        defer { server.stop() }
        print(project.path)
        fflush(stdout)
        RunLoop.main.run()
    }

    static func checkReferenceRendering() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/pdr-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, paper) = try projectFixture(at: directory)
        model.clearSelections()
        model.scope = .document
        let bibliography = [
            PaperReferenceDraft(label: "7", entryIndex: 0, authors: "Smith, J.", firstAuthor: "Smith",
                                title: "A verified earlier result", year: 2020, venue: "Journal of Examples",
                                doi: nil, arxivID: nil, url: nil, rawText: "[7] Smith, J. (2020). A verified earlier result.",
                                pageIndex: 1, pageLabel: "2", fingerprint: "self-check-reference-7"),
            PaperReferenceDraft(label: "8", entryIndex: 1, authors: "Doe, A.", firstAuthor: "Doe",
                                title: "A second result", year: 2021, venue: "Journal of Examples",
                                doi: nil, arxivID: nil, url: nil, rawText: "[8] Doe, A. (2021). A second result.",
                                pageIndex: 1, pageLabel: "2", fingerprint: "self-check-reference-8")
        ]
        try model.store.replacePDFBibliography(paperID: paper.id, entries: bibliography,
                                                headingPageIndex: 1, parserVersion: PaperReferenceParser.version)
        model.refreshReferences()
        let groupedReferences = PaperReferenceMentions.snapshots(
            in: "Prior work [7, 8] and [7–8] support the setup. Array a[8] and code `[7]` remain ordinary text.",
            references: model.references)
        guard Set(groupedReferences.map(\.label)) == Set(["7", "8"]) else {
            throw PaperDeskError.invalid("合并参考文献编号或代码中的方括号识别有误。")
        }
        let reader = ReaderTools(model: model)
        func call(_ method: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
            let result = reader.handle(BridgeRequest(method: method, arguments: .object(arguments))).result
            guard result?["isError"].boolValue == false, let body = result?["structuredContent"] else {
                throw PaperDeskError.invalid("引用自检调用失败：\(method)")
            }
            return body
        }
        let input = "公式 $x_1$ 中，原文写道“Let H be a Hermitian operator”，并引用文献 [7]。\n另有 10.1000/182。\n“这段虚构文字不能生成标记”。\n源码样例 `“这条代码里的假引文不能生成标记”`。\n文献 [999] 尚未匹配。"
        guard let snapshotID = try call("capture_reading_state")["snapshot_id"].stringValue else {
            throw PaperDeskError.invalid("缺少引用自检快照。")
        }
        var arguments: [String: JSONValue] = [
            "snapshot_id": .string(snapshotID), "question": .string("请对照原文。"), "answer": .string(input),
            "source_context_ids": .array([]), "idempotency_key": .string("reference-rendering")
        ]
        let saved = try call("save_discussion", arguments)
        let expected = input
            .replacingOccurrences(of: "operator”", with: "operator”⟦1⟧")
            .replacingOccurrences(of: "10.1000/182", with: "[10.1000/182](https://doi.org/10.1000/182)")
        guard saved["rendered_answer"].stringValue == expected,
              let message = model.discussion.last, message.text == expected,
              message.citations?.count == 1,
              message.referencedWorks?.map(\.label) == ["7"],
              message.referencedWorks?.first?.title == "A verified earlier result",
              message.citationWarnings?.contains(where: { $0.contains("[999]") }) == true else {
            throw PaperDeskError.invalid("引用渲染改变了正文或没有补齐可验证的引用。")
        }
        let savedMessageID = message.id
        model.activateCitations(for: message)
        guard model.activeCitationMarks.contains(where: { $0.regions.contains { $0.pageIndex == 0 } }),
              try model.store.snapshotCitations(snapshotID: snapshotID).count == 1 else {
            throw PaperDeskError.invalid("引用渲染没有保存跨页位置。")
        }
        try model.store.replacePDFBibliography(paperID: paper.id,
                                                entries: [PaperReferenceDraft(label: "7", entryIndex: 0,
                                                                               authors: "Other, A.", firstAuthor: "Other",
                                                                               title: "A changed directory entry", year: 2030,
                                                                               venue: nil, doi: nil, arxivID: nil, url: nil,
                                                                               rawText: "[7] Other, A. (2030). A changed directory entry.",
                                                                               pageIndex: 1, pageLabel: "2", fingerprint: "self-check-reference-7-updated")],
                                                headingPageIndex: 1, parserVersion: PaperReferenceParser.version)
        model.refreshReferences()
        guard model.discussion.first(where: { $0.id == savedMessageID })?.referencedWorks?.first?.title == "A verified earlier result" else {
            throw PaperDeskError.invalid("重建目录后，旧回答的参考文献链接发生变化。")
        }
        arguments["render_references"] = .bool(false)
        arguments["idempotency_key"] = .string("reference-rendering-disabled")
        guard try call("save_discussion", arguments)["rendered_answer"] == .null,
              model.discussion.last?.text == input,
              model.discussion.last?.referencedWorks?.isEmpty == true,
              model.scope(forPaperID: paper.id) == .document else {
            throw PaperDeskError.invalid("关闭引用渲染后仍修改了答案。")
        }
        var longAnswerArguments = arguments
        longAnswerArguments["render_references"] = .bool(true)
        longAnswerArguments["answer"] = .string("第一段说明一个结果。\n\n第二段解释这个结果。\n\n第三段继续讨论条件。")
        longAnswerArguments["idempotency_key"] = .string("long-answer-without-citations")
        let longAnswer = try call("save_discussion", longAnswerArguments)
        guard longAnswer["citation_warnings"].arrayValue?.contains(where: { $0.stringValue?.contains("漏标") == true }) == true,
              model.discussion.last?.citationWarnings?.isEmpty == false else {
            throw PaperDeskError.invalid("长回答缺少原文标记时没有显示核对提示。")
        }

        model.clearSelections()
        guard let document = model.document,
              let firstPassage = document.findString("Let H be a Hermitian operator", withOptions: []).first,
              let secondPassage = document.findString("For a time-independent Hamiltonian", withOptions: []).first else {
            throw PaperDeskError.invalid("无法准备正文引用顺序测试。")
        }
        model.captureSelection(firstPassage, document: document)
        model.captureSelection(secondPassage, document: document)
        guard let orderSnapshotID = try call("capture_reading_state")["snapshot_id"].stringValue,
              let snapshot = try model.store.readingSnapshot(id: orderSnapshotID),
              snapshot.state.selections.count == 2 else {
            throw PaperDeskError.invalid("正文引用顺序测试缺少两处选区。")
        }
        var orderCitations: [[String: JSONValue]] = []
        for selection in snapshot.state.selections {
            let created = try call("cite_passage", ["snapshot_id": .string(orderSnapshotID),
                                                       "selection_context_id": .string(selection.id)])
            guard let contextID = created["citation_id"].stringValue,
                  let label = created["label"].stringValue else {
                throw PaperDeskError.invalid("无法创建正文引用顺序测试出处。")
            }
            orderCitations.append(["context_id": .string(contextID), "label": .string(label)])
        }
        let outOfOrderAnswer = "先解释第二处原文⟦2⟧，再回到第一处原文⟦1⟧。"
        let normalizedOrder = try call("save_discussion", [
            "snapshot_id": .string(orderSnapshotID), "question": .string("检查引用编号顺序。"),
            "answer": .string(outOfOrderAnswer), "source_context_ids": .array([]),
            "citations": .array(orderCitations.map(JSONValue.object)),
            "idempotency_key": .string("citation-order-normalization")
        ])
        let expectedOrder = "先解释第二处原文⟦1⟧，再回到第一处原文⟦2⟧。"
        guard normalizedOrder["rendered_answer"].stringValue == expectedOrder,
              model.discussion.last?.citations?.map(\.label) == ["1", "2"],
              model.discussion.last?.citationWarnings?.contains(where: { $0.contains("正文首次出现顺序") }) == true else {
            throw PaperDeskError.invalid("正文引用没有按首次出现顺序整理并提示核对。")
        }

        model.clearSelections()
        guard let capacitySnapshotID = try call("capture_reading_state")["snapshot_id"].stringValue else {
            throw PaperDeskError.invalid("缺少 32 处引用上限测试快照。")
        }
        var capacityCitations: [[String: JSONValue]] = []
        for index in 0..<32 {
            let region: JSONValue = .object([
                "x": .number(24), "y": .number(Double(24 + index * 12)),
                "width": .number(8), "height": .number(8)
            ])
            let created = try call("cite_passage", ["snapshot_id": .string(capacitySnapshotID),
                                                       "page_index": .number(0), "region": region])
            guard let contextID = created["citation_id"].stringValue,
                  let label = created["label"].stringValue else {
                throw PaperDeskError.invalid("无法建立第 \(index + 1) 个测试出处。")
            }
            capacityCitations.append(["context_id": .string(contextID), "label": .string(label)])
        }
        let overflowRequest = BridgeRequest(method: "cite_passage", arguments: .object([
            "snapshot_id": .string(capacitySnapshotID), "page_index": .number(0),
            "region": .object(["x": .number(24), "y": .number(420), "width": .number(8), "height": .number(8)])
        ]))
        guard reader.handle(overflowRequest).result?["isError"].boolValue == true else {
            throw PaperDeskError.invalid("第 33 处原文引用没有遵守容量限制。")
        }
        let capacityAnswer = (1...32).map { "结论 \($0)⟦\($0)⟧" }.joined(separator: "，")
        _ = try call("save_discussion", [
            "snapshot_id": .string(capacitySnapshotID), "question": .string("检查长回答引用上限。"),
            "answer": .string(capacityAnswer), "source_context_ids": .array([]),
            "citations": .array(capacityCitations.map { JSONValue.object($0) }),
            "idempotency_key": .string("citation-capacity-32")
        ])
        guard model.discussion.last?.citations?.count == 32 else {
            throw PaperDeskError.invalid("32 处可跳转原文不能完整归档。")
        }
        print("PASS: mixed citations remain linked, warnings persist, history stays fixed, footnotes follow text order, and 32 source marks save")
    }

    static func checkLiveQuestion(clientID: String) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/pdl-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, paper) = try projectFixture(at: directory)
        model.scope = .document
        model.clearSelections()
        try model.prepareQuestionProject()
        let service = ReaderTools(model: model)
        let server = LocalBridgeServer(socketURL: LibraryPaths.socket(root: model.store.rootURL)) { request in
            await service.handleWithProgress(request)
        }
        try server.start()
        defer { server.stop() }
        model.bridgeConnected = true
        model.recordClientConnection(connectionID: "live-check", paperID: paper.id, documentHash: paper.fileHash,
                                     clientName: clientID, clientVersion: nil)
        guard let target = try model.questionTargets().choices.first(where: { $0.clientID == clientID }) else {
            throw PaperDeskError.missing("无法启动指定的测试客户端。")
        }
        let start = Date()
        var previous: PaperQuestionStage?
        let observer = model.questions.$progressByPaperID.sink { values in
            if let stage = values[paper.id]?.stage, stage != previous {
                previous = stage
                print(String(format: "%.2fs", Date().timeIntervalSince(start)), stage)
                fflush(stdout)
            }
        }
        defer { observer.cancel() }
        guard model.questions.send("This is a synthetic PDF test. Read PDF page 1 (index 0), even if the reader is on page 2. Quote the short passage ‘Let H be a Hermitian operator’ exactly, use cite_passage to make the reader highlight it, and attach the returned citation when saving the answer. One sentence only.", to: target, in: model) else {
            throw PaperDeskError.invalid(model.questions.errors[paper.id] ?? "未能发送测试。")
        }
        let end = start.addingTimeInterval(180)
        while model.questions.runningPaperIDs.contains(paper.id), Date() < end {
            try await Task.sleep(for: .milliseconds(100))
        }
        if model.questions.runningPaperIDs.contains(paper.id) {
            model.questions.cancel(paperID: paper.id)
            throw PaperDeskError.invalid("客户端测试超时。")
        }
        if let error = model.questions.errors[paper.id] { throw PaperDeskError.invalid(error) }
        guard let answer = model.discussion.last, answer.role == .assistant,
              answer.citations?.first != nil else {
            throw PaperDeskError.invalid(model.questions.errors[paper.id] ?? "客户端回答未带有已保存的原文高亮。")
        }
        model.activateCitations(for: answer)
        guard model.activeCitationMarks.contains(where: { $0.regions.contains { $0.pageIndex == 0 } }) else {
            throw PaperDeskError.invalid("阅读器没有取得跨页高亮位置。")
        }
        print("PASS: \(clientID) saved a verified cross-page PDF highlight")
    }

    static func checkFloatingQuestion() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["PAPERDESK_QUESTION_TEST_CLIENTS"],
              let fixtureDirectory = QuestionClientRegistry.adapter(id: "codex")?.executableURL()?.deletingLastPathComponent(),
              fixtureDirectory.path == URL(fileURLWithPath: fixture).standardizedFileURL.path,
              QuestionClientRegistry.adapter(id: "opencode")?.executableURL()?.deletingLastPathComponent().path == fixtureDirectory.path else {
            throw PaperDeskError.invalid("悬浮提问检查需要临时客户端，避免调用实际模型。")
        }
        let directory = URL(fileURLWithPath: "/private/tmp/pdq-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, paper) = try projectFixture(at: directory)
        try model.prepareQuestionProject()
        let noConnections = try model.questionTargets()
        guard noConnections.choices.isEmpty, noConnections.active == nil, noConnections.hasProject else {
            throw PaperDeskError.invalid("没有 MCP 连接时仍然提供了发送目标。")
        }
        // Synthetic clients do not run the real paperdesk-mcp child, so mark
        // both harnesses as connected through MCP explicitly.
        func markConnected() {
            model.recordClientConnection(connectionID: "selfcheck-codex", paperID: paper.id,
                                         documentHash: paper.fileHash, clientName: "codex-mcp-client",
                                         clientVersion: "selfcheck")
            model.recordClientConnection(connectionID: "selfcheck-opencode", paperID: paper.id,
                                         documentHash: paper.fileHash, clientName: "opencode",
                                         clientVersion: "selfcheck")
        }
        // An unknown harness should appear in the status list but never become
        // a send target until it registers an adapter.
        model.recordClientConnection(connectionID: "selfcheck-unknown", paperID: paper.id,
                                     documentHash: paper.fileHash, clientName: "future-harness",
                                     clientVersion: "0.1")
        markConnected()
        let service = ReaderTools(model: model)
        let server = LocalBridgeServer(socketURL: LibraryPaths.socket(root: model.store.rootURL)) { request in
            await service.handleWithProgress(request)
        }
        try server.start()
        defer { server.stop() }
        model.bridgeConnected = true

        func waitForReply() async throws {
            let deadline = Date().addingTimeInterval(12)
            while model.questions.runningPaperIDs.contains(paper.id), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if let progress = model.questions.progressByPaperID[paper.id] {
                throw PaperDeskError.invalid("合成客户端没有及时回答（\(progress.title) · \(model.questions.drafts[paper.id] ?? "无草稿")）。")
            }
        }

        let originalIDs = model.activeSelections.map(\.id)
        let initial = try model.questionTargets()
        var stages: [PaperQuestionStage] = []
        let observation = model.questions.$progressByPaperID.sink { values in
            guard let stage = values[paper.id]?.stage, stages.last != stage else { return }
            stages.append(stage)
        }
        defer { observation.cancel() }
        let waitingQuestion = "First frozen question"
        guard let waitingTarget = initial.choices.first(where: { $0.clientID == "codex" && !$0.isKnownConversation }),
              model.questions.send(waitingQuestion, to: waitingTarget, in: model) else {
            throw PaperDeskError.invalid("无法启动等待中的 Codex 自检请求。")
        }
        let waitingFile = fixtureDirectory.appendingPathComponent("codex-waiting")
        let startDeadline = Date().addingTimeInterval(3)
        while (!FileManager.default.fileExists(atPath: waitingFile.path) || stages.last != .generatingAnswer),
              Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard FileManager.default.fileExists(atPath: waitingFile.path),
              model.questions.runningPaperIDs.contains(paper.id),
              stages == [.checkingConnection, .connectingClient, .waitingForAnswer, .generatingAnswer] else {
            throw PaperDeskError.invalid(model.questions.errors[paper.id] ?? "合成 Codex 客户端阶段不正确 \(stages)。")
        }
        model.questions.cancel(paperID: paper.id)
        guard !model.questions.runningPaperIDs.contains(paper.id),
              model.questions.progressByPaperID[paper.id] == nil,
              let retryDraft = model.questions.drafts[paper.id], retryDraft == waitingQuestion,
              model.discussion.isEmpty else {
            throw PaperDeskError.invalid("停止等待后没有解锁发送、保留草稿或保持对话记录。")
        }
        stages.removeAll()
        guard initial.active == nil,
              initial.connectedClients.contains(where: { $0.clientName == "future-harness" && $0.clientID == nil }),
              initial.choices.allSatisfy({ ["codex", "opencode"].contains($0.clientID) }),
              let create = initial.choices.first(where: { $0.clientID == "opencode" && !$0.isKnownConversation }),
              model.questions.send(retryDraft, to: create, in: model) else {
            throw PaperDeskError.invalid("没有找到合成 OpenCode 客户端或无法新建对话。")
        }
        model.clearSelections()
        model.navigate(pageIndex: 2)
        try await waitForReply()
        let titleDeadline = Date().addingTimeInterval(5)
        while ConversationGrouping.group(model.discussion).first?.title != "OpenCode session title", Date() < titleDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("codex-stopped").path) else {
            throw PaperDeskError.invalid("切换客户端后，已停止的 Codex 请求仍在运行。")
        }
        guard model.questions.errors[paper.id] == nil, model.activeReadingConversationID == nil,
              model.questions.progressByPaperID[paper.id] == nil,
              stages.first == .checkingConnection, stages.contains(.connectingClient),
              stages.contains(.readingPaper), stages.contains(.markingSources),
              stages.contains(.savingAnswer), stages.contains(.finishing),
              let conversation = model.questions.completedConversationIDs[paper.id],
              let archived = model.discussion.last, let snapshot = archived.readingSnapshotID,
              let frozen = try model.store.readingSnapshot(id: snapshot), frozen.state.selections.map(\.id) == originalIDs,
              model.discussion.first?.text == "First frozen question", archived.text == "First answer ⟦1⟧.",
              archived.citations?.map(\.label) == ["1"] else {
            throw PaperDeskError.invalid(model.questions.errors[paper.id] ?? "首轮提问的快照、归档或完成状态有误。")
        }

        model.activeReadingConversationID = conversation
        markConnected()
        guard let continuation = try model.questionTargets().active,
              continuation.externalSessionID == "ses_paperdesk_fixture", continuation.clientID == "opencode",
              model.questions.send("Follow-up question", to: continuation, in: model) else {
            throw PaperDeskError.invalid("已有外部会话没有被选为续问目标。")
        }
        try await waitForReply()
        let groups = ConversationGrouping.group(model.discussion)
        guard model.questions.errors[paper.id] == nil, groups.count == 1, groups[0].turnCount == 2,
              groups[0].title == "OpenCode session title", groups[0].messages.last?.text == "Follow-up answer",
              model.activeReadingConversationID == conversation else {
            throw PaperDeskError.invalid(model.questions.errors[paper.id] ?? "续问没有归入原对话。")
        }

        guard model.questions.send("Failed question", to: continuation, in: model) else {
            throw PaperDeskError.invalid("无法启动失败恢复自检。")
        }
        try await waitForReply()
        guard model.questions.errors[paper.id] != nil, model.questions.drafts[paper.id] == "Failed question",
              ConversationGrouping.group(model.discussion).first?.turnCount == 2 else {
            throw PaperDeskError.invalid("外部客户端失败后丢失了草稿或增加了空问答。")
        }

        let nativeLegacySessionID = "018fcc03-c390-7c5b-8d0f-a952e9c104f3"
        var history = try model.store.chatSession(paperID: paper.id)
        let legacyQuestionID = UUID().uuidString
        history.messages += [
            PaperChatMessage(id: legacyQuestionID, role: .user, text: "Legacy Codex question",
                             origin: RecordOrigin(clientName: "Codex")),
            PaperChatMessage(role: .assistant, text: "Legacy Codex answer",
                             origin: RecordOrigin(clientName: "Codex"))
        ]
        try model.store.saveChatSession(history, paperID: paper.id)
        model.refreshDiscussion()
        let legacyRecordID = "legacy:" + legacyQuestionID
        model.activeReadingConversationID = legacyRecordID
        guard let legacy = try model.questionTargets().active,
              legacy.readingRecordID == legacyRecordID, legacy.needsManualSessionBinding,
              legacy.legacyMessageIDs.count == 2,
              model.questions.send("Legacy Codex continuation", to: legacy.bindingSession(nativeLegacySessionID), in: model) else {
            throw PaperDeskError.invalid("无法选择需要显式会话编号的旧 Codex 记录。")
        }
        try await waitForReply()
        let promotedID = "conversation:" + (legacy.conversationID ?? "")
        let promoted = ConversationGrouping.group(model.discussion).first { $0.id == promotedID }
        guard model.questions.errors[paper.id] == nil, model.activeReadingConversationID == promotedID,
              promoted?.title == "Legacy Codex title", promoted?.turnCount == 2, promoted?.messages.count == 4,
              try model.store.questionBinding(backend: "codex", externalSessionID: nativeLegacySessionID)?.conversationID == legacy.conversationID else {
            throw PaperDeskError.invalid(model.questions.errors[paper.id] ?? "旧 Codex 对话未按显式会话编号绑定并合并历史。")
        }

        model.activeReadingConversationID = nil
        guard let document = model.document,
              let selection = document.findString("Let H be a Hermitian operator", withOptions: [.literal]).first else {
            throw PaperDeskError.invalid("未找到 Codex 的引用自检选区。")
        }
        model.captureSelection(selection, document: document)
        markConnected()
        let newTargets = try model.questionTargets()
        guard newTargets.active == nil,
              let codex = newTargets.choices.first(where: { $0.clientID == "codex" && !$0.isKnownConversation }),
              model.questions.send("Separate Codex question", to: codex, in: model) else {
            throw PaperDeskError.invalid("结束续问后没有显示 Codex 的新对话目标。")
        }
        try await waitForReply()
        let reopened = try LibraryStore(rootURL: model.store.rootURL)
        let bindings = try reopened.questionBindings(paperID: paper.id)
        guard model.questions.errors[paper.id] == nil, Set(bindings.map(\.backend)) == ["codex", "opencode"],
              let answer = model.discussion.last, answer.text == "Codex answer ⟦1⟧",
              answer.citations?.map(\.label) == ["1"],
              answer.origin?.clientSourceLabel == "Codex",
              ConversationGrouping.group(model.discussion).count == 3 else {
            throw PaperDeskError.invalid(model.questions.errors[paper.id] ?? "新对话与原会话的客户端绑定串组了。")
        }

        try "Renamed in OpenCode".write(to: fixtureDirectory.appendingPathComponent("opencode-title"), atomically: true, encoding: .utf8)
        let index = fixtureDirectory.appendingPathComponent("session_index.jsonl")
        let existingIndex = try String(contentsOf: index, encoding: .utf8)
        try (existingIndex + """
        {"id":"018fcc03-c390-7c5b-8d0f-a952e9c104f4","thread_name":"Renamed in Codex"}

        """).write(to: index, atomically: true, encoding: .utf8)
        model.refreshExternalConversationTitles()
        let expectedTitles: Set<String> = ["Legacy Codex title", "Renamed in Codex", "Renamed in OpenCode"]
        let deadline = Date().addingTimeInterval(5)
        while Set(ConversationGrouping.group(model.discussion).map(\.title)) != expectedTitles, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard Set(ConversationGrouping.group(model.discussion).map(\.title)) == expectedTitles,
              Set(ConversationGrouping.group(try reopened.chatSession(paperID: paper.id).messages).map(\.title)) == expectedTitles else {
            throw PaperDeskError.invalid("外部改名没有按会话同步到阅读记录。")
        }
        print("PASS: floating questions report live phases, clear them on cancellation and completion, and preserve snapshots, archives and drafts")
    }

    private static func checkProjectConfiguration(_ project: URL, paper: Paper, library: URL, connector: URL) throws {
        let instructionsURL = project.appendingPathComponent("AGENTS.md")
        let reviewerURL = project.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("paperdesk-answer-reviewer.toml")
        let feedbackURL = reviewerURL.deletingLastPathComponent().appendingPathComponent("paperdesk-feedback-analyst.toml")
        let codexReference = project.appendingPathComponent(".codex/agents/paperdesk-reference-renderer.toml")
        let openCodeReference = project.appendingPathComponent(".opencode/agents/paperdesk-reference-renderer.md")
        let currentMarker = "<!-- paperdesk:begin v10 -->"

        // A new project gets both the managed instructions and the dedicated
        // reviewer role. Keep these checks independent of any real Codex CLI.
        let freshInstructions = try String(contentsOf: instructionsURL, encoding: .utf8)
        let freshReviewer = try String(contentsOf: reviewerURL, encoding: .utf8)
        let freshFeedback = try String(contentsOf: feedbackURL, encoding: .utf8)
        guard freshInstructions.contains(currentMarker), freshInstructions.contains("<!-- paperdesk:end -->"),
              freshInstructions.contains(CodexPaperReview.instructions),
              freshInstructions.contains(CodexPaperFeedback.instructions),
              freshInstructions.contains(PaperReferenceRenderer.projectInstruction),
              try String(contentsOf: codexReference, encoding: .utf8).contains("developer_instructions"),
              try String(contentsOf: openCodeReference, encoding: .utf8).contains("mode: subagent"),
              freshReviewer.contains(#"name = "paperdesk-answer-reviewer""#),
              freshFeedback.contains(#"name = "paperdesk-feedback-analyst""#),
              freshFeedback.contains("developer_instructions") else {
            throw PaperDeskError.invalid("新项目没有生成阅读规则、复核角色或反馈分析角色。")
        }

        for version in [4, 5, 6, 7, 8, 9] {
            var previous = freshInstructions.replacingOccurrences(of: currentMarker, with: "<!-- paperdesk:begin v\(version) -->")
                .replacingOccurrences(of: CodexPaperProject.referenceInstruction + "\n", with: "")
            if version < 9 {
                previous = previous.replacingOccurrences(of: PaperReferenceRenderer.projectInstruction + "\n", with: "")
            }
            if version < 8 {
                previous = previous.replacingOccurrences(of: CodexPaperProject.currentCitationInstruction, with: CodexPaperProject.citationInstruction)
            }
            if version < 7 {
                previous = previous.replacingOccurrences(of: CodexPaperFeedback.instructions + "\n", with: "")
            }
            if version < 6 {
                previous = previous.replacingOccurrences(of: CodexPaperReview.instructions + "\n", with: "")
            }
            try previous.write(to: instructionsURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: feedbackURL)
            _ = try CodexPaperProject.create(paper: paper, library: library, connector: connector)
            guard try String(contentsOf: instructionsURL, encoding: .utf8) == freshInstructions,
                  try String(contentsOf: feedbackURL, encoding: .utf8) == freshFeedback else {
                throw PaperDeskError.invalid("旧版阅读项目刷新后缺少反馈分析配置。")
            }
        }

        let stableInstructions = try Data(contentsOf: instructionsURL)
        let stableReviewer = try Data(contentsOf: reviewerURL)
        let codexConfig = project.appendingPathComponent(".codex/config.toml")
        let currentConfig = try String(contentsOf: codexConfig, encoding: .utf8)
        let referenceApproval = "[mcp_servers.paperdesk.tools.verify_reference]\napproval_mode = \"approve\"\n\n"
        guard currentConfig.contains(referenceApproval) else {
            throw PaperDeskError.invalid("Codex 项目缺少参考文献核实工具授权。")
        }
        try currentConfig.replacingOccurrences(of: referenceApproval, with: "").write(to: codexConfig, atomically: true, encoding: .utf8)
        _ = try CodexPaperProject.create(paper: paper, library: library, connector: connector)
        guard try Data(contentsOf: instructionsURL) == stableInstructions,
              try Data(contentsOf: reviewerURL) == stableReviewer,
              try String(contentsOf: feedbackURL, encoding: .utf8) == freshFeedback,
              try String(contentsOf: codexConfig, encoding: .utf8) == currentConfig else {
            throw PaperDeskError.invalid("重复刷新项目配置时改变了稳定的生成内容。")
        }

        let customizedReviewer = """
        # User-owned reviewer role
        name = "paperdesk-answer-reviewer"
        description = "Use my project-specific review preferences."
        developer_instructions = "Keep this custom reviewer configuration."
        """
        try customizedReviewer.write(to: reviewerURL, atomically: true, encoding: .utf8)
        _ = try CodexPaperProject.create(paper: paper, library: library, connector: connector)
        guard try String(contentsOf: reviewerURL, encoding: .utf8) == customizedReviewer else {
            throw PaperDeskError.invalid("刷新项目配置时覆盖了同名的自定义 reviewer 文件。")
        }

        let originalInstructions = "# Custom project guidance\n\nKeep this text when refreshing PaperDesk.\n"
        try originalInstructions.write(to: instructionsURL, atomically: true, encoding: .utf8)
        let configURL = project.appendingPathComponent("opencode.json")
        let existingConfig = Data(#"{"theme":"custom","mcp":{"other":{"enabled":false},"paperdesk":{"type":"local","command":["/old/paperdesk-mcp"],"enabled":false,"timeout":8000}}}"#.utf8)
        try existingConfig.write(to: configURL)

        for _ in 0..<2 {
            _ = try CodexPaperProject.create(paper: paper, library: library, connector: connector)
        }
        let updated = try String(contentsOf: instructionsURL, encoding: .utf8)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let servers = config?["mcp"] as? [String: [String: Any]]
        guard updated == originalInstructions,
              config?["theme"] as? String == "custom", servers?["other"]?["enabled"] as? Bool == false,
              servers?["paperdesk"]?["enabled"] as? Bool == false,
              servers?["paperdesk"]?["timeout"] as? Int == 8000,
              (servers?["paperdesk"]?["command"] as? [String])?.first == connector.path,
              try String(contentsOf: reviewerURL, encoding: .utf8) == customizedReviewer else {
            throw PaperDeskError.invalid("刷新接入配置后，项目自定义内容未保留或出现了重复配置。")
        }

        let unrecognized = Data("{ // Existing config with comments\n  \"theme\": \"custom\"\n}\n".utf8)
        try unrecognized.write(to: configURL)
        try? OpenCodeQuestionAdapter().writeProjectConfiguration(
            project: project, connector: connector, arguments: CodexPaperProject.arguments(paper: paper, library: library))
        guard try Data(contentsOf: configURL) == unrecognized else {
            throw PaperDeskError.invalid("刷新接入配置时覆盖了无法识别的 OpenCode 设置。")
        }
        try existingConfig.write(to: configURL)
        _ = try CodexPaperProject.create(paper: paper, library: library, connector: connector)
        print("PASS: project refresh preserves custom instructions and OpenCode settings")
    }

    private static func checkUnnamedClient(model: AppModel, paper: Paper, service: ReaderTools) throws {
        let launch = try model.mcpLaunchConfiguration(bound: true, clientLabel: "Codex")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: launch.command)
        helper.arguments = launch.arguments
        let stdin = Pipe()
        helper.standardInput = stdin
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            helper.waitUntilExit()
        }

        let pid = helper.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        repeat {
            model.refreshDetectedMCPProcesses()
            if model.detectedMCPProcesses.contains(where: { $0.pid == pid }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        guard model.detectedMCPProcesses.contains(where: { $0.pid == pid }),
              model.connectedClients(forPaperID: paper.id).isEmpty else {
            throw PaperDeskError.invalid("未握手的连接进程显示为了已连接客户端。")
        }

        let identity = "selfcheck-unnamed"
        _ = service.handle(BridgeRequest(method: "__mcp_client_heartbeat", arguments: .object([
            "_bound_paper_id": .string(paper.id), "_bound_document_hash": .string(paper.fileHash),
            "_conversation_id": .string(identity), "_client_pid": .number(Double(pid))
        ])))
        let connections = model.connectedClients(forPaperID: paper.id)
        guard connections.count == 1, connections.first?.id == identity,
              connections.first?.displayName == "Codex", connections.first?.clientID == "codex" else {
            throw PaperDeskError.invalid("已确认的无名连接没有从对应进程识别出 Codex。")
        }
        _ = service.handle(BridgeRequest(method: "__mcp_client_disconnected", arguments: .object([
            "_conversation_id": .string(identity)
        ])))
        guard model.connectedClients(forPaperID: paper.id).isEmpty else {
            throw PaperDeskError.invalid("断开后，仍在运行的辅助进程被显示为已连接。")
        }
        print("PASS: idle helpers stay hidden and the matching process names an anonymous live connection")
    }

    static func checkReadingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferenceDomain = "paperdesk.selfcheck." + directory.lastPathComponent
        guard let preferences = UserDefaults(suiteName: preferenceDomain) else {
            throw PaperDeskError.invalid("无法打开自检设置。")
        }
        defer { preferences.removePersistentDomain(forName: preferenceDomain) }
        let (model, paper) = try projectFixture(at: directory)
        let store = model.store
        let saved = try store.readingState(paperID: paper.id)
        let service = ReaderTools(model: model)
        guard model.codexProjectURL == nil, model.codexLastContact[paper.id] == nil else {
            throw PaperDeskError.invalid("未配置的项目显示了已有连接。")
        }
        let connector = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let project = try CodexPaperProject.create(paper: paper, library: store.rootURL, connector: connector)
        try checkProjectConfiguration(project, paper: paper, library: store.rootURL, connector: connector)
        model.refreshCodexProjectStatus()
        guard model.codexProjectURL?.resolvingSymlinksInPath().path == project.resolvingSymlinksInPath().path,
              model.codexProjectBindingValid, model.codexLastContact[paper.id] == nil else {
            throw PaperDeskError.invalid("项目准备状态与访问状态混淆。")
        }
        _ = service.handle(BridgeRequest(method: "reading_status"))
        _ = service.handle(BridgeRequest(method: "reading_status", arguments: .object([
            "_bound_paper_id": .string(paper.id), "_bound_document_hash": .string("wrong-pdf-hash")
        ])))
        guard model.codexLastContact[paper.id] == nil else {
            throw PaperDeskError.invalid("全局调用或错误绑定被计为项目访问。")
        }
        _ = service.handle(BridgeRequest(method: "__mcp_client_heartbeat", arguments: .object([
            "_bound_paper_id": .string(paper.id), "_bound_document_hash": .string(paper.fileHash),
            "_conversation_id": .string("selfcheck-live"), "_client_name": .string("opencode"),
            "_client_version": .string("selfcheck"), "_client_pid": .number(12345)
        ])))
        guard model.connectedClients(forPaperID: paper.id).contains(where: {
            $0.clientName == "opencode" && $0.clientID == "opencode" && $0.processID == 12345
        }) else {
            throw PaperDeskError.invalid("MCP 心跳没有登记实时连接。")
        }
        _ = service.handle(BridgeRequest(method: "__mcp_client_disconnected", arguments: .object([
            "_conversation_id": .string("selfcheck-live")
        ])))
        guard !model.connectedClients(forPaperID: paper.id).contains(where: { $0.clientName == "opencode" }) else {
            throw PaperDeskError.invalid("MCP 断开后仍显示连接。")
        }
        try checkUnnamedClient(model: model, paper: paper, service: service)
        func boundTool(_ name: String, _ args: [String: JSONValue] = [:], expectError: Bool = false) throws -> JSONValue {
            var params = args
            params["_bound_paper_id"] = .string(paper.id)
            params["_bound_document_hash"] = .string(paper.fileHash)
            let response = service.handle(BridgeRequest(method: name, arguments: .object(params)))
            guard let result = response.result, (result["isError"].boolValue ?? false) == expectError else {
                throw PaperDeskError.invalid("项目操作检查失败 \(name) \((try? response.result?.encodedText()) ?? "")")
            }
            return result
        }
        let capture = try boundTool("capture_reading_state")
        guard model.codexLastContact[paper.id] != nil,
              let snapshotID = capture["structuredContent"]["snapshot_id"].stringValue,
              let snapshot = try store.readingSnapshot(id: snapshotID),
              capture["content"].arrayValue?.filter({ $0["type"].stringValue == "image" }).count == 2,
              capture["content"].arrayValue?.first?["text"].stringValue?.contains("time-independent") == true else {
            throw PaperDeskError.invalid("项目没有同时收到两张原公式图与条件文字。")
        }
        for client in ["Codex", "OpenCode", "Future harness"] {
            let status = try boundTool(MCPProtocol.connectionStatusTool, ["_client_name": .string(client)])["structuredContent"]
            guard status == capture["structuredContent"]["connection_policy"],
                  status["connected"].boolValue == true,
                  status["citation_mode"].stringValue == "selected_passages" else {
                throw PaperDeskError.invalid("不同客户端没有收到一致的连接与标注权限。")
            }
        }
        model.allowsAICitationMarks = false
        guard try boundTool(MCPProtocol.connectionStatusTool)["structuredContent"]["citation_mode"].stringValue == "disabled",
              try boundTool("cite_passage", [
                  "snapshot_id": .string(snapshotID), "selection_context_id": .string(saved.selections[0].id)
              ], expectError: true)["structuredContent"]["code"].stringValue == "citation_marks_disabled",
              try store.snapshotCitations(snapshotID: snapshotID).isEmpty,
              try !AppModel(store: store, preferences: preferences).allowsAICitationMarks else {
            throw PaperDeskError.invalid("关闭标注后权限未生效或未保存。")
        }
        model.allowsAICitationMarks = true
        let contactTime = model.codexLastContact[paper.id]
        let reopenedContactModel = try AppModel(store: LibraryStore(rootURL: store.rootURL))
        reopenedContactModel.openPaper(paper)
        guard reopenedContactModel.scope == .document else {
            throw PaperDeskError.invalid("重启后没有恢复全文读取。")
        }
        guard let contactTime, let restoredContact = reopenedContactModel.codexLastContact[paper.id],
              abs(restoredContact.timeIntervalSince(contactTime)) < 1 else {
            throw PaperDeskError.invalid("项目访问记录没有在重新打开后恢复。")
        }
        let ids = saved.selections.map(\.id)
        let firstSelection = saved.selections[0]
        model.showSelection(firstSelection.context)
        let focused = try boundTool("capture_reading_state")["structuredContent"]
        let previous = try boundTool("get_reading_snapshot", ["snapshot_id": .string(snapshotID)])["structuredContent"]
        let live = try boundTool("reading_status")["structuredContent"]
        reopenedContactModel.openPaper(paper)
        guard focused["context_id"].stringValue == firstSelection.id,
              focused["active_in_reader"].boolValue == true,
              focused["selections"].arrayValue?.compactMap({ $0["context_id"].stringValue }) == ids,
              live["context_id"].stringValue == firstSelection.id,
              reopenedContactModel.context?.id == firstSelection.id,
              previous["context_id"].stringValue == ids.last else {
            throw PaperDeskError.invalid("点回已有选区后，实时状态、快照或恢复的指向有误。")
        }
        model.recordDisplayedPage(saved.pageIndex, visibleRegions: saved.visibleRegions)
        model.removeSelection(id: ids[1])
        guard let page = model.document?.page(at: 2) else { throw PaperDeskError.missing("缺少新选区测试页。") }
        let thirdBounds = CGRect(x: 40, y: 640, width: 460, height: 30)
        model.captureRegion(pageIndex: 2, bounds: thirdBounds, imageData: try PDFRegionRenderer.render(page: page, bounds: thirdBounds))
        let secondSource = directory.appendingPathComponent("Another version.pdf")
        guard let other = PDFDocument(url: store.pdfURL(for: paper)), let first = other.page(at: 0) else {
            throw PaperDeskError.missing("无法准备第二篇测试文献。")
        }
        first.addAnnotation(PDFAnnotation(bounds: CGRect(x: 40, y: 80, width: 16, height: 16), forType: .text, withProperties: nil))
        guard other.write(to: secondSource) else { throw PaperDeskError.invalid("无法生成第二篇测试文献。") }
        // Keep the first paper's explicit restriction while opening another
        // paper. A bound request for the background paper must use that
        // paper's scope, rather than the currently visible paper's scope.
        model.scope = .selection
        model.openPDF(url: secondSource)
        guard let otherPaper = model.selectedPaper, otherPaper.id != paper.id, model.activeSelections.isEmpty else {
            throw PaperDeskError.conflict("第二篇文献继承了第一篇文献的选区。")
        }
        guard model.codexProjectURL == nil, model.codexLastContact[otherPaper.id] == nil else {
            throw PaperDeskError.invalid("切换论文后项目状态串到了另一篇。")
        }
        let status = try boundTool("reading_status")["structuredContent"]
        let background = try boundTool("capture_reading_state")["structuredContent"]
        guard status["paper"]["paper_id"].stringValue == paper.id, status["active_in_reader"].boolValue == false,
              background["paper"]["paper_id"].stringValue == paper.id,
              background["active_in_reader"].boolValue == false,
              background["updated_at"].stringValue == status["updated_at"].stringValue else {
            throw PaperDeskError.conflict("项目跟随了阅读器当前打开的另一篇文献。")
        }
        _ = try boundTool("read_pages", ["paper_id": .string(otherPaper.id), "page_indices": .array([.number(0)])], expectError: true)
        _ = try boundTool("read_pages", ["paper_id": .string(paper.id), "page_indices": .array([.number(0)])], expectError: true)
        _ = try boundTool("search_discussions", ["paper_id": .string(otherPaper.id)], expectError: true)
        let wrongPaper = service.handle(BridgeRequest(method: "search_notes",
                                                       arguments: .object(["paper_id": .string(paper.id)])))
        guard wrongPaper.result?["isError"].boolValue == true else {
            throw PaperDeskError.invalid("通用连接读到了阅读器未打开的论文笔记。")
        }
        let restored = try AppModel(store: LibraryStore(rootURL: store.rootURL))
        restored.openPaper(paper)
        guard restored.activeSelections.map(\.label) == ["A", "C", "D"],
              restored.currentPageIndex == 1,
              restored.restoredViewport == saved.visibleRegions.first,
              try restored.store.readingSnapshot(id: snapshot.id)?.state.selections.map(\.id) == ids else {
            throw PaperDeskError.invalid("移除或恢复选区改变了已固定的提问状态。")
        }
        let archive: [String: JSONValue] = ["snapshot_id": .string(snapshot.id), "question": .string("How is B related to A?"),
                                            "answer": .string("Both use H."), "source_context_ids": .array(ids.map(JSONValue.string)),
                                            "idempotency_key": .string("test-discussion")]
        let entry = try boundTool("save_discussion", archive)["structuredContent"]["message_id"].stringValue
        let again = try boundTool("save_discussion", archive)["structuredContent"]["message_id"].stringValue
        let stored = try restored.store.chatSession(paperID: paper.id)
        model.openPaper(paper)
        let anchoredIDs = model.activeSelections.map(\.id)
        let noteArguments: [String: JSONValue] = [
            "context_ids": .array(anchoredIDs.map(JSONValue.string)),
            "content": .string("Compare the two equations."), "idempotency_key": .string("test-anchored-note")
        ]
        let anchored = try boundTool("submit_note_draft", noteArguments)
        restored.showSelection(saved.selections[1].context)
        guard let entry, entry == again, stored.messages.count == 2, stored.messages.last?.sourceContextIDs == ids,
              let noteID = anchored["structuredContent"]["note_id"].stringValue,
              try restored.store.noteContextIDs(noteID: noteID) == anchoredIDs,
              restored.navigationRequest == 1, restored.navigationRegions == saved.selections[1].context.regions else {
            throw PaperDeskError.invalid("讨论、重复写入或多出处回跳验证失败。")
        }
        let candidates = try boundTool("extractive_candidates", [
            "paper_id": .string(paper.id), "page_indices": .array([.number(0), .number(1), .number(2)])
        ])["structuredContent"]["candidates"].arrayValue ?? []
        guard let choice = candidates.first(where: { $0["text"].stringValue?.contains("Hermitian operator") == true }),
              let choiceID = choice["id"].stringValue else { throw PaperDeskError.missing("未取得原文候选。") }
        let additional = Array(candidates.filter { $0["page_index"].intValue == 1 }.prefix(2))
        let additionalIDs = additional.compactMap { $0["id"].stringValue }
        guard additionalIDs.count == 2 else { throw PaperDeskError.missing("缺少可供重排的原文候选。") }
        var summary: [String: JSONValue] = [
            "paper_id": .string(paper.id), "document_hash": .string(paper.fileHash),
            "candidate_ids": .array([.string("P1S9999")]), "idempotency_key": .string("test-summary")
        ]
        _ = try boundTool("save_extractive_summary", summary, expectError: true)
        summary["candidate_ids"] = .array(([choiceID] + additionalIDs).map(JSONValue.string))
        let summaryResult = try boundTool("save_extractive_summary", summary)["structuredContent"]
        guard let summaryID = summaryResult["note_id"].stringValue,
              summaryResult["status"].stringValue == "draft",
              try store.extractiveSummary(noteID: summaryID).map(\.id) == [choiceID] + additionalIDs,
              try store.extractiveCoverage(noteID: summaryID)?.textPageIndices == [0, 1, 2] else {
            throw PaperDeskError.invalid("Codex 的原文摘录没有保留逐字出处或页码覆盖。")
        }
        guard let draft = model.notes.first(where: { $0.id == summaryID }),
              model.saveExcerptAsNote(draft, content: "这是一条改写笔记。"),
              let rewritten = model.notes.first(where: { $0.content == "这是一条改写笔记。" }),
              rewritten.kind == "note", rewritten.status == "accepted",
              try store.extractiveSummary(noteID: rewritten.id).isEmpty,
              model.reviewExtractiveDraft(draft, sourceIDs: [additionalIDs[1], choiceID], confirm: true),
              model.notes.contains(where: { $0.id == summaryID && $0.status == "accepted" && $0.pageIndex == 1 }),
              try store.extractiveSummary(noteID: summaryID).map(\.text) ==
                [additional[1]["text"].stringValue ?? "", choice["text"].stringValue ?? ""] else {
            throw PaperDeskError.invalid("原文摘录无法审核，或改写内容被误当成原句。")
        }
        guard model.saveManualDiscussion(question: "手动提问", answer: "保留完整回答",
                                         attachSelections: true, sharedWithAI: false),
              let manualID = model.discussion.last?.id,
              model.discussion.last?.manuallyRecorded == true,
              model.discussion.last?.sharedWithAI == false,
              model.discussion.last?.sourceContextIDs == anchoredIDs else {
            throw PaperDeskError.invalid("手动问答或原文出处未保存。")
        }
        model.setManualDiscussionSharing(discussionID: manualID, shared: true)
        guard model.discussion.suffix(2).allSatisfy({ $0.sharedWithAI == true }) else {
            throw PaperDeskError.invalid("手动问答的分享没有同时设置到问题和回答。")
        }
        let manualDetail = try boundTool("get_discussion", ["discussion_id": .string(manualID)])["structuredContent"]
        guard manualDetail["question"].stringValue == "手动提问",
              manualDetail["answer"].stringValue == "保留完整回答" else {
            throw PaperDeskError.invalid("MCP 没有读到已分享的完整手动问答。")
        }
        model.setManualDiscussionSharing(discussionID: manualID, shared: false)
        _ = try boundTool("get_discussion", ["discussion_id": .string(manualID)], expectError: true)
        guard try LibraryStore(rootURL: store.rootURL).chatSession(paperID: paper.id)
            .messages.suffix(2).allSatisfy({ $0.sharedWithAI == false }) else {
            throw PaperDeskError.invalid("重开后没有保留手动问答的分享决定。")
        }
        let matches = try boundTool("search_discussions", ["query": .string("Both use H")])["structuredContent"]["discussions"]
        guard matches.arrayValue?.first?["discussion_id"].stringValue == entry else {
            throw PaperDeskError.invalid("历史问答未按关键词检索。")
        }
        let draftRequest: [String: JSONValue] = [
            "content": .string("两式都用到 H"), "linked_discussion_id": .string(entry),
            "idempotency_key": .string("discussion-note")
        ]
        let draftResult = try boundTool("submit_note_draft", draftRequest)["structuredContent"]
        guard let draftID = draftResult["note_id"].stringValue,
              draftResult["status"].stringValue == "draft",
              try boundTool("submit_note_draft", draftRequest)["structuredContent"]["note_id"].stringValue == draftID,
              let discussionNote = model.notes.first(where: { $0.id == draftID }),
              discussionNote.discussionID == entry,
              try store.noteContextIDs(noteID: draftID) == ids else {
            throw PaperDeskError.invalid("讨论提炼草稿缺少关联信息，或重复请求创建了新记录。")
        }
        _ = try boundTool("get_note", ["note_id": .string(draftID)], expectError: true)
        let unapproved = try boundTool("search_notes", ["query": .string("两式都用到")])["structuredContent"]["notes"]
        guard unapproved.arrayValue?.isEmpty == true,
              model.updateNote(discussionNote, content: "确认后修订的笔记", status: "accepted"),
              !model.pdfAnnotationNoteIDs.contains(draftID) else {
            throw PaperDeskError.invalid("讨论提炼草稿没有遵守笔记审核流程。")
        }
        let approved = try boundTool("get_note", ["note_id": .string(draftID)])["structuredContent"]
        guard approved["content"].stringValue == "确认后修订的笔记",
              approved["discussion_id"].stringValue == entry else {
            throw PaperDeskError.invalid("确认后的笔记无法通过 MCP 检索。")
        }
        let longText = String(repeating: "α🙂\n", count: 10_000)
        let longArchive = try boundTool("save_discussion", [
            "snapshot_id": .string(snapshot.id), "question": .string("保留全文"),
            "answer": .string(longText), "idempotency_key": .string("test-long-discussion"),
            "source_context_ids": .array([])
        ])["structuredContent"]
        guard let longID = longArchive["message_id"].stringValue else { throw PaperDeskError.missing("长讨论未保存。") }
        let firstPart = try boundTool("get_discussion", ["discussion_id": .string(longID)])["structuredContent"]
        guard let nextOffset = firstPart["answer_next_offset"].intValue else {
            throw PaperDeskError.invalid("长讨论没有提供续读位置。")
        }
        let secondPart = try boundTool("get_discussion", [
            "discussion_id": .string(longID), "answer_offset": .number(Double(nextOffset))
        ])["structuredContent"]
        guard let head = firstPart["answer"].stringValue, let tail = secondPart["answer"].stringValue,
              head + tail == longText, secondPart["answer_next_offset"] == .null else {
            throw PaperDeskError.invalid("长讨论分段读取时损失了内容。")
        }
        try checkReadingFeedback(snapshotID: snapshot.id) { name, arguments, expectError in
            try boundTool(name, arguments, expectError: expectError)["structuredContent"]
        }
        print("PASS: cross-page A/B/C, stable labels, frozen sources, paper switch, restart, review navigation and idempotent discussion")
        print("PASS: project extractive save accepts verified source IDs, rejects unknown ones and records coverage")
        print("PASS: editable excerpt review, rephrased notes, and offline discussion with durable sharing")
        print("PASS: historical search, per-paper access, manual sharing and approved note retrieval")
    }

    private static func checkReadingFeedback(
        snapshotID: String, tool: (String, [String: JSONValue], Bool) throws -> JSONValue
    ) throws {
        let archive: [String: JSONValue] = [
            "_client_name": .string("Codex"), "_conversation_id": .string("feedback-check"),
            "snapshot_id": .string(snapshotID), "question": .string("What does H do?"),
            "answer": .string("It generates the evolution."), "source_context_ids": .array([]),
            "idempotency_key": .string("feedback-check-first"), "answer_mode": .string("direct")
        ]
        func messageID(_ parameters: [String: JSONValue]) throws -> String {
            guard let id = try tool("save_discussion", parameters, false)["message_id"].stringValue else {
                throw PaperDeskError.missing("反馈测试的问答没有归档。")
            }
            return id
        }
        let first = try messageID(archive)
        var followUp = archive
        followUp["idempotency_key"] = .string("feedback-check-follow-up")
        followUp["question"] = .string("还是没看懂。H 怎么决定下一步？")
        followUp["answer"] = .string("Here is the missing step.")
        followUp["answer_mode"] = .string("self_review")
        followUp["feedback"] = .object(["kind": .string("unclear"), "evidence": .string("还是没看懂")])
        _ = try tool("save_discussion", followUp, true)
        followUp["previous_discussion_id"] = .string(first)
        var forged = followUp
        forged["feedback"] = .object(["kind": .string("unclear"), "evidence": .string("用户原话里没有的内容")])
        _ = try tool("save_discussion", forged, true)
        let second = try messageID(followUp)
        guard try messageID(followUp) == second else { throw PaperDeskError.conflict("反馈重试生成了重复记录。") }

        let secondDiscussion = try tool("get_discussion", ["discussion_id": .string(second)], false)
        let messages = secondDiscussion["messages"].arrayValue ?? []
        guard messages.first?["feedback"]["answer_id"].stringValue == first,
              messages.first?["feedback"]["evidence"].stringValue == "还是没看懂",
              messages.last?["answer_mode"].stringValue == "self_review" else {
            throw PaperDeskError.conflict("阅读反馈没有保留用户原话或关联正确的上一条回答。")
        }

        followUp["idempotency_key"] = .string("feedback-check-neutral")
        followUp["question"] = .string("这一步在另一种情况下怎么用？")
        followUp["feedback"] = .object(["kind": .string("follow_up"), "evidence": .string("这一步在另一种情况下怎么用？")])
        _ = try tool("save_discussion", followUp, true)
        followUp["previous_discussion_id"] = .string(second)
        _ = try messageID(followUp)
        let modes = try tool("reading_feedback_summary", [:], false)["by_answer_mode"].arrayValue ?? []
        let direct = modes.first { $0["answer_mode"].stringValue == "direct" }
        let selfReview = modes.first { $0["answer_mode"].stringValue == "self_review" }
        guard direct?["unclear"].intValue == 1, direct?["follow_up"].intValue == 0,
              selfReview?["follow_up"].intValue == 1, selfReview?["unclear"].intValue == 0 else {
            throw PaperDeskError.conflict("反馈统计没有按被回应的答案模式正确计数。")
        }
        print("PASS: grounded feedback links to the previous answer, retries safely, and keeps ordinary follow-ups separate")
    }

    static func checkRegionPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-region-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try SamplePDF.create(at: source)
        let model = try AppModel(store: LibraryStore(rootURL: directory.appendingPathComponent("library")))
        model.openPDF(url: source)
        guard let document = model.document, let page = document.page(at: 0) else {
            throw PaperDeskError.invalid("框选检查无法打开示例 PDF。")
        }

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = PDFReaderContainer(frame: window.contentView?.bounds ?? .zero)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let reader = host.pdfView
        reader.document = document
        reader.autoScales = true
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        let visiblePage = reader.convert(page.bounds(for: .cropBox), from: page).intersection(reader.bounds)
        guard visiblePage.width > 170, visiblePage.height > 130 else {
            throw PaperDeskError.invalid("框选检查没有可见的 PDF 页面。")
        }
        let start = reader.convert(NSPoint(x: visiblePage.midX - 65, y: visiblePage.midY - 40), to: nil)
        let end = reader.convert(NSPoint(x: visiblePage.midX + 65, y: visiblePage.midY + 40), to: nil)
        let midpoint = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let overlay = host.overlay
        guard host.subviews.last === overlay, host.hitTest(start) !== overlay else {
            throw PaperDeskError.invalid("预览层未正确覆盖 PDF 或拦截了普通鼠标操作。")
        }
        host.onRegionCaptured = { pageIndex, bounds, data in
            model.captureRegion(pageIndex: pageIndex, bounds: bounds, imageData: data)
        }
        host.formulaCaptureEnabled = true
        guard host.hitTest(start) === overlay else {
            throw PaperDeskError.invalid("框选开启后，未接收到鼠标拖动。")
        }
        let samplePoint = overlay.convert(midpoint, from: nil)
        let before = try paintSample(of: overlay, at: samplePoint)
        try overlay.mouseDown(with: dragEvent(.leftMouseDown, at: start, in: window))
        try overlay.mouseDragged(with: dragEvent(.leftMouseDragged, at: end, in: window))
        let during = try paintSample(of: overlay, at: samplePoint)
        guard during.alphaComponent > before.alphaComponent + 0.03,
              during.blueComponent > during.redComponent + 0.1 else {
            throw PaperDeskError.invalid("拖动时没有绘制蓝色预览。")
        }
        try overlay.mouseUp(with: dragEvent(.leftMouseUp, at: end, in: window))
        guard overlay.dragBounds == nil, let selection = model.activeSelections.first,
              selection.label == "A", selection.context.imageRelativePath != nil,
              selection.context.pageIndex == 0, let region = selection.context.regions.first else {
            throw PaperDeskError.invalid("松开鼠标后没有捕获公式区域。")
        }

        host.formulaCaptureEnabled = false
        guard host.hitTest(start) !== overlay else {
            throw PaperDeskError.invalid("关闭框选后未恢复 PDF 的鼠标操作。")
        }
        overlay.markedSelections = [selection]
        let box = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        let screen = overlay.convert(reader.convert(box, from: page), from: reader)
        let badgePoint = NSPoint(x: screen.minX + 3, y: screen.maxY + 12)
        let savedShade = try paintSample(of: overlay, at: samplePoint)
        let badge = try paintSample(of: overlay, at: badgePoint)
        guard savedShade.alphaComponent > before.alphaComponent + 0.03,
              badge.alphaComponent > 0.9, badge.redComponent > badge.greenComponent else {
            throw PaperDeskError.invalid("已保存的框选没有显示阴影和字母标记。")
        }
        var overlappingContext = selection.context
        overlappingContext.id = UUID().uuidString
        overlay.markedSelections.append(ReadingSelection(label: "B", context: overlappingContext))
        let secondBadge = try paintSample(of: overlay, at: NSPoint(x: badgePoint.x + 20, y: badgePoint.y))
        guard secondBadge.alphaComponent > 0.9 else {
            throw PaperDeskError.invalid("重叠框选遮住了第二个字母标记。")
        }
        model.clearSelections()
        overlay.markedSelections = model.activeSelections
        let clearedBadge = try paintSample(of: overlay, at: badgePoint)
        guard clearedBadge.alphaComponent < 0.05 else {
            throw PaperDeskError.invalid("清空选区后仍显示旧的字母标记。")
        }
        print("PASS: real AppKit drag paints the preview before mouse-up, saves the region, and restores normal hit testing")
        print("PASS: saved region shade and letter remain visible until the selection is cleared")
    }

    static func checkQuestionBubble() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-bubble-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try projectFixture(at: directory)
        model.cancelProjectNamePrompt()
        let application = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 1100, height: 690)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: ReaderView(model: model))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)

        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            hosting.layoutSubtreeIfNeeded()
        }
        func findEditor(in view: NSView) -> NSTextView? {
            guard !view.isHidden else { return nil }
            if let editor = view as? NSTextView, editor.isEditable, !editor.isFieldEditor { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        func findReader(in view: NSView) -> PDFReaderContainer? {
            if let reader = view as? PDFReaderContainer { return reader }
            return view.subviews.lazy.compactMap { findReader(in: $0) }.first
        }
        func pointer(at start: NSPoint, to end: NSPoint? = nil) throws {
            let events: [(NSEvent.EventType, NSPoint)] = end.map { destination in
                let middle = NSPoint(x: (start.x + destination.x) / 2, y: (start.y + destination.y) / 2)
                return [(.leftMouseDown, start), (.leftMouseDragged, middle), (.leftMouseDragged, destination), (.leftMouseUp, destination)]
            } ?? [(.leftMouseDown, start), (.leftMouseUp, start)]
            let startTime = ProcessInfo.processInfo.systemUptime
            for (index, step) in events.enumerated() {
                guard let event = NSEvent.mouseEvent(with: step.0, location: step.1, modifierFlags: [],
                    timestamp: startTime + Double(index) * 0.02, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index, clickCount: 1, pressure: step.0 == .leftMouseUp ? 0 : 1) else {
                    throw PaperDeskError.invalid("无法创建提问气泡检查事件。")
                }
                application.postEvent(event, atStart: false)
            }
            let deadline = Date().addingTimeInterval(0.1)
            while let event = application.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                application.sendEvent(event)
            }
            settle()
        }

        settle()
        guard let reader = findReader(in: hosting) else {
            throw PaperDeskError.invalid("无法定位准备检查提问气泡的 PDF 阅读区。")
        }
        guard findEditor(in: hosting) == nil else { throw PaperDeskError.invalid("检查前已出现多行输入框。") }
        let readerFrame = reader.convert(reader.bounds, to: nil)
        let original = NSPoint(x: readerFrame.maxX - 33, y: readerFrame.minY + 33)
        let moved = NSPoint(x: original.x - 125, y: original.y + 95)
        try pointer(at: original)
        guard let editor = findEditor(in: hosting), let editorScroll = editor.enclosingScrollView,
              let composerScroll = editorScroll.enclosingScrollView else {
            throw PaperDeskError.invalid("点击提问气泡后没有显示可滚动的输入框。")
        }
        let inputHeight = editorScroll.contentSize.height
        let composerHeight = composerScroll.bounds.height
        guard inputHeight >= 185, composerHeight < readerFrame.height - 90 else {
            throw PaperDeskError.invalid("提问框高度不合适（输入区 \(inputHeight)，面板 \(composerHeight)）。")
        }
        try pointer(at: original)
        guard findEditor(in: hosting) == nil else { throw PaperDeskError.invalid("再次点击提问气泡后没有关闭输入框。") }
        try pointer(at: original, to: moved)
        guard findEditor(in: hosting) == nil else { throw PaperDeskError.invalid("拖动提问气泡时误打开了输入框。") }
        try pointer(at: moved)
        guard findEditor(in: hosting) != nil else { throw PaperDeskError.invalid("拖动后点击提问气泡没有打开输入框。") }
        print("PASS: the composer hugs its content (\(composerHeight) points) with a \(inputHeight)-point editor")
        print("PASS: the question bubble opens and closes the editor by click, and can be dragged without opening it")
    }

    static func checkReaderSelectionMarks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-reader-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try SamplePDF.create(at: source)
        guard let preferences = UserDefaults(suiteName: "paperdesk.selfcheck." + directory.lastPathComponent) else {
            throw PaperDeskError.invalid("无法打开自检设置。")
        }
        let model = try AppModel(store: LibraryStore(rootURL: directory.appendingPathComponent("library")), preferences: preferences)
        model.openPDF(url: source)
        guard let document = model.document, let page = document.page(at: 0), let secondPage = document.page(at: 1) else {
            throw PaperDeskError.invalid("无法打开选区标记自检文献。")
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 690),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: ReaderView(model: model))
        window.contentView = hosting
        func settle(_ duration: TimeInterval = 0.15) {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(duration))
            hosting.layoutSubtreeIfNeeded()
        }
        func findReader(in view: NSView) -> PDFReaderContainer? {
            if let reader = view as? PDFReaderContainer { return reader }
            for child in view.subviews {
                if let reader = findReader(in: child) { return reader }
            }
            return nil
        }
        window.orderBack(nil)
        settle()
        guard let host = findReader(in: hosting) else { throw PaperDeskError.invalid("未找到实际阅读窗口的 PDF 视图。") }
        let pdfView = host.pdfView
        let overlay = host.overlay
        let readerWidth = host.bounds.width
        func assertMark(_ selection: ReadingSelection, on page: PDFPage) throws {
            guard let region = selection.context.regions.first else { throw PaperDeskError.invalid("阅读窗口未保存选区坐标。") }
            let box = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
            let rect = overlay.convert(pdfView.convert(box, from: page), from: pdfView)
            let shade = try paintSample(of: overlay, at: NSPoint(x: rect.midX, y: rect.midY))
            let badge = try paintSample(of: overlay, at: NSPoint(x: rect.minX + 3, y: rect.maxY + 12))
            guard shade.alphaComponent > 0.05, badge.alphaComponent > 0.9 else {
                throw PaperDeskError.invalid("实际阅读窗口未显示 \(selection.label) 的阴影和字母（阴影 \(shade.alphaComponent)，字母 \(badge.alphaComponent)）。")
            }
            guard selection.isAI ? badge.blueComponent > badge.redComponent : badge.redComponent > badge.blueComponent else {
                throw PaperDeskError.invalid("阅读窗口的 \(selection.label) 标记颜色与来源不符。")
            }
        }

        model.formulaCaptureMode = true
        settle()
        let visiblePage = pdfView.convert(page.bounds(for: .cropBox), from: page).intersection(pdfView.bounds)
        let start = pdfView.convert(NSPoint(x: visiblePage.midX - 95, y: visiblePage.midY - 30), to: nil)
        let end = pdfView.convert(NSPoint(x: visiblePage.midX + 95, y: visiblePage.midY + 30), to: nil)
        guard host.hitTest(host.convert(start, from: nil)) === overlay else {
            throw PaperDeskError.invalid("阅读窗口的框选工具没有收到鼠标拖动。")
        }
        try overlay.mouseDown(with: dragEvent(.leftMouseDown, at: start, in: window))
        try overlay.mouseDragged(with: dragEvent(.leftMouseDragged, at: end, in: window))
        try overlay.mouseUp(with: dragEvent(.leftMouseUp, at: end, in: window))
        settle(2)
        guard let first = model.activeSelections.first, first.label == "A", first.context.imageRelativePath != nil else {
            throw PaperDeskError.invalid("实际窗口拖动后没有保存框选 A。")
        }
        try assertMark(first, on: page)
        pdfView.go(to: secondPage)
        settle()
        pdfView.go(to: page)
        settle()
        try assertMark(first, on: page)
        print("PASS: region marks survive mouse-up, the preview timeout, and page changes in ReaderView")

        model.formulaCaptureMode = false
        settle()
        guard let passage = document.findString("Saved notes should return", withOptions: []).first,
              let passagePage = passage.pages.first else {
            throw PaperDeskError.invalid("未找到阅读窗口的文字选区示例。")
        }
        pdfView.go(to: passage)
        settle()
        pdfView.setCurrentSelection(passage, animate: false)
        settle()
        pdfView.clearSelection()
        settle(2)
        guard let text = model.activeSelections.last, text.label == "B", text.context.imageRelativePath == nil else {
            throw PaperDeskError.invalid("实际窗口划选后没有保存文字选区 B。")
        }
        try assertMark(text, on: passagePage)

        guard let paper = model.selectedPaper else { throw PaperDeskError.invalid("未找到焦点自检文献。") }
        let connector = ReaderTools(model: model)
        func tool(_ name: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
            var arguments = arguments
            arguments["_client_name"] = .string("Codex")
            arguments["_client_version"] = .string("test")
            guard let reply = connector.handle(BridgeRequest(method: name, arguments: .object(arguments))).result else {
                throw PaperDeskError.invalid("未收到引用自检工具返回。")
            }
            return reply
        }
        let quote = "Let H be a Hermitian operator"
        let secondQuote = "Saved notes should return"
        guard let secondPageIndex = document.findString(secondQuote, withOptions: [.literal]).first?.pages.first.map({ document.index(for: $0) }) else {
            throw PaperDeskError.invalid("未找到第二处引用示例。")
        }
        let captured = try tool("capture_reading_state")["structuredContent"]
        guard let snapshotID = captured["snapshot_id"].stringValue,
              captured["context_id"].stringValue == text.id else {
            throw PaperDeskError.invalid("未能冻结包含人工选区的阅读状态。")
        }

        // The old AI focus channel is closed: the tool no longer exists.
        guard try tool("mark_reading_focus", ["document_hash": .string(paper.fileHash),
                                              "page_index": .number(0),
                                              "quote": .string(quote)])["isError"].boolValue == true else {
            throw PaperDeskError.invalid("AI 焦点通道没有被关闭。")
        }

        let file = model.store.readingPDFURL(for: paper)
        let original = try Data(contentsOf: file)
        let navigationBefore = model.navigationSerial
        model.scope = .document
        let firstCitation = try tool("cite_passage", ["snapshot_id": .string(snapshotID),
                                                      "document_hash": .string(paper.fileHash),
                                                      "page_index": .number(0),
                                                      "quote": .string(quote)])["structuredContent"]
        guard firstCitation["number"].intValue == 1,
              firstCitation["citation_id"].stringValue?.isEmpty == false,
              model.activeSelections.count == 2,
              model.context?.id == text.id,
              model.navigationSerial == navigationBefore,
              try Data(contentsOf: file) == original else {
            throw PaperDeskError.invalid("引用改变了人工选区、导航或 PDF 内容。")
        }
        let repeatedCitation = try tool("cite_passage", ["snapshot_id": .string(snapshotID),
                                                         "document_hash": .string(paper.fileHash),
                                                         "page_index": .number(0),
                                                         "quote": .string(quote)])["structuredContent"]
        guard repeatedCitation["citation_id"].stringValue == firstCitation["citation_id"].stringValue,
              repeatedCitation["number"].intValue == 1,
              try model.store.snapshotCitations(snapshotID: snapshotID).count == 1 else {
            throw PaperDeskError.invalid("重复引用没有复用原有编号。")
        }
        let secondCitation = try tool("cite_passage", ["snapshot_id": .string(snapshotID),
                                                       "document_hash": .string(paper.fileHash),
                                                       "page_index": .number(Double(secondPageIndex)),
                                                       "quote": .string(secondQuote)])["structuredContent"]
        guard secondCitation["number"].intValue == 2,
              try model.store.snapshotCitations(snapshotID: snapshotID).count == 2 else {
            throw PaperDeskError.invalid("第二条引用没有递增编号。")
        }

        // Previously shared passages can be cited without granting page access.
        model.scope = .selection
        let selectedSnapshot = try tool("capture_reading_state")["structuredContent"]
        guard let selectedSnapshotID = selectedSnapshot["snapshot_id"].stringValue,
              selectedSnapshot["connection_policy"]["citation_mode"].stringValue == "selected_passages",
              try tool("cite_passage", ["snapshot_id": .string(selectedSnapshotID),
                                       "selection_context_id": .string(text.id)])["structuredContent"]["number"].intValue == 1,
              try tool("cite_passage", ["snapshot_id": .string(selectedSnapshotID),
                                       "page_index": .number(Double(secondPageIndex)),
                                       "quote": .string(secondQuote)])["structuredContent"]["number"].intValue == 1,
              try tool("cite_passage", ["snapshot_id": .string(selectedSnapshotID),
                                        "document_hash": .string(paper.fileHash),
                                        "page_index": .number(0),
                                        "quote": .string(quote)])["structuredContent"]["code"].stringValue == "selection_required" else {
            throw PaperDeskError.invalid("引用没有遵守仅选区的共享范围。")
        }
        model.scope = .document

        let archive: [String: JSONValue] = [
            "snapshot_id": .string(snapshotID),
            "question": .string("自检：引用如何归档"),
            "answer": .string("自检回答 ⟦1⟧ 与 ⟦2⟧。"),
            "source_context_ids": .array([]),
            "citations": .array([
                .object(["context_id": .string(firstCitation["citation_id"].stringValue ?? ""), "label": .string("1")]),
                .object(["context_id": .string(secondCitation["citation_id"].stringValue ?? ""), "label": .string("2")])
            ]),
            "idempotency_key": .string("self-check-citations-\(UUID().uuidString)")
        ]
        var mismatched = archive
        mismatched["answer"] = .string("自检回答 ⟦1⟧ 与 ⟦3⟧。")
        guard try tool("save_discussion", mismatched)["isError"].boolValue == true else {
            throw PaperDeskError.invalid("编号与出处不一致的回答仍被保存。")
        }
        let saved = try tool("save_discussion", archive)["structuredContent"]
        guard saved["saved"].boolValue == true, let discussionID = saved["message_id"].stringValue else {
            throw PaperDeskError.invalid("带引用的讨论没有保存。")
        }
        let detail = try tool("get_discussion", ["discussion_id": .string(discussionID)])["structuredContent"]
        guard detail["citations"].arrayValue?.compactMap({ $0["label"].stringValue }) == ["1", "2"] else {
            throw PaperDeskError.invalid("讨论没有带回引用列表。")
        }

        model.refreshDiscussion()
        guard let answer = model.discussion.last(where: { $0.role == .assistant }),
              answer.citations?.count == 2 else {
            throw PaperDeskError.invalid("阅读记录里的回答没有引用。")
        }
        pdfView.go(to: page)
        settle()
        model.activateCitations(for: answer)
        settle()
        guard model.activeCitationMessageID == answer.id,
              overlay.citationMarks.count == 2,
              let mark = overlay.citationMarks.first,
              let region = mark.regions.first else {
            throw PaperDeskError.invalid("当前回答的引用没有显示在 PDF 上。")
        }
        let citationBox = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        let citationScreen = overlay.convert(pdfView.convert(citationBox, from: page), from: pdfView)
        let citationShade = try paintSample(of: overlay, at: NSPoint(x: citationScreen.midX, y: citationScreen.midY))
        let citationBadge = try paintSample(of: overlay, at: NSPoint(x: citationScreen.minX + 3, y: citationScreen.maxY + 12))
        guard citationShade.alphaComponent > 0.05,
              citationBadge.alphaComponent > 0.5,
              citationBadge.greenComponent > citationBadge.redComponent else {
            throw PaperDeskError.invalid("引用没有使用与人工选区不同的青色标注。")
        }

        // Switching the active answer clears the previous group.
        model.toggleCitationMarks(for: answer)
        settle()
        guard overlay.citationMarks.isEmpty, model.activeCitationMessageID == nil else {
            throw PaperDeskError.invalid("关闭正文标注后仍显示引用。")
        }
        model.activateCitations(for: answer)
        settle()

        // Clearing the human selections must not remove archived citations.
        model.clearSelections()
        settle()
        guard model.activeSelections.isEmpty,
              overlay.markedSelections.isEmpty,
              overlay.citationMarks.count == 2 else {
            throw PaperDeskError.invalid("清空选区影响了回答引用。")
        }
        guard abs(host.bounds.width - readerWidth) < 1 else {
            throw PaperDeskError.invalid("引用使关闭的右侧栏自动展开。")
        }
        print("PASS: the AI focus channel is gone and citations never enter the selection list")
        print("PASS: one answer's citations paint in teal, switch off with the answer, and survive clearing selections")
    }

    static func checkResponsiveZoom() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-zoom-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.pdf")
        try SamplePDF.create(at: source)
        guard let document = PDFDocument(url: source), let firstPage = document.page(at: 0),
              let secondPage = document.page(at: 1) else {
            throw PaperDeskError.invalid("缩放自检无法打开示例 PDF。")
        }

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let host = PDFReaderContainer(frame: NSRect(x: 0, y: 0, width: 680, height: 700))
        window.contentView = host
        host.pdfView.backgroundColor = NSColor.underPageBackgroundColor
        host.pdfView.displayMode = .singlePageContinuous
        host.pdfView.displayDirection = .vertical
        host.pdfView.displaysPageBreaks = true
        host.pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        host.pdfView.autoScales = false
        host.pdfView.document = document

        // PDFKit performs some of its page layout on the next run-loop turn.
        // Keep this helper local so every resize assertion observes the same
        // settled state, just as a sidebar or a window drag would.
        func settle() {
            host.needsLayout = true
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                host.pdfView.layoutDocumentView()
                host.pdfView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }

        func resize(_ width: CGFloat, _ height: CGFloat) {
            host.setFrameSize(NSSize(width: width, height: height))
            window.setContentSize(NSSize(width: width, height: height))
            settle()
        }

        func horizontalScrollerIsVisible() -> Bool {
            guard let scrollView = host.pdfView.documentView?.enclosingScrollView else { return false }
            return scrollView.hasHorizontalScroller && scrollView.horizontalScroller?.isHidden == false
        }

        func pageRect(_ page: PDFPage) -> CGRect {
            host.pdfView.convert(page.bounds(for: .cropBox), from: page).standardized
        }

        func pageScale(_ page: PDFPage) -> CGFloat {
            let points = page.bounds(for: .cropBox)
            let displayed = pageRect(page)
            guard points.width > 0, points.height > 0 else { return 0 }
            // Width is the least ambiguous dimension in a continuous PDFView;
            // use height only as a fallback for unusual PDF page boxes.
            let widthScale = displayed.width / points.width
            let heightScale = displayed.height / points.height
            return widthScale.isFinite && widthScale > 0 ? widthScale : heightScale
        }

        func checkFinitePage(
            _ page: PDFPage,
            _ label: String,
            allowingVerticalOverflow: Bool = false,
            allowingHorizontalOverflow: Bool = false,
            requiringBalancedHorizontalMargins: Bool = false
        ) throws -> CGRect {
            let rect = pageRect(page)
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
                throw PaperDeskError.invalid("\(label) 的 PDF 页面几何无效。")
            }
            let bounds = host.pdfView.documentView?.enclosingScrollView?.contentView().map {
                $0.convert($0.bounds, to: host.pdfView)
            } ?? host.pdfView.bounds
            // Horizontal overflow is never expected: it makes the page look
            // clipped when the reading sidebar is opened. Vertical overflow
            // is allowed when another page is the current reading location.
            let horizontal = bounds.insetBy(dx: allowingHorizontalOverflow ? -80 : -2, dy: 0)
            guard allowingHorizontalOverflow || (rect.minX >= horizontal.minX && rect.maxX <= horizontal.maxX) else {
                let clip = host.pdfView.documentView?.enclosingScrollView?.contentView
                throw PaperDeskError.invalid("\(label) 的 PDF 页面超出阅读区域边界（页面 \(rect)，阅读区 \(bounds)，滚动区 \(String(describing: clip?.frame))）。")
            }
            if requiringBalancedHorizontalMargins {
                let leftMargin = rect.minX - bounds.minX
                let rightMargin = bounds.maxX - rect.maxX
                guard abs(leftMargin - rightMargin) <= 3 else {
                    throw PaperDeskError.invalid("\(label) 的 PDF 页面左右留白不对称（左 \(leftMargin)，右 \(rightMargin)）。")
                }
            }
            if !allowingVerticalOverflow {
                let vertical = bounds.insetBy(dx: 0, dy: -2)
                guard rect.minY >= vertical.minY, rect.maxY <= vertical.maxY else {
                    throw PaperDeskError.invalid("\(label) 的 PDF 页面垂直方向溢出阅读区域。")
                }
            }
            let overlayFrame = host.overlay.frame.standardized
            let hostBounds = host.bounds.standardized
            guard abs(overlayFrame.minX - hostBounds.minX) <= 1,
                  abs(overlayFrame.minY - hostBounds.minY) <= 1,
                  abs(overlayFrame.width - hostBounds.width) <= 1,
                  abs(overlayFrame.height - hostBounds.height) <= 1 else {
                throw PaperDeskError.invalid("\(label) 调整后框选覆盖层没有跟随阅读区域。")
            }
            return rect
        }

        // The reader's initial mode is fit-width. Set it explicitly as well
        // so this check remains meaningful when the container is constructed
        // outside SwiftUI, as it is in this offscreen test.
        host.setZoomMode(.fitWidth)
        settle()
        guard let scrollView = host.pdfView.documentView?.enclosingScrollView else {
            throw PaperDeskError.invalid("无法检查 PDF 的滚动条。")
        }
        scrollView.scrollerStyle = .legacy
        settle()
        guard !horizontalScrollerIsVisible() else { throw PaperDeskError.invalid("适合宽度时仍显示横向滚动条。") }
        let initial = try checkFinitePage(
            firstPage, "初始适合宽度", allowingVerticalOverflow: true,
            requiringBalancedHorizontalMargins: true
        )
        let initialScale = pageScale(firstPage)
        guard initialScale.isFinite, initialScale > 0,
              initial.width <= host.pdfView.bounds.width + 2 else {
            throw PaperDeskError.invalid("默认适合宽度没有把 PDF 页面放入阅读区域。")
        }

        resize(430, 700)
        let narrow = try checkFinitePage(
            firstPage, "侧栏展开后的适合宽度", allowingVerticalOverflow: true,
            requiringBalancedHorizontalMargins: true
        )
        let narrowScale = pageScale(firstPage)
        guard narrow.width < initial.width * 0.88, narrowScale < initialScale * 0.88 else {
            throw PaperDeskError.invalid("阅读区域变窄后，PDF 没有随宽度缩小。")
        }

        resize(940, 700)
        let wide = try checkFinitePage(
            firstPage, "侧栏收起后的适合宽度", allowingVerticalOverflow: true,
            requiringBalancedHorizontalMargins: true
        )
        let wideScale = pageScale(firstPage)
        guard wide.width > narrow.width * 1.35, wideScale > narrowScale * 1.35 else {
            throw PaperDeskError.invalid("阅读区域变宽后，PDF 没有随宽度放大。")
        }

        // Fit-page must react to the vertical space as well as the width.
        resize(680, 420)
        host.setZoomMode(.fitPage)
        host.pdfView.go(to: firstPage)
        settle()
        let shortPage = try checkFinitePage(firstPage, "较矮窗口的整页模式")
        guard !horizontalScrollerIsVisible() else { throw PaperDeskError.invalid("整页模式仍显示横向滚动条。") }
        let shortScale = pageScale(firstPage)
        guard shortScale.isFinite, shortScale > 0 else {
            throw PaperDeskError.invalid("较矮窗口的整页模式没有有效缩放比例。")
        }

        resize(680, 760)
        let tallPage = try checkFinitePage(firstPage, "较高窗口的整页模式")
        let tallScale = pageScale(firstPage)
        guard tallScale > shortScale * 1.08, tallPage.height > shortPage.height * 1.08 else {
            throw PaperDeskError.invalid("窗口变高后，整页模式没有利用新增的垂直空间。")
        }

        // Manual zoom is intentionally independent of later window changes.
        host.setZoomMode(.fixed(0.84))
        host.pdfView.go(to: secondPage)
        settle()
        let fixedScale = host.pdfView.scaleFactor
        guard !horizontalScrollerIsVisible() else { throw PaperDeskError.invalid("固定比例下整页可见时仍显示横向滚动条。") }
        let fixedPage = try checkFinitePage(
            secondPage, "手动缩放", allowingVerticalOverflow: true,
            allowingHorizontalOverflow: true
        )
        guard abs(fixedScale - 0.84) <= 0.03 else {
            throw PaperDeskError.invalid("手动缩放没有保留指定比例。")
        }
        let currentIndex = document.index(for: host.pdfView.currentPage ?? firstPage)
        guard currentIndex == 1 else {
            throw PaperDeskError.invalid("手动缩放前没有保持当前阅读页。")
        }
        let destinationBeforeResize = host.pdfView.currentDestination

        resize(460, 540)
        let resizedFixedPage = try checkFinitePage(
            secondPage, "调整窗口后的手动缩放", allowingVerticalOverflow: true,
            allowingHorizontalOverflow: true
        )
        let resizedFixedScale = host.pdfView.scaleFactor
        guard horizontalScrollerIsVisible() else { throw PaperDeskError.invalid("页面两侧超出阅读区时未显示横向滚动条。") }
        let resizedIndex = document.index(for: host.pdfView.currentPage ?? firstPage)
        guard abs(resizedFixedScale - fixedScale) <= 0.03,
              abs(resizedFixedPage.width - fixedPage.width) <= 3,
              resizedIndex == currentIndex else {
            throw PaperDeskError.invalid("窗口变化改变了手动缩放比例或当前阅读页。")
        }
        if let before = destinationBeforeResize,
           let after = host.pdfView.currentDestination,
           before.page === secondPage, after.page === secondPage,
           before.point.y.isFinite, after.point.y.isFinite,
           abs(before.point.y - after.point.y) > 24 {
            throw PaperDeskError.invalid("窗口变化后当前阅读页的垂直阅读位置发生了跳动。")
        }

        // Returning to fit-width must release the fixed scale and use the new
        // reading-area width again.
        host.setZoomMode(.fitWidth)
        settle()
        guard !horizontalScrollerIsVisible() else { throw PaperDeskError.invalid("恢复适合宽度时未收起横向滚动条。") }
        let restored = try checkFinitePage(secondPage, "恢复适合宽度", allowingVerticalOverflow: true)
        guard host.pdfView.scaleFactor > resizedFixedScale * 0.75,
              restored.width < host.pdfView.bounds.width + 2,
              document.index(for: host.pdfView.currentPage ?? firstPage) == currentIndex else {
            throw PaperDeskError.invalid("恢复适合宽度后没有重新适应阅读区域或丢失当前阅读页。")
        }

        print("PASS: fit-width, fit-page, fixed zoom, viewport anchors, and horizontal scroller visibility")
    }

    private static func paintSample(of view: NSView, at point: NSPoint) throws -> NSColor {
        let sample = NSRect(x: floor(point.x), y: floor(point.y), width: 2, height: 2)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: sample) else {
            throw PaperDeskError.invalid("无法检查框选预览的颜色。")
        }
        view.cacheDisplay(in: sample, to: bitmap)
        guard let color = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            return .clear
        }
        return color
    }

    private static func dragEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            throw PaperDeskError.invalid("无法创建框选检查事件。")
        }
        return event
    }

    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-selfcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try SamplePDF.create(at: source)
        guard let originalPDF = PDFDocument(url: source), let originalPage = originalPDF.page(at: 0) else {
            throw PaperDeskError.invalid("无法准备原有批注自检。")
        }
        let originalMark = PDFAnnotation(bounds: CGRect(x: 120, y: 90, width: 20, height: 20), forType: .text, withProperties: nil)
        originalMark.contents = "Existing PDF comment"
        originalPage.addAnnotation(originalMark)
        guard originalPDF.write(to: source) else { throw PaperDeskError.invalid("无法准备原有 PDF 批注。") }
        let library = directory.appendingPathComponent("library")
        let store = try LibraryStore(rootURL: library)
        let model = try AppModel(store: store)
        model.openPDF(url: source)
        guard let document = model.document, let paper = model.selectedPaper,
              let selection = document.findString("Hermitian operator", withOptions: .caseInsensitive).first else {
            throw PaperDeskError.invalid("导入或PDF文字提取失败。")
        }
        model.captureSelection(selection, document: document)
        guard let context = model.context else { throw PaperDeskError.invalid("选区未保存。") }
        let connector = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard paper.projectName == "source" else { throw PaperDeskError.invalid("导入时没有把文件标题保存为默认项目名。") }
        try store.setProjectName(paperID: paper.id, name: "Source Project")
        let namedPaper = try store.paper(id: paper.id)
        guard namedPaper.effectiveProjectName == "Source Project" else { throw PaperDeskError.invalid("项目名没有正确保存或读取。") }
        let project = try CodexPaperProject.create(paper: namedPaper, projectName: namedPaper.effectiveProjectName,
                                                   library: store.rootURL, connector: connector)
        guard project.lastPathComponent.hasPrefix("Source-Project-") else { throw PaperDeskError.invalid("项目文件夹没有使用项目名。") }
        model.refreshLibrary()
        model.refreshCodexProjectStatus()
        let service = ReaderTools(model: model)
        func rawTool(_ name: String, _ args: [String: JSONValue] = [:], expectError: Bool = false) throws -> JSONValue {
            let response = service.handle(BridgeRequest(method: name, arguments: .object(args)))
            guard let result = response.result, (result["isError"].boolValue ?? false) == expectError else {
                throw PaperDeskError.invalid("工具检查失败：\(name)")
            }
            return result
        }
        func tool(_ name: String, _ args: [String: JSONValue] = [:], expectError: Bool = false) throws -> JSONValue {
            try rawTool(name, args, expectError: expectError)["structuredContent"]
        }
        let status = try tool("reading_status")
        guard status["context_id"].stringValue == context.id else { throw PaperDeskError.invalid("当前选区身份不匹配。") }
        let capture = try tool("get_context", ["context_id": .string(context.id)])
        guard capture["text"].stringValue?.contains("Hermitian") == true else { throw PaperDeskError.invalid("选区内容不匹配。") }
        // Exercise both temporary restrictions and full-document access.
        model.scope = .document
        _ = try tool("read_pages", ["paper_id": .string(paper.id), "page_indices": .array([.number(0)])])
        model.scope = .selection
        _ = try tool("read_pages", ["paper_id": .string(paper.id), "page_indices": .array([.number(0)])], expectError: true)
        model.scope = .page
        _ = try tool("read_pages", ["paper_id": .string(paper.id), "page_indices": .array([.number(Double(model.currentPageIndex))])])
        _ = try tool("read_pages", ["paper_id": .string(paper.id), "page_indices": .array([.number(2)])], expectError: true)
        model.scope = .document
        _ = try tool("read_pages", ["paper_id": .string(paper.id), "page_indices": .array([.number(0), .number(1)])])
        let args: [String: JSONValue] = ["context_ids": .array([.string(context.id)]), "content": .string("自检笔记：Hermitian 条件需要对照原文核验。"), "idempotency_key": .string("selfcheck-save-1")]
        let first = try tool("submit_note_draft", args), second = try tool("submit_note_draft", args)
        guard first["note_id"].stringValue == second["note_id"].stringValue, try store.notes(paperID: paper.id).count == 1 else {
            throw PaperDeskError.invalid("重复保存产生了多条笔记。")
        }
        var changedArgs = args; changedArgs["content"] = .string("另一份内容")
        _ = try tool("submit_note_draft", changedArgs, expectError: true)
        // Accept the AI draft so it becomes visible to list_notes.
        guard let draftNote = try store.notes(paperID: paper.id).first(where: { $0.id == first["note_id"].stringValue }),
              model.updateNote(draftNote, content: draftNote.content, status: "accepted") else {
            throw PaperDeskError.invalid("AI 笔记草稿无法确认。")
        }
        let manual = ReadingNote(paperID: paper.id, contextID: context.id, pageIndex: context.pageIndex, pageLabel: context.pageLabel, content: "私人笔记")
        _ = try store.insertNote(manual)
        let hidden = try tool("list_notes", ["paper_id": .string(paper.id)])
        guard hidden["notes"].arrayValue?.count == 1 else { throw PaperDeskError.invalid("默认笔记分享范围无效。") }
        model.shareNotesWithAI = true
        let shared = try tool("list_notes", ["paper_id": .string(paper.id)])
        guard shared["notes"].arrayValue?.count == 2 else { throw PaperDeskError.invalid("笔记分享开关无效。") }

        // Reading goals and notes are mirrored into the paper project as
        // human-readable Markdown; writes go through MCP, not the files.
        let goalText = "自检阅读目标：核对 Hermitian 条件与时间演化。"
        let goalResult = try tool("set_reading_goal", ["goal": .string(goalText)])
        guard goalResult["reading_goal"].stringValue == goalText,
              let goalFile = try? String(contentsOf: project.appendingPathComponent("reading-goal.md"), encoding: .utf8),
              goalFile.contains(goalText) else {
            throw PaperDeskError.invalid("set_reading_goal 没有写入阅读目标镜像。")
        }
        guard let notesFile = try? String(contentsOf: project.appendingPathComponent("notes.md"), encoding: .utf8),
              notesFile.contains("自检笔记") else {
            throw PaperDeskError.invalid("笔记没有写入项目镜像。")
        }

        // Exercise the formula path with the same crop renderer used by the
        // UI. The stored PNG must decode locally and be returned as an image
        // block by get_context, not just be advertised by metadata.
        guard let firstPage = document.page(at: 0) else { throw PaperDeskError.invalid("公式自检页面不存在。") }
        let formulaBounds = CGRect(x: 36, y: 510, width: 540, height: 70)
        let formulaImage = try PDFRegionRenderer.render(page: firstPage, bounds: formulaBounds)
        guard CGImageSourceCreateWithData(formulaImage as CFData, nil) != nil else {
            throw PaperDeskError.invalid("公式 PNG 无法解码。")
        }
        model.captureRegion(pageIndex: 0, bounds: formulaBounds, imageData: formulaImage)
        guard let formulaContext = model.context, formulaContext.imageRelativePath != nil else {
            throw PaperDeskError.invalid("公式区域未保存。")
        }
        let imageURL = store.rootURL.appendingPathComponent(formulaContext.imageRelativePath ?? "")
        guard FileManager.default.fileExists(atPath: imageURL.path),
              CGImageSourceCreateWithURL(imageURL as CFURL, nil) != nil else {
            throw PaperDeskError.invalid("公式 PNG 文件未保存或无法解码。")
        }
        let imageResult = try rawTool("get_context", ["context_id": .string(formulaContext.id), "include_image": .bool(true)])
        let hasImageBlock = imageResult["content"].arrayValue?.contains(where: {
            $0["type"].stringValue == "image" && !($0["data"].stringValue ?? "").isEmpty
        }) == true
        guard hasImageBlock else { throw PaperDeskError.invalid("get_context 没有返回公式图片。") }

        let formulaNoteContent = "自检公式批注：检查本征态方程。"
        guard let formulaSelection = model.activeSelections.first(where: { $0.id == formulaContext.id }) else {
            throw PaperDeskError.invalid("公式选区没有加入当前焦点。")
        }
        guard model.saveManualPDFAnnotation(content: formulaNoteContent, paperID: paper.id,
                                            pageIndex: formulaContext.pageIndex, selections: [formulaSelection]),
              let formulaNote = model.notes.first(where: { $0.content == formulaNoteContent && $0.kind == "annotation" }) else {
            throw PaperDeskError.invalid(model.errorMessage ?? "无法写入人工公式批注。")
        }
        let managedSource = store.pdfURL(for: paper)
        let sourceBeforeExport = try Data(contentsOf: managedSource)
        let annotatedURL = directory.appendingPathComponent("annotated.pdf")
        try model.writeAnnotatedPDF(to: annotatedURL)
        guard let exported = PDFDocument(url: annotatedURL),
              let exportedPage = exported.page(at: formulaContext.pageIndex),
              exportedPage.annotations.contains(where: { $0.contents == formulaNoteContent }) else {
            throw PaperDeskError.invalid("人工公式批注没有进入 PDF 导出。")
        }
        let approvedContent = formulaNoteContent + " 已核对。"
        guard model.updateNote(formulaNote, content: approvedContent) else {
            throw PaperDeskError.invalid(model.errorMessage ?? "无法更新公式批注。")
        }
        let editedURL = store.annotatedPDFURL(for: paper)
        let editedBytes = try Data(contentsOf: editedURL)
        model.openPaper(paper)
        guard model.pdfAnnotationNoteIDs.contains(formulaNote.id),
              model.activeSelections.contains(where: { $0.id == formulaContext.id }),
              model.document?.page(at: 0)?.annotations.contains(where: { $0.contents == approvedContent }) == true else {
            throw PaperDeskError.invalid("重新打开文献时，批注或原选区未恢复。")
        }
        guard try Data(contentsOf: managedSource) == sourceBeforeExport else {
            throw PaperDeskError.invalid("导出批注时改写了资料库原始 PDF。")
        }
        guard let annotated = PDFDocument(url: editedURL),
              let annotatedPage = annotated.page(at: formulaContext.pageIndex) else {
            throw PaperDeskError.invalid("批注 PDF 无法重新打开。")
        }
        let annotations = annotatedPage.annotations
        guard annotations.contains(where: {
            $0.type == "Highlight" && ($0.contents ?? "") == approvedContent
        }), annotations.contains(where: {
            guard $0.type == "Text", $0.contents == approvedContent,
                  let color = $0.color.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > color.blueComponent
        }), annotations.contains(where: { $0.contents == "Existing PDF comment" }) else {
            throw PaperDeskError.invalid("批注 PDF 缺少公式高亮或人工评论。")
        }
        guard !model.writeNoteToPDF(formulaNote, content: "过期批注") else {
            throw PaperDeskError.invalid("过期批注覆盖了新版本。")
        }
        guard try Data(contentsOf: editedURL) == editedBytes else {
            throw PaperDeskError.invalid("保存过期记录时未恢复 PDF。")
        }
        guard let secondPage = model.document?.page(at: 1) else { throw PaperDeskError.invalid("缺少第二页。") }
        model.captureRegion(pageIndex: 1, bounds: formulaBounds, imageData: try PDFRegionRenderer.render(page: secondPage, bounds: formulaBounds))
        let capturedSelections = model.activeSelections
        model.clearSelections()
        let temporaryComment = "批注编辑删除自检"
        guard model.saveManualPDFAnnotation(content: temporaryComment, paperID: paper.id,
                                           pageIndex: 1, selections: capturedSelections),
              let manualMark = model.notes.first(where: { $0.content == temporaryComment }),
              model.document?.page(at: 0)?.annotations.contains(where: { $0.contents == temporaryComment }) == true,
              model.document?.page(at: 0)?.annotations.contains(where: {
                  guard $0.type == "Text", $0.contents == temporaryComment,
                        let color = $0.color.usingColorSpace(.sRGB) else { return false }
                  return color.redComponent > color.blueComponent
              }) == true,
              model.document?.page(at: 1)?.annotations.contains(where: { $0.contents == temporaryComment }) == true,
              model.updateNote(manualMark, content: "更新后的 PDF 批注"),
              let rewritten = model.notes.first(where: { $0.id == manualMark.id }),
              model.document?.page(at: 1)?.annotations.contains(where: { $0.contents == rewritten.content }) == true,
              model.document?.page(at: 1)?.annotations.contains(where: { $0.contents == temporaryComment }) == false,
              model.deleteNote(rewritten),
              model.pdfAnnotationNoteIDs.contains(formulaNote.id), !model.pdfAnnotationNoteIDs.contains(rewritten.id),
              model.document?.page(at: 0)?.annotations.contains(where: { $0.contents == "Existing PDF comment" }) == true else {
            throw PaperDeskError.invalid(model.errorMessage ?? "多页 PDF 批注的添加、编辑或删除失败。")
        }
        let pageComment = "没有选区时写入指定页"
        guard model.saveManualPDFAnnotation(content: pageComment, paperID: paper.id, pageIndex: 2, selections: []),
              let pageNote = model.notes.first(where: { $0.content == pageComment }),
              model.document?.page(at: 2)?.annotations.contains(where: { $0.type == "Text" && $0.contents == pageComment }) == true,
              model.document?.page(at: 2)?.annotations.contains(where: { $0.type == "Highlight" && $0.contents == pageComment }) == false,
              model.deleteNote(pageNote) else {
            throw PaperDeskError.invalid(model.errorMessage ?? "没有选区时未能在指定页写入手动批注。")
        }
        try model.writeAnnotatedPDF(to: annotatedURL)
        guard try Data(contentsOf: annotatedURL) == Data(contentsOf: editedURL) else {
            throw PaperDeskError.invalid("导出的 PDF 与正在使用的批注文件不一致。")
        }
        var rejectedSourceAlias = false
        do {
            try model.writeAnnotatedPDF(to: managedSource)
        } catch {
            rejectedSourceAlias = true
        }
        guard rejectedSourceAlias else { throw PaperDeskError.invalid("批注导出允许覆盖原始 PDF。") }

        try store.updateReadingPosition(paperID: paper.id, pageIndex: 2)
        let reopened = try LibraryStore(rootURL: library)
        guard try reopened.paper(id: paper.id).lastPageIndex == 2, try reopened.notes(paperID: paper.id).count == 3 else {
            throw PaperDeskError.invalid("重启恢复检查失败。")
        }
        guard try reopened.exportMarkdown(paperID: paper.id).contains("Hermitian") else { throw PaperDeskError.invalid("笔记导出失败。") }
        let backup = directory.appendingPathComponent("backup")
        try reopened.backup(to: backup)
        let restored = try LibraryStore(rootURL: backup)
        guard try restored.notes(paperID: paper.id).count == 3,
              try Data(contentsOf: restored.annotatedPDFURL(for: paper)) == Data(contentsOf: editedURL),
              FileManager.default.fileExists(atPath: restored.pdfURL(for: paper).path) else { throw PaperDeskError.invalid("备份恢复检查失败。") }
        print("PASS: PDF import, selection, formula images, on-disk PDF comments and highlights, edit/delete, stale-edit rollback, export, source protection, note scopes, reopen and backup")
    }

    static func checkChatStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-chat-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try SamplePDF.create(at: source)
        let root = directory.appendingPathComponent("library")
        let store = try LibraryStore(rootURL: root)
        let paper = try store.importPDF(from: source, title: "Sample paper", pageCount: 3)
        let session = PaperChatSession(readingInstructions: "核对时间演化公式", threadID: "synthetic-session",
                                       messages: [PaperChatMessage(role: .user, text: "What assumptions enter equation (3)?")])
        try store.saveChatSession(session, paperID: paper.id)
        let reopened = try LibraryStore(rootURL: root)
        guard try reopened.chatSession(paperID: paper.id) == session,
              try reopened.chatSession(paperID: "different-paper").messages.isEmpty else {
            throw PaperDeskError.invalid("没有按文献分别保存对话和阅读目标。")
        }
        let backup = directory.appendingPathComponent("backup")
        try reopened.backup(to: backup)
        guard try LibraryStore(rootURL: backup).chatSession(paperID: paper.id) == session else {
            throw PaperDeskError.invalid("备份没有保存文献对话。")
        }
        print("PASS: per-paper goals, thread IDs and messages are persisted and backed up; article excerpts carry PDF pages")
    }

    static func checkExtractiveStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperdesk-extractive-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try SamplePDF.create(at: source)
        let root = directory.appendingPathComponent("library")
        let store = try LibraryStore(rootURL: root)
        let paper = try store.importPDF(from: source, title: "Sample paper", pageCount: 3)
        let original = "Eq. (2) gives α.\nA\nfinite  value is sufficient."
        let candidates = ExtractiveSummary.candidates(pageIndex: 1, pageLabel: "ii", text: original)
        guard candidates.map(\.text) == ["Eq. (2) gives α.", "A\nfinite  value is sufficient."] else {
            throw PaperDeskError.invalid("原文切分修改了公式、空白或缩写。")
        }
        let response = String(decoding: try JSONEncoder().encode(candidates.map(\.id)), as: UTF8.self)
        let verified = try ExtractiveSummary.verifiedSources(response: response, from: candidates, maximum: 2)
        guard (try? ExtractiveSummary.verifiedSources(response: "[\"invented-source\"]", from: candidates, maximum: 2)) == nil,
              (try? ExtractiveSummary.verifiedSources(response: "Comment: " + response, from: candidates, maximum: 2)) == nil,
              (try? ExtractiveSummary.verifiedSources(response: response, from: candidates, maximum: 1)) == nil else {
            throw PaperDeskError.invalid("摘录接受了缺少来源的内容。")
        }
        let note = try store.recordExtractiveSummary(paperID: paper.id, documentHash: paper.fileHash, sources: verified)
        let second = try store.recordExtractiveSummary(paperID: paper.id, documentHash: paper.fileHash, sources: verified)
        let reopened = try LibraryStore(rootURL: root)
        let messages = try reopened.extractiveSummaryMessages(paperID: paper.id)
        let record = try reopened.extractiveSummary(noteID: note.id)
        let exported = try reopened.exportMarkdown(paperID: paper.id)
        guard second.id == note.id, record == candidates, messages.count == 1, messages[0].summarySources == candidates,
              messages[0].summaryNoteID == note.id, exported.contains("PDF 第 2 页\nA\nfinite  value is sufficient.") else {
            throw PaperDeskError.invalid("原文摘录未按页准确保存、重载或导出。")
        }
        guard (try? reopened.updateNote(id: note.id, content: "Rewritten", status: "accepted", expectedRevision: 1)) == nil else {
            throw PaperDeskError.invalid("已核对的原文摘录可以被改写。")
        }
        try reopened.deleteNote(id: note.id)
        guard try reopened.extractiveSummaryMessages(paperID: paper.id).isEmpty,
              try reopened.extractiveSummary(noteID: note.id).isEmpty else {
            throw PaperDeskError.invalid("删除笔记后仍保留原文摘录。")
        }
        print("PASS: original sentences and page references survive storage and export; invalid selections and rewrites are rejected")
    }

}
