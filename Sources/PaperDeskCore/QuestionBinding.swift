import Foundation

/// A durable association between one PaperDesk conversation and one native
/// conversation in an external AI client.
public struct QuestionBinding: Codable, Equatable, Sendable {
    public let paperID: String
    public let conversationID: String
    /// Stable adapter identifier (for example `codex` or `opencode`). Stored in
    /// the `question_bindings.backend` column.
    public let backend: String
    public let projectPath: String
    public let externalSessionID: String

    public init(paperID: String, conversationID: String, backend: String,
                projectPath: String, externalSessionID: String) {
        self.paperID = paperID
        self.conversationID = conversationID
        self.backend = backend
        self.projectPath = projectPath
        self.externalSessionID = externalSessionID
    }
}
