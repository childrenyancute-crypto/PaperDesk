import Foundation
import PaperDeskCore
import PaperDeskStorage
import PaperDeskBridge

/// Dependency-free checks used by `paperdesk-check --verify`.
///
/// These checks intentionally exercise the same public APIs used by the app
/// and the MCP process. They do not contact a model or open any UI, so they
/// remain useful on a machine that only has the Swift command-line tools.
public enum Verification {
    private enum VerificationError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationError.failed(message) }
    }

    private static func expectFailure(_ operation: () throws -> Void, _ message: String) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw VerificationError.failed(message)
    }

    private static func temporaryRoot() throws -> URL {
        // Keep the path deliberately short because Unix-domain sockets have a
        // small platform limit for their pathname.
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        let root = URL(fileURLWithPath: "/private/tmp/pdv-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func code(in response: JSONValue?) -> Int? {
        response?["error"]["code"].intValue
    }

    /// Run all local checks and print one machine-readable line per check.
    public static func run() async throws {
        var passed = 0

        func check(_ name: String, _ operation: () throws -> Void) throws {
            try operation()
            passed += 1
            print("PASS \(name)")
        }

        try check("mcp initialize and protocol negotiation") {
            let protocolServer = MCPProtocol()
            let initialize = protocolServer.handle(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(1),
                "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("future-version")])
            ]), invoke: { _, _ in .null })
            try require(initialize?["result"]["protocolVersion"].stringValue == MCPProtocol.latestProtocolVersion,
                        "MCP should fall back to its latest supported protocol version")
            try require(initialize?["result"]["serverInfo"]["name"].stringValue == "PaperDesk",
                        "MCP initialize should identify PaperDesk")
            try require(protocolServer.handle(.object([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized")
            ]), invoke: { _, _ in .null }) == nil,
                        "initialized notification must not produce a response")
        }

        try check("mcp tools and invalid params") {
            let protocolServer = MCPProtocol()
            let listed = protocolServer.handle(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(2),
                "method": .string("tools/list"),
                "params": .object([:])
            ]), invoke: { _, _ in .null })
            let tools = listed?["result"]["tools"].arrayValue ?? []
            try require(tools.count == MCPProtocol.knownToolNames.count, "MCP tools/list should expose every local tool")
            try require(tools.allSatisfy { $0["inputSchema"]["additionalProperties"].boolValue == false },
                        "MCP tool schemas must reject undeclared arguments")

            let invalid = protocolServer.handle(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(3),
                "method": .string("tools/call"),
                "params": .object(["name": .string("reading_status"), "arguments": .string("wrong shape")])
            ]), invoke: { _, _ in .null })
            try require(Self.code(in: invalid) == -32_602, "MCP should reject non-object tool arguments")

            let unknown = protocolServer.handle(.object([
                "jsonrpc": .string("2.0"),
                "id": .number(4),
                "method": .string("unknown/method")
            ]), invoke: { _, _ in .null })
            try require(Self.code(in: unknown) == -32_601, "MCP should reject unknown methods")
        }

        try check("BibTeX import preserves equations and unknown fields") {
            let text = """
                @comment{A bibliography export}
                @article{example, title = {From {$H$} to {$U(t)$}}, custom = "x@y"}
                @book(another, title = "Another entry")
                """
            let entries = try BibTeX.entries(in: text)
            try require(entries.map(\.id) == ["example", "another"], "BibTeX import should find both entries")
            try require(entries.first?.raw.contains(#"custom = "x@y""#) == true, "unknown BibTeX fields should survive export")
            try require(entries.first?.label.contains("U(t)") == true, "BibTeX import should retain mathematical title content")
        }

        try check("bridge round trip and private socket") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = LibraryPaths.socket(root: root)
            let server = LocalBridgeServer(socketURL: socket) { request in
                BridgeResponse(id: request.id, result: request.arguments)
            }
            try server.start()
            defer { server.stop() }

            let input = JSONValue.object(["text": .string("local bridge"), "page": .number(2)])
            let output = try LocalBridgeClient(socketURL: socket).call(method: "echo", arguments: input)
            try require(output == input, "bridge should return the handler result")
            let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            try require(permissions == 0o600, "bridge socket must be readable only by the current user")
        }

        try check("bridge live server cannot be replaced") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = LibraryPaths.socket(root: root)
            let first = LocalBridgeServer(socketURL: socket) { request in
                BridgeResponse(id: request.id, result: .string("first"))
            }
            try first.start()
            defer { first.stop() }

            let second = LocalBridgeServer(socketURL: socket) { request in
                BridgeResponse(id: request.id, result: .string("second"))
            }
            try expectFailure({ try second.start() }, "a live bridge socket must not be replaced")
            let result = try LocalBridgeClient(socketURL: socket).call(method: "status")
            try require(result == .string("first"), "the original bridge must remain available")
        }

        try check("bridge offline failure") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = LibraryPaths.socket(root: root)
            let server = LocalBridgeServer(socketURL: socket) { request in
                BridgeResponse(id: request.id, result: .null)
            }
            try server.start()
            server.stop()
            try require(!FileManager.default.fileExists(atPath: socket.path), "stopping the bridge should remove its socket")
            try expectFailure({ _ = try LocalBridgeClient(socketURL: socket).call(method: "status") },
                              "an offline bridge should fail instead of returning a fake result")
        }

        try check("library import, duplicate detection, and reopen") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("sample.pdf")
            try SamplePDF.create(at: source)
            let library = root.appendingPathComponent("library", isDirectory: true)

            let paper: Paper
            do {
                let store = try LibraryStore(rootURL: library)
                paper = try store.importPDF(from: source, title: "Verification Sample", pageCount: 3)
                let duplicate = try store.importPDF(from: source, title: "A different title", pageCount: 3)
                try require(duplicate == paper, "importing the same PDF twice should return the existing record")
                let paperCount = try store.papers().count
                try require(paperCount == 1, "duplicate import should not create another paper")
                try store.updateReadingPosition(paperID: paper.id, pageIndex: 2)
                try store.setTags(paperID: paper.id, tags: ["QFT", "QFT", "reading"])
                try store.setReadingState(paperID: paper.id, state: "reading")
            }

            let reopened = try LibraryStore(rootURL: library)
            let persisted = try reopened.paper(id: paper.id)
            try require(persisted.lastPageIndex == 2, "reading position should survive reopening")
            try require(persisted.tags == ["QFT", "reading"], "normalized tags should survive reopening")
            try require(persisted.readingState == "reading", "reading state should survive reopening")
            let reopenedPDF = try Data(contentsOf: reopened.pdfURL(for: persisted))
            let sourcePDF = try Data(contentsOf: source)
            try require(reopenedPDF == sourcePDF, "managed PDF bytes should survive reopening")
        }

        try check("context hash, page validation, and note idempotency") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("sample.pdf")
            try SamplePDF.create(at: source)
            let store = try LibraryStore(rootURL: root.appendingPathComponent("library", isDirectory: true))
            let paper = try store.importPDF(from: source, title: "Context Sample", pageCount: 3)

            let wrongHash = ContextSnapshot(paperID: paper.id, documentHash: "wrong-hash", pageIndex: 1,
                                            pageLabel: "2", text: "invalid version")
            try expectFailure({ _ = try store.saveContext(wrongHash) }, "a context from another PDF version must be rejected")
            let wrongPage = ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash, pageIndex: 3,
                                            pageLabel: "4", text: "invalid page")
            try expectFailure({ _ = try store.saveContext(wrongPage) }, "a context outside the paper must be rejected")

            let context = ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash, pageIndex: 1,
                                          pageLabel: "2", text: "H |n> = E_n |n>",
                                          regions: [PageRegion(pageIndex: 1, x: 10, y: 12, width: 80, height: 24)])
            let savedContext = try store.saveContext(context)
            let loadedContext = try store.context(id: savedContext.id)
            try require(loadedContext == savedContext, "saved context should be readable")

            let note = ReadingNote(paperID: paper.id, contextID: savedContext.id, pageIndex: 1, pageLabel: "2",
                                   quote: "H |n> = E_n |n>", content: "Check the units.", source: "ai", status: "draft")
            let first = try store.insertNote(note, idempotencyKey: "context-check")
            let retry = try store.insertNote(note, idempotencyKey: "context-check")
            try require(first.id == retry.id, "repeating a note request should return the original note")
            let noteCount = try store.notes(paperID: paper.id).count
            try require(noteCount == 1, "idempotent note save must not duplicate notes")
            try expectFailure({ _ = try store.insertNote(ReadingNote(id: UUID().uuidString, paperID: paper.id,
                                                                       pageIndex: 1, pageLabel: "2", content: "changed"),
                                                          idempotencyKey: "context-check") },
                              "reusing an idempotency key with different content must fail")
        }

        try check("note revision CAS conflict") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("sample.pdf")
            try SamplePDF.create(at: source)
            let store = try LibraryStore(rootURL: root.appendingPathComponent("library", isDirectory: true))
            let paper = try store.importPDF(from: source, title: "Revision Sample", pageCount: 3)
            let note = try store.insertNote(ReadingNote(paperID: paper.id, pageIndex: 0, pageLabel: "1", content: "draft"))
            let updated = try store.updateNote(id: note.id, content: "accepted text", status: "accepted", expectedRevision: 1)
            try require(updated.revision == 2, "a successful note update should increment its revision")
            try expectFailure({ _ = try store.updateNote(id: note.id, content: "stale text", status: "accepted", expectedRevision: 1) },
                              "a stale note revision must be rejected")
        }

        try check("backup and restore") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("sample.pdf")
            try SamplePDF.create(at: source)
            let library = root.appendingPathComponent("library", isDirectory: true)
            let store = try LibraryStore(rootURL: library)
            let paper = try store.importPDF(from: source, title: "Backup Sample", pageCount: 3)
            _ = try store.insertNote(ReadingNote(paperID: paper.id, pageIndex: 0, pageLabel: "1", content: "keep me"))
            let backup = root.appendingPathComponent("backup", isDirectory: true)
            try store.backup(to: backup)

            let restored = try LibraryStore(rootURL: backup)
            let restoredPaper = try restored.paper(id: paper.id)
            let restoredNote = try restored.notes(paperID: restoredPaper.id).first?.content
            try require(restoredNote == "keep me", "restored database should contain notes")
            let restoredPDF = try Data(contentsOf: restored.pdfURL(for: restoredPaper))
            let sourcePDF = try Data(contentsOf: source)
            try require(restoredPDF == sourcePDF, "restored library should contain managed PDF assets")
        }


        try check("latex subset normalization and validation") {
            try require(LatexSubset.normalize(#"\dfrac{a}{b}"#) == #"\frac{a}{b}"#,
                        "dfrac should normalize to frac")
            try require(LatexSubset.normalize(#"\begin{align} a &= b \end{align}"#)
                == #"\begin{aligned} a &= b \end{aligned}"#,
                        "align should normalize to aligned")
            try require(LatexSubset.normalize(#"\operatorname{tr}(A)"#) == #"\mathrm{tr}(A)"#,
                        "operatorname should normalize to mathrm")
            try require(LatexSubset.prepare(#"\frac{a}{b} + x^2"#).issues.isEmpty,
                        "supported math must validate")
            try require(LatexSubset.prepare("x = 中").issues.contains { $0.kind == .nonASCIICharacter },
                        "CJK inside math must be reported")
            try require(LatexSubset.prepare(#"\ce{H2O}"#).issues.contains { $0.kind == .unsupportedCommand },
                        "unsupported commands must be reported")
            try require(LatexSubset.prepare(#"\frac{a}{b"#).issues.contains { $0.kind == .unmatchedBrace },
                        "unbalanced braces must be reported")
            try require(LatexSubset.prepare(#"\begin{multline} a \end{multline}"#).issues
                            .contains { $0.kind == .unsupportedEnvironment },
                        "unsupported environments must be reported")
        }

        try check("latex document parsing and check_latex result") {
            let segments = LatexDocument.segments(#"Inline $a^2$ and $$\frac{a}{b}$$"#)
            try require(segments.map(\.formula) == [#"a^2"#, #"\frac{a}{b}"#],
                        "document parser should find inline and display math")
            let ok = LatexSubset.checkResult(text: #"Value $x^2$"#)
            try require(ok["isError"].boolValue == false, "valid math should pass check_latex")
            let bad = LatexSubset.checkResult(text: #"Value $x = 中$"#)
            try require(bad["isError"].boolValue == true, "invalid math should fail check_latex")
            try require(MCPProtocol.instructions.contains("check_latex"),
                        "initialize instructions should tell the model to use check_latex")
        }

        try check("citation footnotes and answer attachments") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("citations.pdf")
            try SamplePDF.create(at: source)
            let store = try LibraryStore(rootURL: root.appendingPathComponent("library", isDirectory: true))
            let paper = try store.importPDF(from: source, title: "Citations", pageCount: 2)
            let snapshot = ReadingQuestionSnapshot(state: PaperReadingState(paperID: paper.id, documentHash: paper.fileHash))
            try store.freezeReadingState(snapshot)
            let context = try store.saveContext(ContextSnapshot(paperID: paper.id, documentHash: paper.fileHash,
                                                                pageIndex: 0, pageLabel: "1", text: "quoted passage",
                                                                regions: [PageRegion(pageIndex: 0, x: 10, y: 10, width: 40, height: 12)]))
            let first = try store.addSnapshotCitation(snapshotID: snapshot.id, contextID: context.id)
            let repeated = try store.addSnapshotCitation(snapshotID: snapshot.id, contextID: context.id)
            try require(first.number == 1 && repeated.number == 1,
                        "repeating a citation should reuse its footnote number")
            let citations = [MessageCitation(contextID: context.id, label: "1", pageLabel: "1")]
            let messageID = try store.appendDiscussion(paperID: paper.id, snapshotID: snapshot.id,
                                                       question: "Why?", answer: "See ⟦1⟧.",
                                                       sourceContextIDs: [], idempotencyKey: "citation-key",
                                                       citations: citations).id
            let answer = try store.chatSession(paperID: paper.id).messages.first { $0.id == messageID }
            try require(answer?.citations?.map(\.label) == ["1"], "saved answers should carry their citations")
            try expectFailure({
                _ = try store.appendDiscussion(paperID: paper.id, snapshotID: snapshot.id,
                                               question: "Why?", answer: "See ⟦1⟧.",
                                               sourceContextIDs: [], idempotencyKey: "citation-key",
                                               citations: [])
            }, "changing the citation payload of a retry must conflict")
            let tools = MCPProtocol.knownToolNames
            try require(tools.contains("cite_passage") && !tools.contains("mark_reading_focus"),
                        "the citation tool should replace the AI focus channel")
        }

        try check("discussion continuation across reconnects") {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("continuation-library", isDirectory: true)
            let store = try LibraryStore(rootURL: directory)
            let source = root.appendingPathComponent("continuation.pdf")
            try SamplePDF.create(at: source)
            let paper = try store.importPDF(from: source, title: "Discussion continuity", pageCount: 3)
            let frame = ReadingQuestionSnapshot(state: PaperReadingState(paperID: paper.id, documentHash: paper.fileHash))
            try store.freezeReadingState(frame)
            let origin = RecordOrigin(clientName: "Codex", clientVersion: "first")
            let first = try store.appendDiscussion(paperID: paper.id, snapshotID: frame.id, question: "Question", answer: "Answer",
                                                   sourceContextIDs: [], idempotencyKey: "first", origin: origin, conversationID: "first-connection")
            let reconnected = RecordOrigin(clientName: "Codex", clientVersion: "second")
            let follow = try store.appendDiscussion(paperID: paper.id, snapshotID: frame.id, question: "Follow-up", answer: "Follow-up answer",
                                                    sourceContextIDs: [], idempotencyKey: "follow", origin: reconnected,
                                                    conversationID: "second-connection", continuingFrom: first.id)
            let replay = try store.appendDiscussion(paperID: paper.id, snapshotID: frame.id, question: "Follow-up", answer: "Follow-up answer",
                                                     sourceContextIDs: [], idempotencyKey: "follow", origin: reconnected,
                                                     conversationID: "third-connection", continuingFrom: first.id)
            try require(follow.conversationID == first.conversationID && replay.id == follow.id && replay.conversationID == follow.conversationID,
                        "follow-up and replay must carry the original group's ID")
            try expectFailure({
                _ = try store.appendDiscussion(paperID: paper.id, snapshotID: frame.id, question: "Foreign", answer: "Unrelated",
                                               sourceContextIDs: [], idempotencyKey: "foreign", origin: RecordOrigin(clientName: "Claude Code"),
                                               conversationID: "foreign-connection", continuingFrom: first.id)
            }, "continuation must reject an unrelated client")
            let grouped = ConversationGrouping.group(try store.chatSession(paperID: paper.id).messages)
            try require(grouped.map(\.turnCount) == [2],
                        "the original chat should have exactly two turns")
        }

        print("PASS total (\(passed) checks)")
    }
}
