import Foundation

public struct HTTPResult: Sendable, Equatable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

public protocol DeliveryHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

/// Whose certificates a session believes.
public enum TransportTrust: Sendable, Equatable {
    case system
    /// The system's rules, plus an untrusted certificate when the server is on this Mac. For the
    /// self-signed certificate the Obsidian Local REST plugin makes.
    case loopbackSelfSigned
}

public struct URLSessionTransport: DeliveryHTTPTransport {
    public static let timeout: TimeInterval = 30

    private let session: URLSession

    public init(trust: TransportTrust = .system) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout * 4
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        switch trust {
        case .system:
            session = URLSession(configuration: configuration)
        case .loopbackSelfSigned:
            session = URLSession(configuration: configuration, delegate: LoopbackTrustDelegate(), delegateQueue: nil)
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return HTTPResult(status: http.statusCode, headers: headers, body: data)
    }
}

public enum LoopbackTrust {
    public static func isLoopback(host: String) -> Bool {
        let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    /// Whether to accept a server's certificate: when the system trusts it, or when the server is this Mac.
    public static func accepts(host: String, systemTrustPassed: Bool) -> Bool {
        systemTrustPassed || isLoopback(host: host)
    }
}

final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              LoopbackTrust.isLoopback(host: space.host) else {
            return (.performDefaultHandling, nil)
        }
        let systemTrustPassed = SecTrustEvaluateWithError(trust, nil)
        guard LoopbackTrust.accepts(host: space.host, systemTrustPassed: systemTrustPassed) else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// What a destination needs from the app to run: where its secrets live, how it reaches the
/// network, and the clock its waits go through. Never stored; the app wires it in after decoding.
public struct DeliveryEnvironment: Sendable, Equatable {
    public var secrets: any SecretStore
    public var transport: @Sendable (TransportTrust) -> any DeliveryHTTPTransport
    public var clock: any Clock<Duration>

    public init(
        secrets: any SecretStore,
        transport: @escaping @Sendable (TransportTrust) -> any DeliveryHTTPTransport,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.secrets = secrets
        self.transport = transport
        self.clock = clock
    }

    public static let live = DeliveryEnvironment(
        secrets: KeychainSecretStore.shared,
        transport: { URLSessionTransport(trust: $0) }
    )

    public static func == (lhs: DeliveryEnvironment, rhs: DeliveryEnvironment) -> Bool { true }

    public func withSecretOverrides(_ overrides: [String: String]) -> DeliveryEnvironment {
        var copy = self
        copy.secrets = OverlaySecretStore(base: secrets, overrides: overrides)
        return copy
    }

    func secret(_ reference: String, destination: String) async throws -> String {
        guard let value = try await secrets.get(reference), !value.isEmpty else {
            throw DeliveryError.missingSecret(destination)
        }
        return value
    }

    func perform(_ request: URLRequest, trust: TransportTrust = .system, destination: String) async throws -> HTTPResult {
        do {
            return try await transport(trust).send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeliveryError.networkFailed(request.url?.host ?? destination, Self.reason(for: error))
        }
    }

    /// The error's own words, which for a URL error name the problem and the host and never a header.
    private static func reason(for error: any Error) -> String {
        (error as? URLError).map { $0.localizedDescription } ?? error.localizedDescription
    }
}

/// Which hosts may be spoken to without encryption: this Mac and the local network.
public enum NetworkHostPolicy {
    public static func isLocalOrPrivate(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty { return false }
        if LoopbackTrust.isLoopback(host: host) { return true }
        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if host.contains(":") {
            return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        return !host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard part.allSatisfy(\.isASCII), let value = Int(part), (0...255).contains(value) else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }
}

/// What a "Check connection" found.
public enum ConnectionStatus: Sendable, Equatable {
    case connected(String?)
    case unauthorised
    case pageNotShared
}
