import Foundation

public struct LogMessage: ExpressibleByStringInterpolation, Sendable, Equatable {
    /// Pinning this to `StaticString` is what keeps `LogMessage(stringLiteral:)` from accepting a runtime `String`, and it closes the inherited grapheme-cluster and unicode-scalar literal initializers by inference too.
    public typealias StringLiteralType = StaticString

    public enum Segment: Sendable, Equatable {
        case literal(String)
        case value(String)
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        public typealias StringLiteralType = StaticString

        var segments: [Segment] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: StaticString) {
            segments.append(.literal(literal.description))
        }

        public mutating func appendInterpolation(_ value: some LogSafe) {
            segments.append(.value(value.logToken))
        }

        public mutating func appendInterpolation(_ value: (some LogSafe)?) {
            segments.append(.value(value.map(\.logToken) ?? "nil"))
        }
    }

    public let segments: [Segment]

    public init(stringLiteral value: StaticString) {
        self.segments = [.literal(value.description)]
    }

    public init(stringInterpolation: StringInterpolation) {
        self.segments = stringInterpolation.segments
    }

    /// Literal segments with interpolations replaced by `%@`. Low cardinality by
    /// construction, so exported logs stay greppable by message shape.
    public var template: String {
        segments.map { segment in
            switch segment {
            case .literal(let text): return text
            case .value: return "%@"
            }
        }.joined()
    }

    public var rendered: String {
        segments.map { segment in
            switch segment {
            case .literal(let text), .value(let text): return text
            }
        }.joined()
    }
}
