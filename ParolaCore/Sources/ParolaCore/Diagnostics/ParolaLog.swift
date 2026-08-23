import Foundation
import os

public enum LogSubsystem: String, Sendable {
    case core = "app.parola.core"
    case app = "app.parola.app"
    case cli = "app.parola.cli"
}

public enum ParolaLog {
    private struct State {
        var sink: (any DiagnosticsSink)?
        var subsystem: String = LogSubsystem.core.rawValue
        var loggers: [LogCategory: Logger] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    public static func configure(subsystem: LogSubsystem) {
        state.withLock {
            $0.subsystem = subsystem.rawValue
            $0.loggers = [:]
        }
    }

    public static func install(_ sink: any DiagnosticsSink) {
        state.withLock { $0.sink = sink }
    }

    public static func uninstall() {
        state.withLock { $0.sink = nil }
    }

    static var installedSink: (any DiagnosticsSink)? {
        state.withLock { $0.sink }
    }

    public static func debug(
        _ category: LogCategory, _ message: LogMessage,
        _ fields: [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.debug, category, message, fields, file, line) }

    public static func info(
        _ category: LogCategory, _ message: LogMessage,
        _ fields: [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.info, category, message, fields, file, line) }

    public static func notice(
        _ category: LogCategory, _ message: LogMessage,
        _ fields: [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.notice, category, message, fields, file, line) }

    public static func error(
        _ category: LogCategory, _ message: LogMessage,
        _ fields: [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.error, category, message, fields, file, line) }

    public static func fault(
        _ category: LogCategory, _ message: LogMessage,
        _ fields: [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.fault, category, message, fields, file, line) }

    private static func emit(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: LogMessage,
        _ fields: [LogField: LogValue],
        _ file: StaticString,
        _ line: UInt
    ) {
        let (logger, subsystem) = resolve(category)
        let record = LogRecord(
            timestamp: Date(),
            level: level,
            subsystem: subsystem,
            category: category,
            message: message,
            fields: fields,
            file: file.description,
            line: line
        )
        logger.log(level: level.osLogType, "\(record.message.rendered, privacy: .public) \(record.formattedFields, privacy: .public)")
        installedSink?.enqueue(record)
    }

    private static func resolve(_ category: LogCategory) -> (Logger, String) {
        state.withLock { current in
            if let existing = current.loggers[category] {
                return (existing, current.subsystem)
            }
            let logger = Logger(subsystem: current.subsystem, category: category.rawValue)
            current.loggers[category] = logger
            return (logger, current.subsystem)
        }
    }
}

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .error: return .error
        case .fault: return .fault
        }
    }
}
