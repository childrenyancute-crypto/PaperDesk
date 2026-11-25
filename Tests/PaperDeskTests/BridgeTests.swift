import XCTest
import Foundation
import PaperDeskCore
import PaperDeskBridge

final class BridgeTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/pd-\(UUID().uuidString.prefix(10))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRoundTripAndSocketPermissions() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = LibraryPaths.socket(root: root)
        let server = LocalBridgeServer(socketURL: socket) { request in
            BridgeResponse(id: request.id, result: request.arguments)
        }
        try server.start(); defer { server.stop() }
        let input = JSONValue.object(["text": .string("公式与笔记\nsecond line"), "page": .number(3)])
        let result = try LocalBridgeClient(socketURL: socket).call(method: "echo", arguments: input)
        XCTAssertEqual(result, input)
        let permissions = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testSecondServerCannotReplaceLiveReader() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = LibraryPaths.socket(root: root)
        let first = LocalBridgeServer(socketURL: socket) { request in BridgeResponse(id: request.id, result: .string("first")) }
        try first.start(); defer { first.stop() }
        let second = LocalBridgeServer(socketURL: socket) { request in BridgeResponse(id: request.id, result: .string("second")) }
        XCTAssertThrowsError(try second.start())
        XCTAssertEqual(try LocalBridgeClient(socketURL: socket).call(method: "status"), .string("first"))
    }

    func testOfflineAndNonSocketPathsFailClearly() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = LibraryPaths.socket(root: root)
        let client = LocalBridgeClient(socketURL: socket)
        XCTAssertThrowsError(try client.call(method: "status"))
        try Data("not a socket".utf8).write(to: socket)
        let server = LocalBridgeServer(socketURL: socket) { request in BridgeResponse(id: request.id, result: .null) }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: socket, encoding: .utf8), "not a socket")
    }

    func testStoppedServerRemovesSocket() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = LibraryPaths.socket(root: root)
        let server = LocalBridgeServer(socketURL: socket) { request in BridgeResponse(id: request.id, result: .null) }
        try server.start(); server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }
}
