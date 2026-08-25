import Foundation
import os

public enum ParolaLog {
    private struct State {
        var sink: (any DiagnosticsSink)?
        var loggers: [LogCategory: Logger] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

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
        _ category: LogCategory, _ message: @autoclosure () -> LogMessage,
        _ fields: @autoclosure () -> [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.debug, category, message, fields, file, line) }

    public static func info(
        _ category: LogCategory, _ message: @autoclosure () -> LogMessage,
        _ fields: @autoclosure () -> [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.info, category, message, fields, file, line) }

    public static func notice(
        _ category: LogCategory, _ message: @autoclosure () -> LogMessage,
        _ fields: @autoclosure () -> [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.notice, category, message, fields, file, line) }

    public static func error(
        _ category: LogCategory, _ message: @autoclosure () -> LogMessage,
        _ fields: @autoclosure () -> [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.error, category, message, fields, file, line) }

    public static func fault(
        _ category: LogCategory, _ message: @autoclosure () -> LogMessage,
        _ fields: @autoclosure () -> [LogField: LogValue] = [:],
        file: StaticString = #fileID, line: UInt = #line
    ) { emit(.fault, category, message, fields, file, line) }

    private static func emit(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: () -> LogMessage,
        _ fields: () -> [LogField: LogValue],
        _ file: StaticString,
        _ line: UInt
    ) {
        let (sink, logger) = destination(for: category)
        let osLogEnabled = logger.isEnabled(type: level.osLogType)
        guard sink != nil || osLogEnabled else { return }

        let record = LogRecord(
            timestamp: Date(),
            level: level,
            subsystem: category.subsystem,
            category: category,
            message: message(),
            fields: fields(),
            file: file.description,
            line: line
        )
        if osLogEnabled {
            let fieldText = record.formattedFields
            let text = fieldText.isEmpty
                ? record.message.rendered
                : "\(record.message.rendered) \(fieldText)"
            logger.log(level: level.osLogType, "\(text, privacy: .public)")
        }
        sink?.enqueue(record)
    }

    private static func destination(
        for category: LogCategory
    ) -> ((any DiagnosticsSink)?, Logger) {
        state.withLock { current in
            if let existing = current.loggers[category] { return (current.sink, existing) }
            let logger = Logger(
                subsystem: category.subsystem.rawValue,
                category: category.rawValue
            )
            current.loggers[category] = logger
            return (current.sink, logger)
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
