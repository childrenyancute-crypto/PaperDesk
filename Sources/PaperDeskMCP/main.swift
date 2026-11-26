import Foundation
import Darwin
import PaperDeskCore
import PaperDeskBridge

private let version = "0.3.0"
private let readBufferSize = 64 * 1024

private func printUsage() {
    let usage = "paperdesk-mcp (\(version))\nUsage: paperdesk-mcp [--library PATH] [--paper-id ID --document-hash HASH] [--client-label LABEL] [--check-connection]\n\nConnects an AI client to one PaperDesk literature project over a local socket.\n"
    FileHandle.standardOutput.write(Data(usage.utf8))
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let baseAddress = buffer.baseAddress else { return }

        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(
                fileDescriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if written < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if written == 0 {
                throw POSIXError(.EPIPE)
            }
            offset += written
        }
    }
}

private func writeStdout(_ value: JSONValue) {
    let line: String
    do {
        line = try MCPLineCodec.encode(value)
    } catch {
        FileHandle.standardError.write(Data("paperdesk-mcp: failed to encode response\n".utf8))
        guard let id = value.objectValue?["id"], value["error"] == .null else { return }
        writeStdout(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(-32_000), "message": .string("PaperDesk response is too large. Request fewer selections or fetch each image separately.")])
        ]))
        return
    }
    do {
        try writeAll(Data((line + "\n").utf8), to: STDOUT_FILENO)
    } catch {
        FileHandle.standardError.write(Data("paperdesk-mcp: failed to write response\n".utf8))
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(EXIT_SUCCESS)
}
if arguments.contains("--version") {
    print(version)
    exit(EXIT_SUCCESS)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

let boundPaperID = option("--paper-id")
let boundDocumentHash = option("--document-hash")
let commandLineClientLabel = option("--client-label")
let questionRequestID = option("--question-request")
if arguments.contains("--paper-id") != arguments.contains("--document-hash") ||
   (arguments.contains("--paper-id") && (boundPaperID == nil || boundDocumentHash == nil)) {
    FileHandle.standardError.write(Data("paperdesk-mcp: --paper-id and --document-hash must be supplied together\n".utf8))
    exit(EXIT_FAILURE)
}

let root = LibraryPaths.root(arguments: arguments)
let client = LocalBridgeClient(socketURL: LibraryPaths.socket(root: root))
let protocolServer = MCPProtocol(serverVersion: version)
var pending = Data()
var discardingOversizedFrame = false
var clientName: String? = commandLineClientLabel
var clientVersion: String?
// A bound helper is not a live MCP connection until the peer has completed a
// successful initialize request. In particular, tools/list and a stray
// notifications/initialized notification must not make a pre-handshake
// process appear in PaperDesk's connection list. A successful initialize is
// sufficient even when a client omits clientInfo.name; the app can still
// identify that confirmed process by its PID.
private var completedInitialize = false
// A connection ID is the fallback for a new chat. A follow-up can identify
// its previous archived answer to continue the same chat after a reconnect.
let conversationID = "mcp-" + UUID().uuidString
let processID = getpid()

private struct HeartbeatContext: Sendable {
    let socketURL: URL
    let arguments: [String: JSONValue]
}

private var heartbeatContext: HeartbeatContext?
private var heartbeatTimer: DispatchSourceTimer?

private func sendHeartbeat(_ context: HeartbeatContext, method: String) {
    let heartbeatClient = LocalBridgeClient(socketURL: context.socketURL)
    _ = try? heartbeatClient.call(method: method, arguments: .object(context.arguments))
}

private func startHeartbeatIfNeeded() {
    guard completedInitialize, heartbeatContext == nil, let boundPaperID else { return }
    var heartbeatArguments: [String: JSONValue] = [:]
    heartbeatArguments["_bound_paper_id"] = .string(boundPaperID)
    if let boundDocumentHash { heartbeatArguments["_bound_document_hash"] = .string(boundDocumentHash) }
    if let clientName { heartbeatArguments["_client_name"] = .string(String(clientName.prefix(256))) }
    if let clientVersion { heartbeatArguments["_client_version"] = .string(String(clientVersion.prefix(256))) }
    heartbeatArguments["_conversation_id"] = .string(conversationID)
    heartbeatArguments["_client_pid"] = .number(Double(processID))
    if let questionRequestID { heartbeatArguments["_question_request"] = .string(questionRequestID) }
    let context = HeartbeatContext(socketURL: LibraryPaths.socket(root: root), arguments: heartbeatArguments)
    heartbeatContext = context
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "paperdesk.mcp.heartbeat"))
    timer.schedule(deadline: .now(), repeating: .seconds(10))
    timer.setEventHandler { sendHeartbeat(context, method: "__mcp_client_heartbeat") }
    timer.resume()
    heartbeatTimer = timer
}

func invokeReader(_ method: String, _ requestArguments: JSONValue) throws -> JSONValue {
    var object = requestArguments.objectValue ?? [:]
    // These fields are transport-owned. Always overwrite (or remove) values
    // supplied inside a model's tool arguments so a model cannot spoof the
    // paper binding or the client attribution stored in the library.
    if let boundPaperID { object["_bound_paper_id"] = .string(boundPaperID) }
    else { object.removeValue(forKey: "_bound_paper_id") }
    if let boundDocumentHash { object["_bound_document_hash"] = .string(boundDocumentHash) }
    else { object.removeValue(forKey: "_bound_document_hash") }
    if let clientName { object["_client_name"] = .string(String(clientName.prefix(256))) }
    else { object.removeValue(forKey: "_client_name") }
    if let clientVersion { object["_client_version"] = .string(String(clientVersion.prefix(256))) }
    else { object.removeValue(forKey: "_client_version") }
    object["_client_pid"] = .number(Double(processID))
    // Transport-owned conversation identity. A model cannot set this from its
    // tool arguments, so one MCP session cannot impersonate another.
    object["_conversation_id"] = .string(conversationID)
    if let questionRequestID { object["_question_request"] = .string(questionRequestID) }
    else { object.removeValue(forKey: "_question_request") }
    return try client.call(method: method, arguments: .object(object))
}

if arguments.contains("--check-connection") {
    do {
        let status = try invokeReader(MCPProtocol.connectionStatusTool, .object([:]))
        writeStdout(status)
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

// check_latex is pure computation over the reply text and does not need the
// reader connection, so it stays available even when the app is not running.
func localToolCall(_ method: String, _ arguments: JSONValue) throws -> JSONValue? {
    guard method == "check_latex" else { return nil }
    guard let text = arguments["text"].stringValue,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PaperDeskError.invalid("text is required")
    }
    return LatexSubset.checkResult(text: text)
}

// Requests and subscribed resource checks both run on the stdio loop.
final class Subscriptions: @unchecked Sendable {
    var revisions: [String: JSONValue] = [:]

    func invoke(_ method: String, _ arguments: JSONValue) throws -> JSONValue {
        switch method {
        case "__mcp_subscribe":
            guard let uri = arguments["uri"].stringValue,
                  revisions.count < 16 || revisions[uri] != nil else {
                throw PaperDeskError.invalid("订阅的阅读状态资源过多")
            }
            let revision = try invokeReader("__mcp_resource_revision", arguments)
            guard revision["isError"].boolValue != true else {
                throw PaperDeskError.missing("找不到阅读状态资源")
            }
            revisions[uri] = revision
            return .object([:])
        case "__mcp_unsubscribe":
            if let uri = arguments["uri"].stringValue { revisions.removeValue(forKey: uri) }
            return .object([:])
        default:
            return try invokeReader(method, arguments)
        }
    }

    func sendChanges() {
        for (uri, last) in revisions {
            guard let revision = try? invokeReader("__mcp_resource_revision", .object(["uri": .string(uri)])),
                  revision["isError"].boolValue != true, revision != last else { continue }
            revisions[uri] = revision
            writeStdout(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/resources/updated"),
                                 "params": .object(["uri": .string(uri)])]))
        }
    }
}
let subscriptions = Subscriptions()
var boundProjectContactSent = false

let processLine: (Data) -> Void = { lineData in
    if lineData.count > MCPLineCodec.maximumLineBytes {
        writeStdout(MCPLineCodec.parseErrorResponse())
        return
    }
    let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if line.isEmpty { return }
    do {
        let message = try MCPLineCodec.decode(line)
        let method = message["method"].stringValue
        var initializeSucceeded = false
        if let response = protocolServer.handle(message, invoke: { method, requestArguments in
            if let local = try localToolCall(method, requestArguments) { return local }
            return try subscriptions.invoke(method, requestArguments)
        }) {
            writeStdout(response)
            initializeSucceeded = method == "initialize" && response["error"] == .null
            if initializeSucceeded {
                let info = message["params"]["clientInfo"].objectValue
                if commandLineClientLabel == nil {
                    let discoveredName = info?["name"]?.stringValue ?? info?["title"]?.stringValue
                    if let discoveredName, !discoveredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        clientName = discoveredName
                    }
                }
                if let discoveredVersion = info?["version"]?.stringValue,
                   !discoveredVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    clientVersion = discoveredVersion
                }
                completedInitialize = true
            }
        }
        if boundPaperID != nil, !boundProjectContactSent,
           completedInitialize,
           initializeSucceeded || method == "notifications/initialized",
           let contact = try? invokeReader("__mcp_client_connected", .object([:])),
           contact["isError"].boolValue != true {
            boundProjectContactSent = true
        }
        startHeartbeatIfNeeded()
    } catch {
        writeStdout(MCPLineCodec.parseErrorResponse())
    }
}

let processPendingFrames: () -> Void = {
    while let newline = pending.firstIndex(of: 0x0A) {
        let lineData = Data(pending.prefix(upTo: newline))
        pending.removeSubrange(...newline)

        if discardingOversizedFrame {
            // The preceding partial frame exceeded the cap. Discard all of
            // its remaining bytes through the first newline, then resume
            // normal framing for the next message.
            discardingOversizedFrame = false
            continue
        }

        processLine(lineData)
    }

    // A peer that never sends a newline must not grow the process without a
    // bound. Once the cap is crossed, emit one parse error and discard the
    // partial frame until its newline arrives. This prevents the tail of an
    // oversized frame from being parsed as a fresh valid request.
    if discardingOversizedFrame {
        // Keep only the state bit while waiting for the terminating newline;
        // the discarded tail itself must not accumulate across reads.
        pending.removeAll(keepingCapacity: true)
    } else if pending.count > MCPLineCodec.maximumLineBytes {
        pending.removeAll(keepingCapacity: true)
        discardingOversizedFrame = true
        writeStdout(MCPLineCodec.parseErrorResponse())
    }
}

var readBuffer = [UInt8](repeating: 0, count: readBufferSize)
var reachedEOF = false

while !reachedEOF {
    var pollInput = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = Darwin.poll(&pollInput, 1, subscriptions.revisions.isEmpty ? -1 : 500)
    if ready == 0 {
        subscriptions.sendChanges()
        continue
    }
    if ready < 0 {
        if errno == EINTR { continue }
        break
    }
    let bytesRead = readBuffer.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
        guard let baseAddress = buffer.baseAddress else { return 0 }
        return Darwin.read(STDIN_FILENO, baseAddress, buffer.count)
    }

    if bytesRead < 0 {
        if errno == EINTR { continue }
        FileHandle.standardError.write(Data("paperdesk-mcp: stdin read failed\n".utf8))
        break
    }
    if bytesRead == 0 {
        reachedEOF = true
        break
    }

    pending.append(contentsOf: readBuffer[0..<bytesRead])
    processPendingFrames()
}

// Be liberal for embedders that close stdin after a single JSON object
// without a final newline.
if reachedEOF && !discardingOversizedFrame && !pending.isEmpty {
    processLine(pending)
}

// Best-effort disconnect so PaperDesk can clear the live connection promptly;
// killed processes are covered by the reader's heartbeat timeout.
if let heartbeatContext {
    heartbeatTimer?.cancel()
    sendHeartbeat(heartbeatContext, method: "__mcp_client_disconnected")
}
