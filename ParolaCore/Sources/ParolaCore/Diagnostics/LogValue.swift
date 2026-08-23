import Foundation

public struct LogValue: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case int, seconds, bytes, flag, token
    }

    public let kind: Kind
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
        LogValue(kind: .seconds, text: String(format: "%.2f", value))
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
