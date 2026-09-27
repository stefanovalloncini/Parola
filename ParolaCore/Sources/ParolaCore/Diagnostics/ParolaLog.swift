import Foundation
import os

public enum ParolaLog {
    private struct State {
        var sink: (any DiagnosticsSink)?
        var loggers: [LogCategory: Logger] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    @TaskLocal private static var scopedSink: (any DiagnosticsSink)?

    /// Sends the records this task tree emits to `sink` instead of the installed one, for as long as
    /// `operation` runs. Structured children and `Task { }` inherit the routing; a `Task.detached`,
    /// a Dispatch hop or a C callback does not, and keeps logging to the installed sink, so a caller
    /// must not expect its capture to hold those records. A `Task { }` started inside the scope keeps
    /// `sink` for its whole life, including whatever it logs after `withSink` has returned.
    public nonisolated(nonsending) static func withSink<T>(
        _ sink: any DiagnosticsSink,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $scopedSink.withValue(sink, operation: operation)
    }

    /// The synchronous half of `withSink(_:operation:)`, under the same routing rule.
    public static func withSink<T>(
        _ sink: any DiagnosticsSink, operation: () throws -> T
    ) rethrows -> T {
        try $scopedSink.withValue(sink, operation: operation)
    }

    public static func install(_ sink: any DiagnosticsSink) {
        state.withLock { $0.sink = sink }
    }

    public static func uninstall() {
        state.withLock { $0.sink = nil }
    }

    public static func flush() async {
        await currentSink()?.flush()
    }

    public static func flushSynchronously() {
        currentSink()?.flushSynchronously()
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

    private static func currentSink() -> (any DiagnosticsSink)? {
        scopedSink ?? state.withLock { $0.sink }
    }

    private static func destination(
        for category: LogCategory
    ) -> ((any DiagnosticsSink)?, Logger) {
        let scoped = scopedSink
        return state.withLock { current in
            let sink = scoped ?? current.sink
            if let existing = current.loggers[category] { return (sink, existing) }
            let logger = Logger(
                subsystem: category.subsystem.rawValue,
                category: category.rawValue
            )
            current.loggers[category] = logger
            return (sink, logger)
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
