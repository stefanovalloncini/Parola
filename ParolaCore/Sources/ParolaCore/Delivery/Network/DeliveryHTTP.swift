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

    /// One session per trust level for the whole process, so connections are reused and none is left behind.
    public static func shared(trust: TransportTrust) -> URLSessionTransport {
        switch trust {
        case .system: return systemShared
        case .loopbackSelfSigned: return loopbackShared
        }
    }

    private static let systemShared = URLSessionTransport(trust: .system)
    private static let loopbackShared = URLSessionTransport(trust: .loopbackSelfSigned)

    private let session: URLSession

    public init(trust: TransportTrust = .system) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout * 4
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: DeliverySessionDelegate(trust: trust), delegateQueue: nil)
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
    public enum Decision: Sendable, Equatable {
        case acceptCertificate
        case defaultHandling
    }

    public static func isLoopback(host: String) -> Bool {
        let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    /// Whether to accept a server's certificate: when the system trusts it, or when the server is this Mac.
    public static func accepts(host: String, systemTrustPassed: Bool) -> Bool {
        systemTrustPassed || isLoopback(host: host)
    }

    /// What a session set to `.loopbackSelfSigned` does with an authentication challenge. A certificate
    /// without a trusted chain is accepted only for a server trust challenge from a loopback host.
    public static func decision(
        trust: TransportTrust, authenticationMethod: String, host: String, systemTrustPassed: @autoclosure () -> Bool
    ) -> Decision {
        guard trust == .loopbackSelfSigned, authenticationMethod == NSURLAuthenticationMethodServerTrust, isLoopback(host: host) else {
            return .defaultHandling
        }
        return accepts(host: host, systemTrustPassed: systemTrustPassed()) ? .acceptCertificate : .defaultHandling
    }
}

/// A redirect is followed only within the same scheme, host and port: a header secret and a transcript
/// must not follow a hook to another address.
public enum RedirectPolicy {
    public static func allows(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target else { return false }
        return original.scheme?.lowercased() == target.scheme?.lowercased()
            && original.host?.lowercased() == target.host?.lowercased()
            && effectivePort(original) == effectivePort(target)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}

final class DeliverySessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let trust: TransportTrust

    init(trust: TransportTrust) {
        self.trust = trust
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard let serverTrust = space.serverTrust else { return (.performDefaultHandling, nil) }
        let decision = LoopbackTrust.decision(
            trust: trust,
            authenticationMethod: space.authenticationMethod,
            host: space.host,
            systemTrustPassed: SecTrustEvaluateWithError(serverTrust, nil)
        )
        return decision == .acceptCertificate ? (.useCredential, URLCredential(trust: serverTrust)) : (.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectPolicy.allows(from: task.originalRequest?.url, to: request.url) ? request : nil
    }
}

/// The section names of a Notion page, in the app's language.
public struct NotionHeadings: Sendable, Equatable {
    public var summary: String
    public var actionItems: String
    public var chapters: String
    public var transcript: String

    public init(
        summary: String = "Summary", actionItems: String = "Action Items",
        chapters: String = "Chapters", transcript: String = "Transcript"
    ) {
        self.summary = summary
        self.actionItems = actionItems
        self.chapters = chapters
        self.transcript = transcript
    }
}

/// What a destination needs from the app to run: where its secrets live, how it reaches the
/// network, and the clock its waits go through. Never stored; the app wires it in after decoding.
public struct DeliveryEnvironment: Sendable, Equatable {
    public var secrets: any SecretStore
    public var transport: @Sendable (TransportTrust) -> any DeliveryHTTPTransport
    public var clock: any Clock<Duration>
    public var notionHeadings: NotionHeadings

    public init(
        secrets: any SecretStore,
        transport: @escaping @Sendable (TransportTrust) -> any DeliveryHTTPTransport,
        clock: any Clock<Duration> = ContinuousClock(),
        notionHeadings: NotionHeadings = NotionHeadings()
    ) {
        self.secrets = secrets
        self.transport = transport
        self.clock = clock
        self.notionHeadings = notionHeadings
    }

    public static let live = DeliveryEnvironment(
        secrets: KeychainSecretStore.shared,
        transport: { URLSessionTransport.shared(trust: $0) }
    )

    /// Never part of a destination's identity: two destinations with the same settings are equal whatever they are wired to.
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
            let failure = NetworkFailure(error)
            if failure == .cancelled { throw CancellationError() }
            throw DeliveryError.networkFailed(request.url?.host ?? destination, failure)
        }
    }
}

/// Which hosts may be spoken to without encryption: this Mac and the local network.
public enum NetworkHostPolicy {
    public static func isLocalOrPrivate(host rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty { return false }
        if LoopbackTrust.isLoopback(host: host) { return true }
        if let address = ipv4(host) {
            let first = UInt8(address >> 24)
            let second = UInt8((address >> 16) & 0xFF)
            switch (first, second) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if let bytes = ipv6(host) {
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = bytes[0] & 0xFE == 0xFC
            let isLinkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
            return isLoopback || isUniqueLocal || isLinkLocal
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        return !host.contains(".") && host.contains(where: \.isLetter)
    }

    /// The address the system resolver reads a host as, in every form it accepts: `8.8.8.8`, `134744072`, `0x8.8.8.8`.
    private static func ipv4(_ host: String) -> UInt32? {
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}

/// What a "Check connection" found.
public enum ConnectionStatus: Sendable, Equatable {
    case connected(String?)
    case unauthorised
    case pageNotShared
}
