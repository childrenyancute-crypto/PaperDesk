import XCTest
@testable import PaperDeskCore

final class MCPProtocolTests: XCTestCase {
    private let protocolServer = MCPProtocol()

    func testInitializeNegotiatesUnsupportedVersionToLatest() throws {
        let response = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("future-version")])
        ]), invoke: { _, _ in .object([:]) }))
        XCTAssertEqual(response["result"]["protocolVersion"].stringValue, MCPProtocol.latestProtocolVersion)
        XCTAssertEqual(response["result"]["serverInfo"]["name"].stringValue, "PaperDesk")
    }

    func testInitializedNotificationProducesNoResponse() {
        let response = protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "method": .string("notifications/initialized")
        ]), invoke: { _, _ in .object([:]) })
        XCTAssertNil(response)
    }

    func testToolsListIncludesReadAndWriteHints() throws {
        let response = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .string("list"), "method": .string("tools/list"), "params": .object([:])
        ]), invoke: { _, _ in .object([:]) }))
        let tools = try XCTUnwrap(response["result"]["tools"].arrayValue)
        let write = try XCTUnwrap(tools.first { $0["name"].stringValue == "set_reading_goal" })
        let read = try XCTUnwrap(tools.first { $0["name"].stringValue == "get_context" })
        XCTAssertEqual(write["annotations"]["readOnlyHint"].boolValue, false)
        XCTAssertEqual(write["annotations"]["idempotentHint"].boolValue, true)
        XCTAssertEqual(read["annotations"]["readOnlyHint"].boolValue, true)
        XCTAssertEqual(write["inputSchema"]["additionalProperties"].boolValue, false)
    }

    func testCitationToolReplacesAIFocusAndSaveDiscussionAcceptsCitations() throws {
        let response = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .string("list"), "method": .string("tools/list"), "params": .object([:])
        ]), invoke: { _, _ in .object([:]) }))
        let tools = try XCTUnwrap(response["result"]["tools"].arrayValue)
        let names = Set(tools.compactMap { $0["name"].stringValue })
        XCTAssertTrue(names.contains("cite_passage"))
        XCTAssertFalse(names.contains("mark_reading_focus"))
        let save = try XCTUnwrap(tools.first { $0["name"].stringValue == "save_discussion" })
        XCTAssertTrue(save["inputSchema"]["properties"].objectValue?.keys.contains("citations") == true)
        let cite = try XCTUnwrap(tools.first { $0["name"].stringValue == "cite_passage" })
        XCTAssertEqual(cite["inputSchema"]["required"].arrayValue?.compactMap { $0.stringValue }, ["snapshot_id"])
    }

    func testToolCallDispatchesAndWrapsResult() throws {
        let response = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("call"),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("get_context"),
                "arguments": .object(["context_id": .string("ctx")])
            ])
        ]), invoke: { method, args in
            XCTAssertEqual(method, "get_context")
            XCTAssertEqual(args["context_id"].stringValue, "ctx")
            return .object(["content": .array([.object(["type": .string("text"), "text": .string("ok")])])])
        }))
        XCTAssertEqual(response["result"]["content"][0]["text"].stringValue, "ok")
        XCTAssertNil(response["error"].stringValue)
    }

    func testOfflineBridgeIsToolError() throws {
        let response = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
            "params": .object(["name": .string("reading_status"), "arguments": .object([:])])
        ]), invoke: { _, _ in throw PaperDeskError.missing("PaperDesk reader is not running") }))
        XCTAssertEqual(response["result"]["isError"].boolValue, true)
        XCTAssertEqual(response["result"]["content"][0]["type"].stringValue, "text")
    }

    func testInvalidParamsAndUnknownToolUseJsonRpcErrors() throws {
        let invalid = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(3), "method": .string("tools/call"), "params": .object([:])
        ]), invoke: { _, _ in .object([:]) }))
        XCTAssertEqual(invalid["error"]["code"].intValue, -32_602)

        let unknown = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(4), "method": .string("tools/call"),
            "params": .object(["name": .string("unknown_tool"), "arguments": .object([:])])
        ]), invoke: { _, _ in .object([:]) }))
        XCTAssertEqual(unknown["error"]["code"].intValue, -32_601)
    }

    func testInstructionsDescribeTheMathSubset() {
        XCTAssertTrue(MCPProtocol.instructions.contains("check_latex"))
        XCTAssertTrue(MCPProtocol.instructions.contains("aligned"))
        XCTAssertTrue(MCPProtocol.instructions.contains("2048"))
    }

    func testCheckLatexToolIsListed() throws {
        let response = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .string("list"), "method": .string("tools/list"), "params": .object([:])
        ]), invoke: { _, _ in .object([:]) }))
        let tools = try XCTUnwrap(response["result"]["tools"].arrayValue)
        let check = try XCTUnwrap(tools.first { $0["name"].stringValue == "check_latex" })
        XCTAssertEqual(check["annotations"]["readOnlyHint"].boolValue, true)
        XCTAssertEqual(check["inputSchema"]["required"][0].stringValue, "text")
        XCTAssertEqual(check["inputSchema"]["additionalProperties"].boolValue, false)
    }

    func testCheckLatexResultIsForwarded() throws {
        let response = try XCTUnwrap(protocolServer.handle(.object([
            "jsonrpc": .string("2.0"), "id": .string("call"), "method": .string("tools/call"),
            "params": .object(["name": .string("check_latex"), "arguments": .object(["text": .string("$x$")])])
        ]), invoke: { method, args in
            XCTAssertEqual(method, "check_latex")
            return LatexSubset.checkResult(text: args["text"].stringValue ?? "")
        }))
        XCTAssertEqual(response["result"]["isError"].boolValue, false)
        XCTAssertTrue(response["result"]["content"][0]["text"].stringValue?.contains("all renderable") ?? false)
    }
}
