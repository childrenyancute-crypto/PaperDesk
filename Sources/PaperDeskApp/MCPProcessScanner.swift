import Foundation
import PaperDeskCore

/// A `paperdesk-mcp` helper process discovered locally. This is auxiliary
/// evidence used to recover a missing client label for a heartbeat that already
/// confirmed the connection; the process alone is never a displayed connection.
struct DetectedMCPProcess: Equatable, Sendable {
    let pid: Int32
    let paperID: String
    let documentHash: String?
    let clientName: String?
    let clientID: String?
}

enum MCPProcessScanner {
    private static let helperExecutableName = "paperdesk-mcp"
    private static let optionFlags = [
        "--library", "--paper-id", "--document-hash", "--client-label", "--question-request"
    ]
    private static let lock = NSLock()
    private static var cache: (processes: [DetectedMCPProcess], root: String, date: Date)?
    private static let lifetime: TimeInterval = 3

    static func detect(library: URL, paperID: String) -> [DetectedMCPProcess] {
        let root = library.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let processes: [DetectedMCPProcess]
        if let cache, cache.root == root, now.timeIntervalSince(cache.date) < lifetime {
            processes = cache.processes
        } else {
            processes = scan(root: root)
            cache = (processes, root, now)
        }
        return processes.filter { $0.paperID == paperID }
    }

    private static func scan(root: String) -> [DetectedMCPProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // Keep the executable name in its own column. Matching the helper
        // name in the free-form arguments column would also accept a wrapper,
        // shell command, or unrelated client that merely mentions it.
        process.arguments = ["-ww", "-axo", "pid=,ppid=,ucomm=,args="]
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var parentNames: [Int32: String] = [:]
        var result: [DetectedMCPProcess] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  fields[2] == Substring(helperExecutableName) else { continue }
            guard ppid != 1 else { continue }
            let arguments = String(fields[3])
            guard libraryMatches(arguments, root: root),
                  let paperID = argumentValue("--paper-id", in: arguments) else { continue }
            let documentHash = argumentValue("--document-hash", in: arguments)
            let label = argumentValue("--client-label", in: arguments)
            // The explicit label is transport-owned and is more reliable than
            // the parent process name. It is also what the MCP helper reports
            // after initialization, so use the same precedence here.
            let clientName = label ?? parentName(pid: ppid, cache: &parentNames)
            let adapter = QuestionClientRegistry.adapter(clientName: clientName)
            result.append(DetectedMCPProcess(pid: pid, paperID: paperID, documentHash: documentHash,
                                             clientName: clientName, clientID: adapter?.id))
        }
        return result
    }

    private static func libraryMatches(_ arguments: String, root: String) -> Bool {
        guard let supplied = argumentValue("--library", in: arguments) else { return false }
        return URL(fileURLWithPath: supplied).standardizedFileURL.path == root
    }

    private static func argumentValue(_ flag: String, in arguments: String) -> String? {
        guard optionFlags.contains(flag),
              let flagRange = optionRange(flag, in: arguments),
              flagRange.upperBound < arguments.endIndex else { return nil }
        let valueStart = arguments.index(after: flagRange.upperBound)
        let remainder = arguments[valueStart...].drop(while: { $0.isWhitespace })
        guard !remainder.isEmpty else { return nil }
        let remainderStart = remainder.startIndex

        var end = arguments.endIndex
        for candidate in optionFlags where candidate != flag {
            guard let candidateRange = optionRange(candidate, in: arguments, after: remainderStart) else { continue }
            if candidateRange.lowerBound < end { end = candidateRange.lowerBound }
        }
        let value = String(arguments[remainderStart..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func optionRange(_ flag: String, in arguments: String,
                                   after start: String.Index? = nil) -> Range<String.Index>? {
        let searchStart = start ?? arguments.startIndex
        var cursor = searchStart
        while cursor < arguments.endIndex,
              let range = arguments.range(of: flag, range: cursor..<arguments.endIndex) {
            let before = range.lowerBound == arguments.startIndex
                || arguments[arguments.index(before: range.lowerBound)].isWhitespace
            let after = range.upperBound == arguments.endIndex
                || arguments[range.upperBound].isWhitespace
            if before && after { return range }
            cursor = arguments.index(after: range.lowerBound)
        }
        return nil
    }

    private static func parentName(pid: Int32, cache: inout [Int32: String]) -> String? {
        if let cached = cache[pid] { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(fileURLWithPath: name).lastPathComponent
        if !base.isEmpty { cache[pid] = base }
        return base.isEmpty ? nil : base
    }
}
