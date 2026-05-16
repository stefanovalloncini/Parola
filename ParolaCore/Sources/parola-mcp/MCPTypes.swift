import Foundation

// MARK: - JSON-RPC envelope

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: AnyDecodable?
}

struct JSONRPCResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID?
    let result: AnyEncodable?
    let error: JSONRPCError?

    static func success(id: JSONRPCID?, result: any Encodable) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: AnyEncodable(result), error: nil)
    }
    static func failure(id: JSONRPCID?, code: Int, message: String, data: (any Encodable)? = nil) -> JSONRPCResponse {
        let err = JSONRPCError(code: code, message: message, data: data.map(AnyEncodable.init))
        return JSONRPCResponse(id: id, result: nil, error: err)
    }
}

struct JSONRPCError: Encodable {
    let code: Int
    let message: String
    let data: AnyEncodable?
}

enum JSONRPCID: Codable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

// MARK: - AnyDecodable / AnyEncodable

struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self) { value = s; return }
        if let a = try? c.decode([AnyDecodable].self) { value = a.map(\.value); return }
        if let o = try? c.decode([String: AnyDecodable].self) {
            value = o.mapValues(\.value); return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON type")
    }
}

struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) {
        _encode = value.encode(to:)
    }
    init(_ value: Any) {
        _encode = { encoder in
            var container = encoder.singleValueContainer()
            try AnyEncodable.encodeAny(value, into: &container)
        }
    }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }

    private static func encodeAny(_ value: Any, into container: inout SingleValueEncodingContainer) throws {
        switch value {
        case is NSNull: try container.encodeNil()
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]:
            try container.encode(v.map(AnyEncodable.init))
        case let v as [String: Any]:
            try container.encode(v.mapValues(AnyEncodable.init))
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - MCP protocol structures

struct MCPInitializeResult: Encodable {
    let protocolVersion: String
    let capabilities: Capabilities
    let serverInfo: ServerInfo

    struct Capabilities: Encodable {
        let tools: ToolsCapability
    }
    struct ToolsCapability: Encodable {
        let listChanged: Bool
    }
    struct ServerInfo: Encodable {
        let name: String
        let version: String
    }
}

struct MCPTool: Encodable {
    let name: String
    let description: String
    let inputSchema: AnyEncodable
}

struct MCPListToolsResult: Encodable {
    let tools: [MCPTool]
}

struct MCPToolCallResult: Encodable {
    let content: [MCPContentBlock]
    let isError: Bool

    init(text: String, isError: Bool = false) {
        self.content = [MCPContentBlock(type: "text", text: text)]
        self.isError = isError
    }
}

struct MCPContentBlock: Encodable {
    let type: String
    let text: String
}

// MARK: - JSON-RPC error codes

enum RPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}
