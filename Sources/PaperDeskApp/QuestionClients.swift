import Foundation
import PaperDeskCore

/// One external AI harness PaperDesk can talk to. Adding a harness means adding
/// one adapter to `QuestionClientRegistry`; the status UI and send picker pick
/// it up automatically.
protocol QuestionClientAdapter: Sendable {
    /// Stable identifier persisted in question bindings. Existing values are
    /// `codex` and `opencode`.
    var id: String { get }
    var displayName: String { get }
    var iconName: String { get }
    var sessionIDHint: String { get }

    /// Maps an MCP `clientInfo.name` (or a configured client label) to this
    /// adapter.
    func matches(clientName: String?) -> Bool
    func executableURL() -> URL?
    func normalize(sessionID: String) -> String
    func isValidSessionID(_ id: String) -> Bool

    func send(project: URL, sessionID: String?, prompt: String,
              connector: String, connectorArguments: [String]) async throws -> ExternalQuestionAnswer
    func conversationTitles(sessionIDs: [String], project: URL) async -> [String: String]

    /// Writes this harness's MCP configuration into the paper project so the
    /// external client can connect to PaperDesk.
    func writeProjectConfiguration(project: URL, connector: URL, arguments: [String]) throws
}

extension QuestionClientAdapter {
    func isAvailable() -> Bool { executableURL() != nil }
}

enum QuestionClientRegistry {
    static let adapters: [any QuestionClientAdapter] = [
        CodexQuestionAdapter(),
        OpenCodeQuestionAdapter()
    ]

    static func adapter(id: String) -> (any QuestionClientAdapter)? {
        adapters.first { $0.id == id }
    }

    static func adapter(clientName: String?) -> (any QuestionClientAdapter)? {
        guard let name = clientName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return adapters.first { $0.matches(clientName: name) }
    }

    static func displayName(id: String) -> String {
        adapter(id: id)?.displayName ?? id
    }

    static func displayName(clientName: String?) -> String {
        if let adapter = adapter(clientName: clientName) { return adapter.displayName }
        let raw = clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? L("未知客户端") : raw
    }

    static func iconName(id: String?) -> String {
        guard let id, let adapter = adapter(id: id) else {
            return "bubble.left.and.bubble.right"
        }
        return adapter.iconName
    }

    static func executableURL(id: String) -> URL? {
        adapter(id: id)?.executableURL()
    }
}

// MARK: - Codex

struct CodexQuestionAdapter: QuestionClientAdapter {
    let id = "codex"
    let displayName = "Codex"
    let iconName = "terminal"
    let sessionIDHint = "UUID"

    func matches(clientName: String?) -> Bool {
        let lowered = clientName?.lowercased() ?? ""
        return lowered.contains("codex") || lowered.contains("chatgpt")
    }

    func executableURL() -> URL? {
        ExternalQuestionRunner.executable(
            named: "codex",
            extraCandidates: [
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
            ],
            appRelativeCandidates: [
                "codex",
                "codex-cli/bin/codex",
                "codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ]
        )
    }

    func normalize(sessionID: String) -> String {
        sessionID.lowercased()
    }

    func isValidSessionID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    func send(project: URL, sessionID: String?, prompt: String,
              connector: String, connectorArguments: [String]) async throws -> ExternalQuestionAnswer {
        try Task.checkCancellation()
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw ExternalQuestionRunnerError.emptyPrompt }
        let projectURL = project.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ExternalQuestionRunnerError.invalidProject }
        guard let executable = executableURL() else {
            throw ExternalQuestionRunnerError.executableUnavailable(displayName)
        }
        let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSessionID = normalizedSessionID?.isEmpty == false ? normalize(sessionID: normalizedSessionID!) : nil
        let mcp = try MCPLaunchConfiguration(connector: connector, arguments: connectorArguments)

        var arguments = ["exec"]
        if effectiveSessionID != nil { arguments.append("resume") }
        arguments += ["--json", "--skip-git-repo-check"]
        // `resume` intentionally has no --cd option. Its process working
        // directory is set to the paper project below, while a new session gets
        // an explicit project root.
        if effectiveSessionID == nil { arguments += ["--cd", projectURL.path] }
        arguments += ["-c", "sandbox_mode=\"read-only\""]
        if let command = mcp.command {
            arguments += ["-c", "mcp_servers.paperdesk.command=\(tomlString(command))"]
            arguments += ["-c", "mcp_servers.paperdesk.args=\(tomlArray(mcp.arguments))"]
        }
        if let effectiveSessionID { arguments.append(effectiveSessionID) }
        // Codex documents `-` as the stdin prompt.
        arguments.append("-")

        let output = try await ExternalQuestionRunner.runProcess(
            executable: executable, arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            standardInput: trimmedPrompt, project: projectURL)
        let parsed = parse(output.stdout)
        guard let answer = parsed.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
              let reported = parsed.sessionID, !reported.isEmpty else {
            throw ExternalQuestionRunnerError.invalidResponse
        }
        let sessionID = normalize(sessionID: reported)
        if let effectiveSessionID, sessionID != effectiveSessionID {
            throw ExternalQuestionRunnerError.sessionMismatch
        }
        guard isValidSessionID(sessionID) else { throw ExternalQuestionRunnerError.invalidResponse }
        let title = await conversationTitles(sessionIDs: [sessionID], project: projectURL)[sessionID]
        return ExternalQuestionAnswer(sessionID: sessionID, answer: answer, conversationTitle: title)
    }

    func conversationTitles(sessionIDs: [String], project: URL) async -> [String: String] {
        let identifiers = Set(sessionIDs.filter { !$0.isEmpty })
        guard !Task.isCancelled, !identifiers.isEmpty else { return [:] }
        let wanted = Set(identifiers.map { $0.lowercased() })
        let environment = ProcessInfo.processInfo.environment
        let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome: URL
        if let configuredHome, !configuredHome.isEmpty {
            let expandedPath: String
            if configuredHome == "~" {
                expandedPath = NSHomeDirectory()
            } else if configuredHome.hasPrefix("~/") {
                expandedPath = (NSHomeDirectory() as NSString).appendingPathComponent(String(configuredHome.dropFirst(2)))
            } else {
                expandedPath = configuredHome
            }
            codexHome = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        guard let contents = try? String(contentsOf: index, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rowID = row["id"] as? String,
                  wanted.contains(rowID.lowercased()), result[rowID.lowercased()] == nil,
                  let title = ExternalQuestionRunner.nonEmptyTitle(row["thread_name"] as? String) else { continue }
            result[rowID.lowercased()] = title
            if result.count == wanted.count { break }
        }
        return result
    }

    func writeProjectConfiguration(project: URL, connector: URL, arguments: [String]) throws {
        let configuration = project.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func quote(_ value: String) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let quotedArguments = try arguments.map(quote)
        let connection = """
        [mcp_servers.paperdesk]
        command = \(try quote(connector.path))
        args = [\(quotedArguments.joined(separator: ", "))]
        tool_timeout_sec = 60
        """
        let previousTools = ["capture_reading_state", "save_discussion", "save_extractive_summary"]
        let legacyTools = ["capture_reading_state", "save_discussion", "save_note", "save_extractive_summary"]
        func serverConfig(allowed tools: [String]) -> String {
            let permissions = tools.map { "[mcp_servers.paperdesk.tools.\($0)]\napproval_mode = \"approve\"" }
            return ([connection] + permissions).joined(separator: "\n\n") + "\n"
        }
        let server = serverConfig(allowed: previousTools + ["set_reading_goal", "submit_note_draft"])
        let legacyServer = serverConfig(allowed: legacyTools + ["submit_note_draft"])
        let configURL = configuration.appendingPathComponent("config.toml")
        let oldConfig = try? String(contentsOf: configURL, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: configURL.path) || oldConfig == connection || oldConfig == legacyServer {
            try server.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    private func tomlString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private func tomlArray(_ values: [String]) -> String {
        "[" + values.map(tomlString).joined(separator: ",") + "]"
    }

    private struct ParsedResponse {
        var sessionID: String?
        var answer: String?
    }

    private func parse(_ output: Data) -> ParsedResponse {
        var response = ParsedResponse()
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) else { continue }
            collectSessionID(from: object, into: &response.sessionID)
            collectAnswer(from: object, into: &response.answer)
        }
        return response
    }

    private func collectSessionID(from value: Any, into result: inout String?) {
        guard let dictionary = value as? [String: Any], result == nil else { return }
        let eventType = (dictionary["type"] as? String)?.lowercased()
        // The Codex JSONL protocol puts the authoritative thread id on the
        // top-level thread.started event. Do not walk tool results.
        if eventType == "thread.started" || eventType == "thread_started",
           let candidate = dictionary["thread_id"] as? String, !candidate.isEmpty {
            result = candidate
        }
    }

    private func collectAnswer(from value: Any, into answer: inout String?) {
        guard let dictionary = value as? [String: Any] else {
            if let array = value as? [Any] {
                for element in array { collectAnswer(from: element, into: &answer) }
            }
            return
        }
        let eventType = (dictionary["type"] as? String)?.lowercased()
        if eventType == "item.completed" || eventType == "item_completed" {
            if let item = dictionary["item"] as? [String: Any],
               let itemType = (item["type"] as? String)?.lowercased(),
               ["agent_message", "assistant_message", "assistant"].contains(itemType),
               let text = item["text"] as? String {
                answer = text
            }
        }
        if let role = (dictionary["role"] as? String)?.lowercased(), role == "assistant",
           let text = dictionary["text"] as? String {
            answer = text
        }
        for key in ["item", "message", "output", "response", "parts"] {
            if let child = dictionary[key] { collectAnswer(from: child, into: &answer) }
        }
    }
}

// MARK: - OpenCode

struct OpenCodeQuestionAdapter: QuestionClientAdapter {
    let id = "opencode"
    let displayName = "OpenCode"
    let iconName = "chevron.left.forwardslash.chevron.right"
    let sessionIDHint = "ses_…"

    func matches(clientName: String?) -> Bool {
        let lowered = clientName?.lowercased() ?? ""
        return lowered.contains("opencode") || lowered.contains("open code")
    }

    func executableURL() -> URL? {
        ExternalQuestionRunner.executable(named: "opencode", appRelativeCandidates: ["opencode"])
    }

    func normalize(sessionID: String) -> String { sessionID }

    func isValidSessionID(_ id: String) -> Bool {
        id.hasPrefix("ses_") && id.count > 4 && id.count <= 160 &&
            id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
            }
    }

    func send(project: URL, sessionID: String?, prompt: String,
              connector: String, connectorArguments: [String]) async throws -> ExternalQuestionAnswer {
        try Task.checkCancellation()
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw ExternalQuestionRunnerError.emptyPrompt }
        let projectURL = project.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ExternalQuestionRunnerError.invalidProject }
        guard let executable = executableURL() else {
            throw ExternalQuestionRunnerError.executableUnavailable(displayName)
        }
        let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSessionID = normalizedSessionID?.isEmpty == false ? normalizedSessionID : nil
        let mcp = try MCPLaunchConfiguration(connector: connector, arguments: connectorArguments)
        var arguments = ["run", "--format", "json", "--dir", projectURL.path]
        if let effectiveSessionID { arguments += ["--session", effectiveSessionID] }

        let output = try await ExternalQuestionRunner.runProcess(
            executable: executable, arguments: arguments,
            environment: opencodeEnvironment(mcp: mcp),
            standardInput: trimmedPrompt, project: projectURL)
        let parsed = parse(output.stdout)
        guard let answer = parsed.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
              let reported = parsed.sessionID, isValidSessionID(reported) else {
            throw ExternalQuestionRunnerError.invalidResponse
        }
        if let effectiveSessionID, reported != effectiveSessionID {
            throw ExternalQuestionRunnerError.sessionMismatch
        }
        let title = await conversationTitles(sessionIDs: [reported], project: projectURL)[reported]
        return ExternalQuestionAnswer(sessionID: reported, answer: answer, conversationTitle: title)
    }

    func conversationTitles(sessionIDs: [String], project: URL) async -> [String: String] {
        let identifiers = Set(sessionIDs.filter { !$0.isEmpty })
        guard !Task.isCancelled, !identifiers.isEmpty, let executable = executableURL() else { return [:] }
        let arguments = ["session", "list", "--pure", "--max-count", "10000", "--format", "json"]
        guard let output = try? await ExternalQuestionRunner.runProcess(
            executable: executable, arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            standardInput: nil, project: project, timeout: 10) else { return [:] }
        guard let rows = try? JSONSerialization.jsonObject(with: output.stdout) as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for row in rows {
            guard let rowID = row["id"] as? String, identifiers.contains(rowID), result[rowID] == nil,
                  let title = ExternalQuestionRunner.nonEmptyTitle(row["title"] as? String) else { continue }
            result[rowID] = title
            if result.count == identifiers.count { break }
        }
        return result
    }

    func writeProjectConfiguration(project: URL, connector: URL, arguments: [String]) throws {
        let url = project.appendingPathComponent("opencode.json")
        var existingData: Data?
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            // An existing client configuration is user-owned. Keep it intact
            // when it cannot be decoded instead of silently replacing it with
            // a PaperDesk-only file.
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let existing = object as? [String: Any] else { return }
            existingData = data
            root = existing
        }
        if let mcp = root["mcp"], !(mcp is [String: Any]) { return }
        var servers = root["mcp"] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["type": "local", "enabled": true]
        if let current = servers["paperdesk"] {
            guard let settings = current as? [String: Any], settings["type"] as? String == "local" else {
                throw PaperDeskError.conflict(L("已保留原有的 OpenCode PaperDesk 配置，因为它不是可识别的本地连接。",
                                                "The existing OpenCode PaperDesk configuration was kept because it is not a recognized local connection."))
            }
            entry = settings
        }
        entry["command"] = [connector.path] + arguments
        servers["paperdesk"] = entry
        if root["$schema"] == nil { root["$schema"] = "https://opencode.ai/config.json" }
        root["mcp"] = servers
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data != existingData else { return }
        try data.write(to: url, options: .atomic)
    }

    private func opencodeEnvironment(mcp: MCPLaunchConfiguration) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let command = mcp.command else { return environment }
        var configuration = (environment["OPENCODE_CONFIG_CONTENT"].flatMap { data in
            try? JSONSerialization.jsonObject(with: Data(data.utf8))
        } as? [String: Any]) ?? [:]
        var servers = configuration["mcp"] as? [String: Any] ?? [:]
        servers["paperdesk"] = [
            "type": "local",
            "command": [command] + mcp.arguments,
            "enabled": true
        ]
        configuration["mcp"] = servers
        if let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
           let content = String(data: data, encoding: .utf8) {
            environment["OPENCODE_CONFIG_CONTENT"] = content
        }
        return environment
    }

    private struct ParsedResponse {
        var sessionID: String?
        var answer: String?
        var partOrder: [String] = []
        var partText: [String: String] = [:]

        mutating func appendPart(id: String?, text: String) {
            guard let id, !id.isEmpty else {
                answer = ExternalQuestionRunner.mergeStream(answer, text)
                return
            }
            if partText[id] == nil { partOrder.append(id) }
            partText[id] = ExternalQuestionRunner.mergeStream(partText[id], text)
            answer = partOrder.compactMap { partText[$0] }.joined()
        }
    }

    private func parse(_ output: Data) -> ParsedResponse {
        var response = ParsedResponse()
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if response.sessionID == nil, let candidate = object["sessionID"] as? String, !candidate.isEmpty {
                response.sessionID = candidate
            }
            let eventType = (object["type"] as? String)?.lowercased()
            if eventType == "text" {
                if let part = object["part"] as? [String: Any], let text = part["text"] as? String {
                    if response.sessionID == nil, let candidate = part["sessionID"] as? String, !candidate.isEmpty {
                        response.sessionID = candidate
                    }
                    response.appendPart(id: part["id"] as? String, text: text)
                } else if let text = object["text"] as? String {
                    response.appendPart(id: nil, text: text)
                }
            }
        }
        return response
    }
}
