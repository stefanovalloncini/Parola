import Foundation
import Network

public enum ScenarioError: Error, CustomStringConvertible {
    case discovery(String)
    case connection(String)
    case bridge(String)
    public var description: String {
        switch self {
        case .discovery(let s): return "discovery: \(s)"
        case .connection(let s): return "connection: \(s)"
        case .bridge(let s): return "bridge: \(s)"
        }
    }
}

/// A parsed JSON value returned by the bridge. Sendable so it can cross the
/// `ScenarioBridgeClient` actor boundary back to a test.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if CFNumberIsFloatType(n) { self = .double(n.doubleValue) }
            else { self = .int(n.intValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init))
        case let o as [String: Any]:
            self = .object(o.mapValues(JSONValue.init))
        default: self = .string(String(describing: any))
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? { if case .int(let i) = self { return i }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

/// Connects to a running Parola debug build's automation bridge over loopback and
/// sends line-delimited JSON commands. Reads port + token from ~/Library/Caches/Parola/.
public actor ScenarioBridgeClient {
    private let connection: NWConnection
    private let token: String
    private var buffer = Data()
    private var nextID = 0

    public init() throws {
        let dir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Parola", isDirectory: true)
        func read(_ name: String) throws -> String {
            do { return try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            catch { throw ScenarioError.discovery("missing \(name): \(error.localizedDescription)") }
        }
        let portStr = try read("bridge.port")
        self.token = try read("bridge.token")
        guard let p = UInt16(portStr), let port = NWEndpoint.Port(rawValue: p) else {
            throw ScenarioError.discovery("bad port \(portStr)")
        }
        self.connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    }

    public func connect(timeout: Duration = .seconds(5)) async throws {
        let resumed = ResumeGuard()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { cont.resume() }
                case .failed(let e):
                    if resumed.claim() { cont.resume(throwing: ScenarioError.connection("\(e)")) }
                case .cancelled:
                    if resumed.claim() { cont.resume(throwing: ScenarioError.connection("cancelled")) }
                default: break
                }
            }
            connection.start(queue: .global())
            let conn = connection
            Task {
                try? await Task.sleep(for: timeout)
                if resumed.claim() {
                    conn.cancel()
                    cont.resume(throwing: ScenarioError.connection("connect timed out"))
                }
            }
        }
        connection.stateUpdateHandler = nil
    }

    /// Sends a command and returns the response's `result` object.
    /// Throws `ScenarioError.bridge` when the server reports `ok: false`.
    @discardableResult
    public func send(_ cmd: String, _ args: [String: Any] = [:]) async throws -> JSONValue {
        nextID += 1
        let payload: [String: Any] = ["id": "\(nextID)", "cmd": cmd, "args": args, "auth": token]
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0a)
        try await sendData(line)
        let responseData = try await readLine()
        guard let obj = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw ScenarioError.bridge("non-object response")
        }
        let ok = obj["ok"] as? Bool ?? false
        if !ok {
            let error = obj["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "INTERNAL"
            let message = error?["message"] as? String ?? "unknown error"
            throw ScenarioError.bridge("\(code): \(message)")
        }
        return JSONValue(obj["result"])
    }

    private func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: ScenarioError.connection("\(error)")) }
                else { cont.resume() }
            })
        }
    }

    private func readLine() async throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                if buffer.isEmpty { throw ScenarioError.connection("closed before newline") }
                let line = buffer; buffer.removeAll(); return line
            }
            buffer.append(chunk)
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { cont.resume(throwing: ScenarioError.connection("\(error)")); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    public func close() { connection.cancel() }
}

// Safe: all mutable state is guarded by the NSLock; NWConnection's state handler may fire on any queue.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
