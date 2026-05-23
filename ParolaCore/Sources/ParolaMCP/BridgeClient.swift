import Darwin
import Foundation

/// Talks to the in-app `ParolaAutomationServer` over TCP loopback. One request per call:
/// reads the port + auth token from `~/Library/Caches/Parola/`, opens a socket,
/// sends a line, reads a line, closes.
public struct BridgeClient: BridgeProtocol {
    public struct BridgeNotRunning: LocalizedError {
        public var errorDescription: String? {
            "Parola.app's test bridge is not reachable. Launch a Debug build of Parola.app and try again."
        }
    }

    public struct BridgeFailure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let portFileURL: URL
    private let tokenFileURL: URL
    private let timeout: TimeInterval

    /// Bumped when the wire format breaks. The bridge echoes its own version so the client can detect skew.
    public static let clientVersion: Int = 1

    public init(timeout: TimeInterval = 30) {
        self.portFileURL = AppLauncher.portFileURL()
        self.tokenFileURL = AppLauncher.tokenFileURL()
        self.timeout = timeout
    }

    public func call(_ cmd: String, argsJSON: Data) async throws -> String {
        let port = try readPort()
        let token = readToken() ?? ""
        let payload = encodeRequest(cmd: cmd, argsJSON: argsJSON, token: token)
        let timeout = self.timeout

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try BridgeClient.exchange(
                        host: "127.0.0.1",
                        port: port,
                        request: payload,
                        timeout: timeout
                    )
                    let text = try BridgeClient.parse(response: response)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readPort() throws -> Int {
        guard let raw = try? String(contentsOf: portFileURL, encoding: .utf8),
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BridgeNotRunning()
        }
        return port
    }

    private func readToken() -> String? {
        guard let raw = try? String(contentsOf: tokenFileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func encodeRequest(cmd: String, argsJSON: Data, token: String) -> Data {
        let argsBytes = argsJSON.isEmpty ? Data("{}".utf8) : argsJSON
        let id = UUID().uuidString
        var out = Data()
        out.append(Data("{\"id\":\"\(id)\",\"version\":\(BridgeClient.clientVersion),\"cmd\":\"\(cmd)\",\"auth\":\"\(token)\",\"args\":".utf8))
        out.append(argsBytes)
        out.append(Data("}\n".utf8))
        return out
    }

    private static func exchange(host: String, port: Int, request: Data, timeout: TimeInterval) throws -> Data {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw BridgeFailure(message: "socket() failed") }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw BridgeNotRunning() }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        try request.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                throw BridgeFailure(message: "send() failed (empty request buffer)")
            }
            var sent = 0
            while sent < request.count {
                let n = send(socketFD, base + sent, request.count - sent, 0)
                if n <= 0 { throw BridgeFailure(message: "send() failed (n=\(n))") }
                sent += n
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return recv(socketFD, base, ptr.count, 0)
            }
            if n <= 0 { break }
            let received = chunk.prefix(n)
            buffer.append(contentsOf: received)
            if received.contains(0x0A) { break }
        }
        return buffer
    }

    private static func parse(response: Data) throws -> String {
        guard !response.isEmpty else {
            throw BridgeFailure(message: "bridge closed connection before responding")
        }
        let nl = response.firstIndex(of: 0x0A) ?? response.endIndex
        let lineData = response.subdata(in: response.startIndex..<nl)

        let object = try JSONSerialization.jsonObject(with: lineData)
        guard let dict = object as? [String: Any] else {
            throw BridgeFailure(message: "malformed response: \(String(decoding: lineData, as: UTF8.self))")
        }
        if let serverVersion = dict["serverVersion"] as? Int,
           serverVersion < BridgeClient.clientVersion {
            throw BridgeFailure(
                message: "incompatible bridge: app advertises v\(serverVersion), parola-mcp expects v\(BridgeClient.clientVersion). Rebuild Parola.app."
            )
        }
        if let ok = dict["ok"] as? Bool, ok {
            return BridgeJSON.string(dict["result"] ?? NSNull())
        }
        let message = (dict["error"] as? String) ?? "unknown bridge error"
        throw BridgeFailure(message: message)
    }
}

public enum BridgeJSON {
    public static func string(_ value: Any) -> String {
        do {
            let normalised = normalise(value)
            let data = try JSONSerialization.data(
                withJSONObject: normalised,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "<encoding error: \(error.localizedDescription)>"
        }
    }

    private static func normalise(_ value: Any) -> Any {
        switch value {
        case is [Any], is [String: Any]:
            return value
        case is NSNull:
            return ["value": NSNull()]
        default:
            return ["value": value]
        }
    }
}
