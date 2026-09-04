import Foundation

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info
    case notice
    case error
    case fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var name: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        }
    }

    /// Reads back a persisted level. Derived from `name`, whose switch has no `default`, so a new
    /// level cannot be decoded until its spelling is decided.
    public init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }
}

public enum LogSubsystem: String, Sendable {
    case core = "app.parola.core"
    case app = "app.parola.app"
    case cli = "app.parola.cli"
}

public enum LogCategory: String, Sendable, CaseIterable {
    case engineWhisperKit = "engine.whisperkit"
    case engineParakeet = "engine.parakeet"
    case engineAppleSpeech = "engine.apple-speech"
    case models
    case library
    case librarySpotlight = "library.spotlight"
    case libraryIndex = "library.index"
    case audioCapture = "audio.capture"
    case audioRecording = "audio.recording"
    case streaming
    case batch
    case export
    case dictation
    case youtube
    case ai
    case appLifecycle = "app.lifecycle"
    case appPermissions = "app.permissions"
    case appBridge = "app.bridge"
    case appRecovery = "app.recovery"
    case cli
    case diagnostics
}

extension LogCategory {
    /// A framework logs under its own subsystem whatever process hosts it, so Core's categories
    /// stay on `app.parola.core` and keep matching the engines' hardcoded signposters.
    public var subsystem: LogSubsystem {
        switch self {
        case .appLifecycle, .appPermissions, .appBridge, .appRecovery: .app
        case .cli: .cli
        default: .core
        }
    }
}

public struct LogRecord: Sendable, Equatable {
    public let timestamp: Date
    public let level: LogLevel
    public let subsystem: LogSubsystem
    public let category: LogCategory
    public let message: LogMessage
    public let fields: [LogField: LogValue]
    public let file: String
    public let line: UInt

    init(
        timestamp: Date,
        level: LogLevel,
        subsystem: LogSubsystem,
        category: LogCategory,
        message: LogMessage,
        fields: [LogField: LogValue],
        file: String,
        line: UInt
    ) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.fields = fields
        self.file = file
        self.line = line
    }

    public var formattedFields: String {
        fields.keys.sorted()
            .map { "\($0.rawValue)=\(fields[$0]!.text)" }
            .joined(separator: " ")
    }

    public var formattedLine: String {
        let stamp = LogTimestamp.string(from: timestamp)
        var line = "\(stamp)  \(level.name)  \(category.rawValue)  \(message.rendered)"
        let rendered = formattedFields
        if !rendered.isEmpty { line += "  \(rendered)" }
        return line
    }
}

enum LogTimestamp {
    static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func string(from date: Date) -> String { style.format(date) }
}
