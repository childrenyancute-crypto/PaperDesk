import Foundation

public enum PaperChatRole: String, Codable, Sendable {
    case user
    case assistant
}

/// One numbered source attached to an archived answer. Citations are
/// per-answer footnotes: they never enter the reader's selection list and they
/// are highlighted in the PDF only while their answer is being read.
public struct MessageCitation: Identifiable, Codable, Equatable, Sendable {
    public var contextID: String
    /// Footnote number shown in the answer (`⟦3⟧`) and in the record chips.
    public var label: String
    public var pageLabel: String?

    public var id: String { contextID + "#" + label }

    public init(contextID: String, label: String, pageLabel: String? = nil) {
        self.contextID = contextID
        self.label = label
        self.pageLabel = pageLabel
    }
}

/// Renderable citation anchor used by the PDF overlay. Only the active
/// answer's marks are drawn, so two answers never show their sources at once.
public struct CitationMark: Equatable, Sendable {
    public var label: String
    public var contextID: String
    public var regions: [PageRegion]

    public init(label: String, contextID: String, regions: [PageRegion]) {
        self.label = label
        self.contextID = contextID
        self.regions = regions
    }
}

public struct PaperChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var role: PaperChatRole
    public var text: String
    public var pageLabel: String?
    public var contextID: String?
    public var sourcePageIndex: Int?
    public var createdAt: Date
    public var summarySources: [ExtractiveSource]?
    public var summaryNoteID: String?
    public var readingSnapshotID: String?
    public var sourceContextIDs: [String]?
    /// Numbered sources cited by this answer. `nil` for legacy records and for
    /// questions.
    public var citations: [MessageCitation]?
    /// Identifies the client that created this message, when available.
    public var origin: RecordOrigin?
    /// Whether this message was explicitly recorded by the user rather than
    /// being an ephemeral AI response. `nil` preserves historical records.
    public var manuallyRecorded: Bool?
    /// Whether the user has approved this message for sharing with an AI
    /// client. `nil` preserves historical records; new records default false.
    public var sharedWithAI: Bool?
    /// The external-client conversation this message belongs to. PaperDesk
    /// groups archived Q&A by this identifier so two conversations in the same
    /// client are stored and shown as two separate reading records. `nil`
    /// preserves historical records written before conversation tracking.
    public var conversationID: String?
    /// The last available title for this conversation, including titles
    /// synchronized from external clients.
    public var conversationTitle: String?
    public var isExtractiveSummary: Bool { summaryNoteID != nil }

    public init(id: String = UUID().uuidString, role: PaperChatRole, text: String, pageLabel: String? = nil, contextID: String? = nil, sourcePageIndex: Int? = nil, createdAt: Date = Date(), summarySources: [ExtractiveSource]? = nil, summaryNoteID: String? = nil, readingSnapshotID: String? = nil, sourceContextIDs: [String]? = nil, origin: RecordOrigin? = nil, manuallyRecorded: Bool? = nil, sharedWithAI: Bool? = nil, conversationID: String? = nil, conversationTitle: String? = nil, citations: [MessageCitation]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.pageLabel = pageLabel
        self.contextID = contextID
        self.sourcePageIndex = sourcePageIndex
        self.createdAt = createdAt
        self.summarySources = summarySources
        self.summaryNoteID = summaryNoteID
        self.readingSnapshotID = readingSnapshotID
        self.sourceContextIDs = sourceContextIDs
        self.origin = origin
        self.manuallyRecorded = manuallyRecorded
        self.sharedWithAI = sharedWithAI
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.citations = citations
    }
}

public struct PaperChatSession: Codable, Equatable, Sendable {
    public var readingInstructions: String
    public var threadID: String?
    public var messages: [PaperChatMessage]

    public init(readingInstructions: String = "", threadID: String? = nil, messages: [PaperChatMessage] = []) {
        self.readingInstructions = readingInstructions
        self.threadID = threadID
        self.messages = messages
    }
}

public extension RecordOrigin {
    /// A short, human-friendly label for the client that created a record.
    /// Known AI clients are normalized so "codex"/"Codex CLI" both read as
    /// "Codex" in the reading-records sidebar.
    var clientSourceLabel: String {
        let raw = clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = raw.lowercased()
        if lowered.contains("codex") { return "Codex" }
        if lowered.contains("claude") { return "Claude Code" }
        if lowered.contains("opencode") || lowered.contains("open code") { return "opencode" }
        if lowered.contains("cursor") { return "Cursor" }
        return raw.isEmpty ? "未知客户端" : raw
    }
}

/// One archived conversation from an external AI client, or a local manual
/// recording. It is the unit shown in the reader's "reading records" sidebar.
public struct ConversationSummary: Identifiable, Equatable, Sendable {
    public let id: String
    /// The raw conversation ID stored on messages, when the records carry one.
    public var conversationID: String?
    public var title: String
    public var origin: RecordOrigin?
    public var messages: [PaperChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var isManual: Bool
    /// True when the messages predate conversation tracking and were grouped
    /// by client and time proximity rather than an explicit conversation ID.
    public var isLegacy: Bool

    public init(id: String, conversationID: String?, title: String, origin: RecordOrigin?, messages: [PaperChatMessage], createdAt: Date, updatedAt: Date, isManual: Bool, isLegacy: Bool) {
        self.id = id
        self.conversationID = conversationID
        self.title = title
        self.origin = origin
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isManual = isManual
        self.isLegacy = isLegacy
    }

    public var sourceLabel: String {
        if isManual { return "手动记录" }
        return origin?.clientSourceLabel ?? "未知客户端"
    }

    /// Number of question/answer pairs, shown in the record card header.
    public var turnCount: Int {
        max(messages.filter { $0.role == .user }.count, 1)
    }

    /// The ID to persist when this group is continued. Legacy groups are
    /// promoted to an explicit ID so future turns stay in the same record.
    public var stableConversationID: String {
        conversationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? conversationID!
            : id
    }
}

public enum ConversationGrouping {
    /// Groups archived chat messages into conversation units.
    ///
    /// Messages carrying an explicit `conversationID` are grouped by it. Manual
    /// recordings are kept together under one "手动记录" entry. Historical
    /// messages without an ID are grouped by client plus a time window so a
    /// single long session reads as one conversation instead of dozens of
    /// fragments.
    public static func group(_ messages: [PaperChatMessage], legacyGap: TimeInterval = 3 * 60 * 60) -> [ConversationSummary] {
        let visible = messages.filter { !$0.isExtractiveSummary }
        guard !visible.isEmpty else { return [] }

        struct Building {
            var messages: [PaperChatMessage]
            var isManual: Bool
            var isLegacy: Bool
        }

        var orderedKeys: [String] = []
        var builders: [String: Building] = [:]
        // Legacy messages are attached to the most recent conversation from the
        // same client when they arrive close together.
        var lastLegacy: [String: (key: String, date: Date)] = [:]

        for message in visible {
            let manual = message.manuallyRecorded == true
            let explicitID = message.conversationID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            let isLegacy: Bool
            if manual {
                key = "manual"
                isLegacy = false
            } else if let explicitID, !explicitID.isEmpty {
                key = "conversation:" + explicitID
                isLegacy = false
            } else {
                let client = message.origin?.clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                if let last = lastLegacy[client], message.createdAt.timeIntervalSince(last.date) <= legacyGap {
                    key = last.key
                } else {
                    key = "legacy:" + message.id
                }
                lastLegacy[client] = (key, message.createdAt)
                isLegacy = true
            }
            if builders[key] == nil {
                orderedKeys.append(key)
                builders[key] = Building(messages: [], isManual: manual, isLegacy: isLegacy)
            }
            builders[key]?.messages.append(message)
        }

        let summaries = orderedKeys.compactMap { key -> ConversationSummary? in
            guard let builder = builders[key], !builder.messages.isEmpty else { return nil }
            let sorted = builder.messages.sorted { $0.createdAt < $1.createdAt }
            let title = explicitTitle(in: sorted) ?? fallbackTitle(for: sorted, isManual: builder.isManual)
            let origin = sorted.compactMap(\.origin).first
            let rawConversationID = sorted.compactMap { $0.conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            return ConversationSummary(id: key,
                                       conversationID: rawConversationID,
                                       title: title,
                                       origin: origin,
                                       messages: sorted,
                                       createdAt: sorted.first?.createdAt ?? Date(),
                                       updatedAt: sorted.last?.createdAt ?? Date(),
                                       isManual: builder.isManual,
                                       isLegacy: builder.isLegacy)
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func explicitTitle(in messages: [PaperChatMessage]) -> String? {
        for message in messages {
            if let title = message.conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private static func fallbackTitle(for messages: [PaperChatMessage], isManual: Bool) -> String {
        if isManual { return "手动记录" }
        let source = messages.first(where: { $0.role == .user }) ?? messages.first
        let raw = source?.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "对话" }
        return String(raw.prefix(28)) + (raw.count > 28 ? "…" : "")
    }
}
