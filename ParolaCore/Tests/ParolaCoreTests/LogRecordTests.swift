import Foundation
import Testing
@testable import ParolaCore

@Suite("Log record")
struct LogRecordTests {
    private func record(level: LogLevel = .error) -> LogRecord {
        LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_871_082.114),
            level: level,
            subsystem: .core,
            category: .engineWhisperKit,
            message: "model \(ModelToken("openai_whisper-large-v3_turbo")) failed",
            fields: [.elapsed: .seconds(61.2), .error: .error(ParolaError.ioError("x"))],
            file: "ParolaCore/WhisperKitTranscriber.swift",
            line: 130
        )
    }

    @Test("levels order from debug up to fault")
    func levelsOrder() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.notice < LogLevel.error)
        #expect(LogLevel.error < LogLevel.fault)
    }

    @Test("every level round-trips through its name")
    func levelsRoundTripByName() {
        for level in LogLevel.allCases {
            #expect(LogLevel(name: level.name) == level)
        }
    }

    @Test("an unknown level name reads back as nil")
    func unknownLevelNameIsNil() {
        #expect(LogLevel(name: "warning") == nil)
        #expect(LogLevel(name: "") == nil)
        #expect(LogLevel(name: "Error") == nil)
    }

    @Test("a formatted line carries timestamp, level, category and fields")
    func formattedLine() {
        let line = record().formattedLine
        #expect(line.hasPrefix("2025-08-22T13:58:02.114Z"))
        #expect(line.contains("error"))
        #expect(line.contains("engine.whisperkit"))
        #expect(line.contains("model openai_whisper-large-v3_turbo failed"))
        #expect(line.contains("elapsed=61.20"))
        #expect(line.contains("error=ParolaError.ioError"))
    }

    @Test("fields render in a deterministic order")
    func fieldsAreOrdered() {
        let line = record().formattedLine
        let elapsedAt = line.range(of: "elapsed=")!.lowerBound
        let errorAt = line.range(of: "error=")!.lowerBound
        #expect(elapsedAt < errorAt)
    }

    @Test("categories are stable strings")
    func categoryStrings() {
        #expect(LogCategory.engineWhisperKit.rawValue == "engine.whisperkit")
        #expect(LogCategory.librarySpotlight.rawValue == "library.spotlight")
    }
}
