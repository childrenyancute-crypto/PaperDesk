import Foundation
import Darwin
import PaperDeskCore

private let maximumMessageBytes = MCPLineCodec.maximumResponseBytes

private func address(for url: URL) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(url.path.utf8) + [0]
    // Keep the tuple's capacity outside the pointer closure. Referencing
    // `address.sun_path` from inside a closure that already has an inout
    // access to it is rejected by Swift as overlapping access (and can make
    // this otherwise straightforward sockaddr setup fail to compile).
    let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= sunPathCapacity else {
        throw PaperDeskError.invalid("资料库位置过长，请选择较短的本地路径。")
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: sunPathCapacity) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = byte }
        }
    }
    return address
}

private func configure(_ fd: Int32) {
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func readMessage(_ fd: Int32) throws -> Data {
    var accumulated = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            throw PaperDeskError.invalid("阅读窗口响应超时或连接中断。")
        }
        guard count > 0 else { throw PaperDeskError.invalid("阅读窗口提前关闭了连接。") }
        accumulated.append(contentsOf: buffer.prefix(count))
        guard accumulated.count <= maximumMessageBytes else { throw PaperDeskError.invalid("返回的内容过大，请缩小选区。") }
        if let end = accumulated.firstIndex(of: 10) { return accumulated.prefix(upTo: end) }
    }
}

private func writeMessage(_ data: Data, to fd: Int32) throws {
    guard data.count <= maximumMessageBytes - 1 else { throw PaperDeskError.invalid("内容过大，请缩小选区。") }
    var framed = data; framed.append(10)
    try framed.withUnsafeBytes { pointer in
        var offset = 0
        while offset < pointer.count {
            let count = Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw PaperDeskError.invalid("阅读窗口连接已中断。")
            }
            guard count > 0 else { throw PaperDeskError.invalid("阅读窗口连接无法写入。") }
            offset += count
        }
    }
}

public struct LocalBridgeClient {
    public let socketURL: URL
    public init(socketURL: URL) { self.socketURL = socketURL }
    public func call(method: String, arguments: JSONValue = .object([:])) throws -> JSONValue {
        var location = try address(for: socketURL)
        var info = stat()
        guard lstat(socketURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw PaperDeskError.missing("阅读助手未连接。请先打开 PaperDesk，并使用相同的资料库。")
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PaperDeskError.invalid("无法建立本机阅读连接。") }
        defer { Darwin.close(fd) }
        configure(fd)
        let connected = withUnsafePointer(to: &location) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw PaperDeskError.missing("阅读助手未连接。请先打开 PaperDesk。") }
        let request = BridgeRequest(method: method, arguments: arguments)
        try writeMessage(JSONEncoder().encode(request), to: fd)
        let response = try JSONDecoder().decode(BridgeResponse.self, from: readMessage(fd))
        guard response.id == request.id else { throw PaperDeskError.invalid("阅读窗口返回了不匹配的响应。") }
        if let error = response.error { throw PaperDeskError.invalid(error) }
        guard let result = response.result else { throw PaperDeskError.invalid("阅读窗口没有返回结果。") }
        return result
    }
}

public final class LocalBridgeServer: @unchecked Sendable {
    private let socketURL: URL
    private let handler: @Sendable (BridgeRequest) async -> BridgeResponse
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var ownsSocket = false
    public init(socketURL: URL, handler: @escaping @Sendable (BridgeRequest) async -> BridgeResponse) {
        self.socketURL = socketURL; self.handler = handler
    }
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listener < 0 else { return }
        var location = try address(for: socketURL)
        var info = stat()
        if lstat(socketURL.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                throw PaperDeskError.invalid("阅读连接位置被其他文件占用，请检查资料库。")
            }
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw PaperDeskError.invalid("无法检查已有阅读连接。") }
            configure(probe)
            let existing = withUnsafePointer(to: &location) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let connectionError = errno
            Darwin.close(probe)
            guard existing != 0 else { throw PaperDeskError.conflict("这个资料库已在另一个 PaperDesk 窗口中使用。") }
            guard connectionError == ECONNREFUSED || connectionError == ENOENT else {
                throw PaperDeskError.invalid("已有阅读连接暂不可访问。")
            }
            guard unlink(socketURL.path) == 0 || errno == ENOENT else { throw PaperDeskError.invalid("无法更新阅读连接。") }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PaperDeskError.invalid("无法创建本机阅读连接。") }
        var succeeded = false
        defer { if !succeeded { Darwin.close(fd) } }
        let bound = withUnsafePointer(to: &location) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw PaperDeskError.invalid("无法启动本机阅读连接。") }
        guard chmod(socketURL.path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            unlink(socketURL.path)
            throw PaperDeskError.invalid("无法保护本机阅读连接。")
        }
        listener = fd; ownsSocket = true; succeeded = true
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptConnections(fd) }
    }
    private func acceptConnections(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; break }
            configure(client)
            let handler = self.handler
            Task.detached(priority: .utility) {
                defer { Darwin.close(client) }
                do {
                    let request = try JSONDecoder().decode(BridgeRequest.self, from: readMessage(client))
                    let response = await handler(request)
                    let encoder = MCPLineCodec.responseEncoder()
                    let encoded = try encoder.encode(response)
                    if encoded.count < maximumMessageBytes {
                        try writeMessage(encoded, to: client)
                    } else {
                        let failure = BridgeResponse(id: request.id, error: "返回的内容过大，请缩小选区或分开读取。")
                        try writeMessage(encoder.encode(failure), to: client)
                    }
                } catch {
                    // Malformed local requests do not expose content or paths in diagnostics.
                }
            }
        }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if listener >= 0 { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1 }
        if ownsSocket { unlink(socketURL.path); ownsSocket = false }
    }
    deinit { stop() }
}
