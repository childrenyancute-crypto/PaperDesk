import XCTest
@testable import PaperDeskCore

final class ConversationTests: XCTestCase {
    private let origin = RecordOrigin(clientName: "Codex CLI", clientVersion: "1.0")

    func testGroupsExplicitConversationsSeparatelyAndLabelsSource() {
        let now = Date()
        let messages = [
            PaperChatMessage(role: .user, text: "第一段对话的问题", createdAt: now, origin: origin, conversationID: "thread-a"),
            PaperChatMessage(role: .assistant, text: "回答一", createdAt: now.addingTimeInterval(5), origin: origin, conversationID: "thread-a"),
            PaperChatMessage(role: .user, text: "第二段对话的问题", createdAt: now.addingTimeInterval(10), origin: origin, conversationID: "thread-b"),
            PaperChatMessage(role: .assistant, text: "回答二", createdAt: now.addingTimeInterval(15), origin: origin, conversationID: "thread-b")
        ]
        let groups = ConversationGrouping.group(messages)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.messages.count == 2 })
        XCTAssertTrue(groups.allSatisfy { $0.sourceLabel == "Codex" })
        XCTAssertEqual(groups.first?.updatedAt, now.addingTimeInterval(15))
        XCTAssertEqual(groups.first?.title, "第二段对话的问题")
    }

    func testUsesStoredConversationTitle() {
        let now = Date()
        let messages = [
            PaperChatMessage(role: .user, text: "问题", createdAt: now, origin: origin,
                             conversationID: "thread-a", conversationTitle: "自定义标题"),
            PaperChatMessage(role: .assistant, text: "回答", createdAt: now.addingTimeInterval(1), origin: origin,
                             conversationID: "thread-a", conversationTitle: "自定义标题")
        ]
        XCTAssertEqual(ConversationGrouping.group(messages).first?.title, "自定义标题")
    }

    func testLegacyMessagesGroupByClientAndTimeGap() {
        let now = Date()
        let messages = [
            PaperChatMessage(role: .user, text: "旧问题一", createdAt: now, origin: origin),
            PaperChatMessage(role: .assistant, text: "旧回答一", createdAt: now.addingTimeInterval(30), origin: origin),
            PaperChatMessage(role: .user, text: "新问题", createdAt: now.addingTimeInterval(10 * 60 * 60), origin: origin),
            PaperChatMessage(role: .assistant, text: "新回答", createdAt: now.addingTimeInterval(10 * 60 * 60 + 30), origin: origin)
        ]
        let groups = ConversationGrouping.group(messages)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy(\.isLegacy))
        XCTAssertEqual(groups.first?.title, "新问题")
    }

    func testManualMessagesShareOneEntry() {
        let now = Date()
        let messages = [
            PaperChatMessage(role: .user, text: "手问一", createdAt: now, manuallyRecorded: true),
            PaperChatMessage(role: .assistant, text: "手答一", createdAt: now.addingTimeInterval(1), manuallyRecorded: true),
            PaperChatMessage(role: .user, text: "手问二", createdAt: now.addingTimeInterval(60), manuallyRecorded: true),
            PaperChatMessage(role: .assistant, text: "手答二", createdAt: now.addingTimeInterval(61), manuallyRecorded: true)
        ]
        let groups = ConversationGrouping.group(messages)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "手动记录")
        XCTAssertEqual(groups.first?.sourceLabel, "手动记录")
        XCTAssertEqual(groups.first?.messages.count, 4)
    }

    func testCitationsDecodeAndTurnCount() throws {
        let now = Date()
        let citations = [MessageCitation(contextID: "c1", label: "1", pageLabel: "4"),
                         MessageCitation(contextID: "c2", label: "2", pageLabel: "9")]
        let messages = [
            PaperChatMessage(role: .user, text: "问题一", createdAt: now, origin: origin, conversationID: "thread-c"),
            PaperChatMessage(role: .assistant, text: "回答一 ⟦1⟧⟦2⟧", createdAt: now.addingTimeInterval(1),
                             origin: origin, conversationID: "thread-c", citations: citations),
            PaperChatMessage(role: .user, text: "问题二", createdAt: now.addingTimeInterval(2), origin: origin, conversationID: "thread-c"),
            PaperChatMessage(role: .assistant, text: "回答二", createdAt: now.addingTimeInterval(3), origin: origin, conversationID: "thread-c")
        ]
        let groups = ConversationGrouping.group(messages)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.turnCount, 2)
        XCTAssertEqual(groups.first?.messages.first(where: { $0.role == .assistant })?.citations?.map(\.label), ["1", "2"])

        let data = try JSONEncoder().encode(messages[0])
        let legacy = try JSONDecoder().decode(PaperChatMessage.self, from: data)
        XCTAssertNil(legacy.citations)
    }

    func testExtractiveSummaryMessagesAreNotConversations() {
        let source = ExtractiveSource(id: "s1", pageIndex: 0, pageLabel: "1", text: "原文")
        let message = PaperChatMessage(role: .assistant, text: "摘录", summarySources: [source], summaryNoteID: "n1")
        XCTAssertTrue(ConversationGrouping.group([message]).isEmpty)
    }
}
