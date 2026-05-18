import Foundation

public enum HTTPMethod: String, Sendable, Hashable {
    case GET, POST, PUT, DELETE, PATCH
}

public struct HTTPRequest: Sendable {
    public let method: HTTPMethod
    public let path: String
    public var params: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(
        method: HTTPMethod,
        path: String,
        params: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.params = params
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: Int, body: String) {
        self.init(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"],
                  body: body.data(using: .utf8) ?? Data())
    }

    public var bodyString: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    public static func json(status: Int, _ payload: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }
}

public typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

public actor HTTPRouter {
    private var routes: [Route] = []

    public init() {}

    private struct Route {
        let method: HTTPMethod
        let segments: [Segment]
        let handler: HTTPHandler
        var specificity: Int {
            segments.reduce(0) { acc, segment in
                switch segment {
                case .literal: return acc + 2
                case .param: return acc + 1
                }
            }
        }
    }

    private enum Segment: Equatable {
        case literal(String)
        case param(String)
    }

    public func route(_ method: HTTPMethod, _ path: String, handler: @escaping HTTPHandler) {
        let segments = Self.parseSegments(path)
        routes.append(Route(method: method, segments: segments, handler: handler))
    }

    public func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        let requestSegments = Self.parseRequestPath(request.path)
        var pathMatchedAnyMethod = false
        var bestMatch: (route: Route, params: [String: String])?

        for route in routes {
            guard let params = match(route.segments, against: requestSegments) else { continue }
            pathMatchedAnyMethod = true
            guard route.method == request.method else { continue }
            if let current = bestMatch {
                if route.specificity > current.route.specificity {
                    bestMatch = (route, params)
                }
            } else {
                bestMatch = (route, params)
            }
        }

        if let bestMatch {
            var enriched = request
            enriched.params.merge(bestMatch.params) { _, new in new }
            return await bestMatch.route.handler(enriched)
        }

        if pathMatchedAnyMethod { return HTTPResponse(status: 405, body: "Method Not Allowed") }
        return HTTPResponse(status: 404, body: "Not Found")
    }

    private func match(_ pattern: [Segment], against path: [String]) -> [String: String]? {
        guard pattern.count == path.count else { return nil }
        var params: [String: String] = [:]
        for (idx, segment) in pattern.enumerated() {
            switch segment {
            case .literal(let value):
                guard value == path[idx] else { return nil }
            case .param(let name):
                params[name] = path[idx]
            }
        }
        return params
    }

    private static func parseSegments(_ path: String) -> [Segment] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { piece in
            if piece.hasPrefix(":") {
                return .param(String(piece.dropFirst()))
            }
            return .literal(String(piece))
        }
    }

    private static func parseRequestPath(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
