import Foundation

/// One item that the reader has deliberately kept in the current question.
/// The context ID is immutable and points to the exact PDF version and page
/// geometry captured by the reader.
public struct ReadingSelection: Codable, Equatable, Identifiable, Sendable {
    public let label: String
    public let context: ContextSnapshot
    public let aiOrigin: RecordOrigin?

    public var id: String { context.id }
    public var isAI: Bool { aiOrigin != nil }

    public init(label: String, context: ContextSnapshot, aiOrigin: RecordOrigin? = nil) {
        self.label = label
        self.context = context
        self.aiOrigin = aiOrigin
    }
}

/// Durable state of one paper in the local reader.
public struct PaperReadingState: Codable, Equatable, Sendable {
    public let paperID: String
    public let documentHash: String
    public var pageIndex: Int
    public var visibleRegions: [PageRegion]
    public var selections: [ReadingSelection]
    public var nextLabel: Int
    public var updatedAt: Date
    public var focusedContextID: String?

    public var focusedSelection: ReadingSelection? {
        // Older states only recorded the order of selection.
        selections.first { $0.id == focusedContextID } ?? selections.last { !$0.isAI }
    }

    public init(paperID: String, documentHash: String, pageIndex: Int = 0,
                visibleRegions: [PageRegion] = [], selections: [ReadingSelection] = [],
                nextLabel: Int = 0, updatedAt: Date = Date(), focusedContextID: String? = nil) {
        self.paperID = paperID
        self.documentHash = documentHash
        self.pageIndex = pageIndex
        self.visibleRegions = visibleRegions
        self.selections = selections
        self.nextLabel = max(0, nextLabel)
        self.updatedAt = updatedAt
        self.focusedContextID = focusedContextID
    }

    public static func label(for index: Int) -> String {
        let value = max(0, index)
        let first = value / 26
        let letter = Character(UnicodeScalar(65 + (value % 26))!)
        return first == 0 ? String(letter) : "\(first + 1)\(letter)"
    }
}

/// A frozen, immutable copy used to answer one Codex question.
public struct ReadingQuestionSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let state: PaperReadingState
    public let readingGoal: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, state: PaperReadingState,
                readingGoal: String = "", createdAt: Date = Date()) {
        self.id = id
        self.state = state
        self.readingGoal = readingGoal
        self.createdAt = createdAt
    }
}
