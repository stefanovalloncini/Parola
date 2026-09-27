import Darwin
import Foundation

/// Talks to the in-app `ParolaAutomationServer` over TCP loopback. One request per call:
/// reads the port + auth token from `~/Library/Caches/Parola/`, opens a socket,
/// sends a line, reads a line, closes.
public struct BridgeClient: BridgeProtocol {
    public struct BridgeNotRunning: LocalizedError {
        public let detail: String?
        public init(detail: String? = nil) { self.detail = detail }
        public var errorDescription: String? {
            let base = "Parola.app's test bridge is not reachable."
            let hint = detail ?? "Launch a Debug build of Parola.app and try again."
            return "\(base) \(hint)"
        }
    }

    public struct BridgeFailure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let portFileURL: URL
    private let tokenFileURL: URL
    private let discoveryFileURL: URL
    private let timeout: TimeInterval

    /// Bumped when the wire format breaks. The bridge echoes its own version so the client can detect skew.
    public static let clientVersion: Int = 2

    public init(timeout: TimeInterval = 35) {
        self.init(
            portFileURL: AppLauncher.portFileURL(),
            tokenFileURL: AppLauncher.tokenFileURL(),
            discoveryFileURL: AppLauncher.discoveryFileURL(),
            timeout: timeout
        )
    }

    init(portFileURL: URL, tokenFileURL: URL, discoveryFileURL: URL, timeout: TimeInterval) {
        self.portFileURL = portFileURL
        self.tokenFileURL = tokenFileURL
        self.discoveryFileURL = discoveryFileURL
        self.timeout = timeout
    }

    public func call(_ cmd: String, argsJSON: Data) async throws -> String {
        do {
            return try await performCall(cmd, argsJSON: argsJSON)
        } catch is BridgeNotRunning {
            throw BridgeNotRunning(detail: Self.staleDiscoveryHint(discoveryFileURL: discoveryFileURL))
        }
    }

    private func performCall(_ cmd: String, argsJSON: Data) async throws -> String {
        let port = try readPort()
        let token = readToken() ?? ""
        let payload = encodeRequest(cmd: cmd, argsJSON: argsJSON, token: token)
        let timeout = Self.socketTimeout(cmd: cmd, argsJSON: argsJSON, floor: self.timeout)

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

    static func staleDiscoveryHint(discoveryFileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: discoveryFileURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = record["pid"] as? Int, pid > 0 else { return nil }
        if processAlive(pid: pid) {
            return "Parola.app (pid \(pid)) wrote the bridge files but isn't accepting on the recorded port — "
                + "another instance may have overwritten them. Relaunch the app or toggle the bridge in Settings → Automation."
        }
        return "The bridge files in Caches/Parola were left by a dead instance (pid \(pid)). "
            + "Relaunch Parola.app or toggle the bridge in Settings → Automation to rewrite them."
    }

    private static func processAlive(pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// The longest a `wait…` command runs on its own default, which a call that names no `timeoutMs` gets.
    static let longestWaitDefault: TimeInterval = 600

    /// A long-poll command (waitForPhase, waitForBatchJob, ...) legally runs past `floor`, so the
    /// socket waits out the command's own `timeoutMs` plus slack.
    static func socketTimeout(cmd: String, argsJSON: Data, floor: TimeInterval) -> TimeInterval {
        if let requested = requestedTimeout(argsJSON: argsJSON) {
            return max(floor, requested + 5)
        }
        return cmd.hasPrefix("wait") ? max(floor, longestWaitDefault + 5) : floor
    }

    private static func requestedTimeout(argsJSON: Data) -> TimeInterval? {
        guard !argsJSON.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: argsJSON) as? [String: Any],
              let ms = object["timeoutMs"] as? Int, ms > 0 else { return nil }
        return TimeInterval(ms) / 1000
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

    func encodeRequest(cmd: String, argsJSON: Data, token: String) -> Data {
        let argsObject = (try? JSONSerialization.jsonObject(with: argsJSON.isEmpty ? Data("{}".utf8) : argsJSON)) ?? [String: Any]()
        let envelope: [String: Any] = [
            "id": UUID().uuidString,
            "version": BridgeClient.clientVersion,
            "cmd": cmd,
            "auth": token,
            "args": argsObject,
        ]
        guard var out = try? JSONSerialization.data(withJSONObject: envelope) else { return Data() }
        out.append(0x0A)
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
        // Without this, a peer reset between connect and send raises SIGPIPE and kills the process.
        var noSigpipe: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

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
            if n > 0 {
                let received = chunk.prefix(n)
                buffer.append(contentsOf: received)
                if received.contains(0x0A) { break }
                continue
            }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                // A recv timeout is not a peer close; say so, or a long-running command
                // in the app reads as a crashed bridge.
                throw BridgeFailure(message: "bridge did not respond within \(Int(timeout))s (the command may still be running in the app)")
            }
            break
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
        let message = Self.errorMessage(from: dict)
        throw BridgeFailure(message: message)
    }

    private static func errorMessage(from dict: [String: Any]) -> String {
        if let err = dict["error"] as? [String: Any] {
            let code = err["code"] as? String ?? "INTERNAL"
            let msg = err["message"] as? String ?? "unknown bridge error"
            return "[\(code)] \(msg)"
        }
        if let msg = dict["error"] as? String { return msg }
        return "unknown bridge error"
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
