import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { objectValue?[key] ?? .null }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var intValue: Int? {
        if case .number(let v) = self, v.isFinite, v.rounded() == v, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }
        return nil
    }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
    public func encodedText() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    public static func textResult(_ text: String, isError: Bool = false) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }
}

public struct BridgeRequest: Codable, Sendable {
    public var id: String
    public var method: String
    public var arguments: JSONValue
    public init(id: String = UUID().uuidString, method: String, arguments: JSONValue = .object([:])) {
        self.id = id; self.method = method; self.arguments = arguments
    }
}

public struct BridgeResponse: Codable, Sendable {
    public var id: String
    public var result: JSONValue?
    public var error: String?
    public init(id: String, result: JSONValue? = nil, error: String? = nil) {
        self.id = id; self.result = result; self.error = error
    }
}
