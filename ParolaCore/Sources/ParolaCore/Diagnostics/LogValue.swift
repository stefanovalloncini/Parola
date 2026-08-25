import Foundation

public struct LogValue: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case int, seconds, bytes, flag, token
    }

    /// Not persisted: the exported log stays flat, and `LogField` is closed, so a renderer can
    /// map field to kind statically instead of paying for it on every line.
    let kind: Kind
    public let text: String

    private init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func int(_ value: Int) -> LogValue {
        LogValue(kind: .int, text: String(value))
    }

    public static func bytes(_ value: Int64) -> LogValue {
        LogValue(kind: .bytes, text: String(value))
    }

    public static func flag(_ value: Bool) -> LogValue {
        LogValue(kind: .flag, text: value ? "true" : "false")
    }

    public static func seconds(_ value: Double) -> LogValue {
        LogValue(kind: .seconds, text: LogDecimal.twoPlaces(value))
    }

    public static func duration(_ value: Duration) -> LogValue {
        let seconds = Double(value.components.seconds)
            + Double(value.components.attoseconds) / 1e18
        return .seconds(seconds)
    }

    public static func safe(_ value: some LogSafe) -> LogValue {
        LogValue(kind: .token, text: value.logToken)
    }

    public static func id(_ value: UUID) -> LogValue {
        LogValue(kind: .token, text: String(value.uuidString.prefix(8)))
    }

    public static func error(_ error: any Error) -> LogValue {
        LogValue(kind: .token, text: LogErrorKind.describe(error))
    }
}

enum LogDecimal {
    /// Hand-rolled because `String(format: "%.2f", …)` costs ~600 ns, which every duration field pays.
    static func twoPlaces(_ value: Double) -> String {
        let scaled = (value * 100).rounded()
        guard scaled.magnitude < 9e18 else { return String(format: "%.2f", value) }
        let magnitude = Int64(scaled.magnitude)
        let sign = scaled < 0 ? "-" : ""
        let fraction = magnitude % 100
        return fraction < 10
            ? "\(sign)\(magnitude / 100).0\(fraction)"
            : "\(sign)\(magnitude / 100).\(fraction)"
    }
}

public enum LogField: String, Sendable, CaseIterable, Comparable {
    case attempt
    case audioSeconds
    case bytes
    case count
    case elapsed
    case engine
    case entry
    case error
    case model
    case stage

    public static func < (lhs: LogField, rhs: LogField) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
