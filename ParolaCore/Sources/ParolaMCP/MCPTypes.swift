import Foundation

// MARK: - JSON-RPC envelope

public struct JSONRPCRequest: Decodable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: AnyDecodable?

    public init(jsonrpc: String, id: JSONRPCID?, method: String, params: AnyDecodable?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: JSONRPCID?
    public let result: AnyEncodable?
    public let error: JSONRPCError?

    public static func success(id: JSONRPCID?, result: any Encodable & Sendable) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: AnyEncodable(result), error: nil)
    }
    public static func failure(id: JSONRPCID?, code: Int, message: String, data: (any Encodable & Sendable)? = nil) -> JSONRPCResponse {
        let err = JSONRPCError(code: code, message: message, data: data.map(AnyEncodable.init))
        return JSONRPCResponse(id: id, result: nil, error: err)
    }
}

public struct JSONRPCError: Encodable, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyEncodable?
}

public enum JSONRPCID: Codable, Sendable, Hashable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

// MARK: - AnyDecodable / AnyEncodable

/// Unchecked Sendable: `value` is a `let` set once at init and never mutated.
public struct AnyDecodable: Decodable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
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

/// Unchecked Sendable: `_encode` is an immutable `let` closure; the captured `Any` is read-only after init.
public struct AnyEncodable: Encodable, @unchecked Sendable {
    private let _encode: (Encoder) throws -> Void
    public init<T: Encodable>(_ value: T) {
        _encode = value.encode(to:)
    }
    public init(_ value: Any) {
        // nonisolated(unsafe): the closure runs synchronously inside `encode(to:)`, never hops actors.
        nonisolated(unsafe) let captured = value
        _encode = { encoder in
            var container = encoder.singleValueContainer()
            try AnyEncodable.encodeAny(captured, into: &container)
        }
    }
    public func encode(to encoder: Encoder) throws { try _encode(encoder) }

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

public struct MCPInitializeResult: Encodable, Sendable {
    public let protocolVersion: String
    public let capabilities: Capabilities
    public let serverInfo: ServerInfo

    public struct Capabilities: Encodable, Sendable {
        public let tools: ToolsCapability
        public init(tools: ToolsCapability) { self.tools = tools }
    }
    public struct ToolsCapability: Encodable, Sendable {
        public let listChanged: Bool
        public init(listChanged: Bool) { self.listChanged = listChanged }
    }
    public struct ServerInfo: Encodable, Sendable {
        public let name: String
        public let version: String
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public init(protocolVersion: String, capabilities: Capabilities, serverInfo: ServerInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

public struct MCPTool: Encodable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: AnyEncodable

    public init(name: String, description: String, inputSchema: AnyEncodable) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPListToolsResult: Encodable, Sendable {
    public let tools: [MCPTool]
    public init(tools: [MCPTool]) { self.tools = tools }
}

public struct MCPToolCallResult: Encodable, Sendable {
    public let content: [MCPContentBlock]
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.content = [MCPContentBlock(type: "text", text: text)]
        self.isError = isError
    }
}

public struct MCPContentBlock: Encodable, Sendable {
    public let type: String
    public let text: String
}

// MARK: - JSON-RPC error codes

public enum RPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}
