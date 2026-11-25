import Foundation

public struct Paper: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var fileName: String
    public var fileHash: String
    public var pageCount: Int
    public var lastPageIndex: Int
    public var tags: [String]
    public var readingState: String
    public var bibtex: String
    /// The human-readable name of this paper's reading project. Missing or
    /// empty values fall back to the paper title for projects created by older
    /// PaperDesk versions.
    public var projectName: String?
    public var addedAt: Date
    public var updatedAt: Date

    public var effectiveProjectName: String {
        let name = projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (fallback.isEmpty ? "Paper" : fallback) : name
    }

    public init(id: String = UUID().uuidString, title: String, fileName: String, fileHash: String, pageCount: Int, lastPageIndex: Int = 0, tags: [String] = [], readingState: String = "unread", bibtex: String = "", projectName: String? = nil, addedAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.fileName = fileName; self.fileHash = fileHash
        self.pageCount = pageCount; self.lastPageIndex = lastPageIndex; self.tags = tags
        self.readingState = readingState; self.bibtex = bibtex; self.projectName = projectName
        self.addedAt = addedAt; self.updatedAt = updatedAt
    }
}

public struct PageRegion: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(pageIndex: Int, x: Double, y: Double, width: Double, height: Double) {
        self.pageIndex = pageIndex; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct ContextSnapshot: Codable, Identifiable, Equatable, Sendable {
    public static let cropImageSuffix = "-v2.png"
    public var id: String
    public var paperID: String
    public var documentHash: String
    public var pageIndex: Int
    public var pageLabel: String
    public var text: String
    public var regions: [PageRegion]
    public var imageRelativePath: String?
    public var createdAt: Date

    public var sourceText: String {
        // Prior versions stored this placeholder when PDFKit found no text.
        imageRelativePath != nil && text == "公式区域" ? "" : text
    }

    public init(id: String = UUID().uuidString, paperID: String, documentHash: String, pageIndex: Int, pageLabel: String, text: String, regions: [PageRegion] = [], imageRelativePath: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.paperID = paperID; self.documentHash = documentHash
        self.pageIndex = pageIndex; self.pageLabel = pageLabel; self.text = text
        self.regions = regions; self.imageRelativePath = imageRelativePath; self.createdAt = createdAt
    }
}

/// Identifies the application or client that created a reading record.
///
/// Both values are optional so records written by older PaperDesk versions
/// remain valid and callers can provide only the information they know.
public struct RecordOrigin: Codable, Equatable, Sendable {
    public var clientName: String?
    public var clientVersion: String?

    public init(clientName: String? = nil, clientVersion: String? = nil) {
        self.clientName = clientName
        self.clientVersion = clientVersion
    }
}

public struct ReadingNote: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var paperID: String
    public var contextID: String?
    public var pageIndex: Int
    public var pageLabel: String
    public var quote: String
    public var content: String
    public var source: String
    public var status: String
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// Optional client metadata for distinguishing records created by a
    /// particular AI client or app. `nil` means the record predates origin
    /// tracking or was created without identifying its caller.
    public var origin: RecordOrigin?
    /// A light-weight semantic category such as `note`, `annotation`, or
    /// `excerpt`. It is optional for compatibility with historical notes.
    public var kind: String?
    /// The discussion answer that led to this note, when applicable.
    public var discussionID: String?

    public init(id: String = UUID().uuidString, paperID: String, contextID: String? = nil, pageIndex: Int, pageLabel: String, quote: String = "", content: String, source: String = "human", status: String = "accepted", revision: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date(), origin: RecordOrigin? = nil, kind: String? = nil, discussionID: String? = nil) {
        self.id = id; self.paperID = paperID; self.contextID = contextID
        self.pageIndex = pageIndex; self.pageLabel = pageLabel; self.quote = quote; self.content = content
        self.source = source; self.status = status; self.revision = revision
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.origin = origin; self.kind = kind; self.discussionID = discussionID
    }
}

public enum ContextScope: String, Codable, CaseIterable, Sendable {
    case selection, page, document
    public var title: String {
        switch self { case .selection: return "仅选区"; case .page: return "当前页"; case .document: return "全文" }
    }
}

public enum LibraryPaths {
    /// The normal on-device location for PaperDesk's local library.
    ///
    /// This is intentionally independent of the app bundle (and of the source
    /// checkout) so installing a new copy of PaperDesk does not move or hide a
    /// user's papers and reading history.
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PaperDesk/Library", isDirectory: true)

    /// Codex projects are kept separately from the library so each project can
    /// be opened directly from Finder/Codex without exposing the app's database
    /// directory as a project.
    public static let defaultCodexProjects = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/PaperDesk/Codex Projects", isDirectory: true)

    public static func root(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let index = arguments.firstIndex(of: "--library"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath, isDirectory: true)
        }
        if let path = environment["PAPERDESK_LIBRARY"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "PaperDeskLibraryPath") as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultRoot
    }

    /// Returns the directory where a paper's Codex project should live.
    ///
    /// The managed/default library uses a stable, Finder-friendly location in
    /// Documents. Explicit library overrides (including test libraries) stay
    /// self-contained under `<library>/codex-projects`.
    public static func codexProjects(root: URL) -> URL {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalDefault = defaultRoot.standardizedFileURL.resolvingSymlinksInPath().path
        if canonicalRoot == canonicalDefault {
            return defaultCodexProjects
        }
        return root.appendingPathComponent("codex-projects", isDirectory: true)
    }

    public static func socket(root: URL) -> URL { root.appendingPathComponent("bridge.sock") }
}

public enum PaperDeskError: LocalizedError {
    case invalid(String)
    case missing(String)
    case conflict(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .missing(let message), .conflict(let message): return message }
    }
}
