import Foundation
import PaperDeskCore

/// The result of one non-interactive request sent to an external coding
/// client.  The session identifier is deliberately returned alongside the
/// answer: it is the value that PaperDesk must persist in order to continue
/// this exact conversation on the next question.
public struct ExternalQuestionAnswer: Sendable, Equatable {
    public let sessionID: String
    public let answer: String
    public let conversationTitle: String?

    public init(sessionID: String, answer: String, conversationTitle: String? = nil) {
        self.sessionID = sessionID
        self.answer = answer
        self.conversationTitle = conversationTitle
    }
}

public enum ExternalQuestionRunnerError: LocalizedError, Sendable {
    case invalidProject
    case emptyPrompt
    case connectorUnavailable
    case executableUnavailable(String)
    case launchFailed
    case processFailed(Int32, String?)
    case timedOut
    case cancelled
    case outputTooLarge
    case invalidResponse
    case sessionMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidProject:
            return L("外部客户端项目目录不存在或无法访问。")
        case .emptyPrompt:
            return L("问题不能为空。")
        case .connectorUnavailable:
            return L("找不到 PaperDesk 的 MCP 连接程序。")
        case .executableUnavailable(let name):
            return L("没有找到已安装的 \(name) 命令行程序。", "The installed \(name) command-line tool could not be found.")
        case .launchFailed:
            return L("无法启动外部客户端。")
        case .processFailed(let status, let diagnostic):
            if let diagnostic {
                return L("外部客户端未能完成这次请求（退出码 \(status)：\(diagnostic)）。", "The external client could not complete this request (exit code \(status): \(diagnostic)).")
            }
            return L("外部客户端未能完成这次请求（退出码 \(status)）。", "The external client could not complete this request (exit code \(status)).")
        case .timedOut:
            return L("外部客户端响应超时。")
        case .cancelled:
            return L("已取消这次提问。")
        case .outputTooLarge:
            return L("外部客户端返回内容过大，PaperDesk 已停止读取。")
        case .invalidResponse:
            return L("外部客户端没有返回可识别的回答。")
        case .sessionMismatch:
            return L("外部客户端返回的对话不是当前绑定的对话。")
        }
    }
}

/// Validated MCP connector details injected into an external client launch.
struct MCPLaunchConfiguration: Sendable {
    let command: String?
    let arguments: [String]

    init(connector: String, arguments: [String]) throws {
        let value = connector.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            command = nil
            self.arguments = []
            return
        }
        let url = URL(fileURLWithPath: value).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ExternalQuestionRunnerError.connectorUnavailable
        }
        command = url.path
        self.arguments = arguments
    }
}

/// Generic local-process bridge for external clients. Harness-specific launch
/// arguments and output parsing live in the registered `QuestionClientAdapter`
/// implementations; this type only runs the process safely.
enum ExternalQuestionRunner {
    static let maximumRunDuration: TimeInterval = 30 * 60
    static let maximumOutputBytes = 32 * 1024 * 1024

    struct ProcessOutput: Sendable {
        let stdout: Data
        let stderr: Data
    }

    /// Finds a CLI without relying on the environment inherited by a GUI app.
    /// Finder-launched apps commonly do not receive Homebrew's PATH.
    static func executable(named name: String, extraCandidates: [String] = [],
                           appRelativeCandidates: [String] = []) -> URL? {
        let manager = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":", omittingEmptySubsequences: true).map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name).path
            })
        }
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        candidates += extraCandidates

        let appResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        candidates += appRelativeCandidates.map { appResources.appendingPathComponent($0).path }

        var seen = Set<String>()
        for candidate in candidates {
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(standardized).inserted,
                  manager.isExecutableFile(atPath: standardized) else { continue }
            return URL(fileURLWithPath: standardized)
        }
        return nil
    }

    static func runProcess(executable: URL, arguments: [String], environment: [String: String],
                           standardInput: String?, project: URL,
                           timeout: TimeInterval = maximumRunDuration) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        let holder = ProcessHolder()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = project
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        holder.set(process)

        do {
            try process.run()
        } catch {
            holder.clear()
            throw ExternalQuestionRunnerError.launchFailed
        }

        do {
            if let input = standardInput {
                try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            }
            try stdin.fileHandleForWriting.close()
        } catch {
            holder.terminate()
            throw ExternalQuestionRunnerError.launchFailed
        }

        let stdoutTask = Task.detached {
            do { return try Self.readAll(from: stdout.fileHandleForReading) }
            catch { holder.terminate(); throw error }
        }
        let stderrTask = Task.detached {
            do { return try Self.readAll(from: stderr.fileHandleForReading) }
            catch { holder.terminate(); throw error }
        }
        let deadline = Date().addingTimeInterval(timeout)

        do {
            try await withTaskCancellationHandler {
                while process.isRunning {
                    try Task.checkCancellation()
                    if Date() >= deadline {
                        holder.terminate()
                        throw ExternalQuestionRunnerError.timedOut
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } onCancel: {
                holder.terminate()
            }
        } catch is CancellationError {
            holder.terminate()
            throw ExternalQuestionRunnerError.cancelled
        } catch let error as ExternalQuestionRunnerError {
            holder.terminate()
            throw error
        }

        process.waitUntilExit()
        holder.clear()
        let output: Data
        let errorOutput: Data
        do {
            output = try await stdoutTask.value
            errorOutput = try await stderrTask.value
        } catch let error as ExternalQuestionRunnerError {
            throw error
        } catch {
            throw ExternalQuestionRunnerError.invalidResponse
        }
        // Keep stderr private.  It can contain a prompt echo or provider
        // details; only the exit code is exposed to the reader UI.
        _ = errorOutput
        guard process.terminationStatus == 0 else {
            throw ExternalQuestionRunnerError.processFailed(process.terminationStatus,
                                                            safeDiagnostic(from: errorOutput))
        }
        return ProcessOutput(stdout: output, stderr: errorOutput)
    }

    static func readAll(from handle: FileHandle) throws -> Data {
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return data }
            guard data.count <= maximumOutputBytes - chunk.count else {
                throw ExternalQuestionRunnerError.outputTooLarge
            }
            data.append(chunk)
        }
    }

    static func safeDiagnostic(from stderr: Data) -> String? {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        if text.contains("unauthorized") || text.contains("authentication") ||
            text.contains("not logged in") || text.contains("api key") {
            return L("认证失败")
        }
        if text.contains("permission denied") || text.contains("not permitted") {
            return L("权限不足")
        }
        if text.contains("timed out") || text.contains("timeout") {
            return L("网络或客户端超时")
        }
        if text.contains("mcp") {
            return L("MCP 连接失败")
        }
        if text.contains("config") || text.contains("invalid argument") {
            return L("客户端配置或参数无效")
        }
        if text.contains("not found") || text.contains("no such file") {
            return L("找不到所需程序或文件")
        }
        return nil
    }

    static func mergeStream(_ current: String?, _ next: String) -> String {
        guard let current, !current.isEmpty else { return next }
        if next == current || next.hasPrefix(current) { return next }
        if current.hasPrefix(next) || current.hasSuffix(next) || current.contains(next) { return current }
        return current + next
    }

    static func nonEmptyTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return title
    }

    private final class ProcessHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func set(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            self.process = process
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            process = nil
        }

        func terminate() {
            lock.lock(); defer { lock.unlock() }
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }
}
