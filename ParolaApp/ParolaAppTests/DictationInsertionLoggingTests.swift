import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Dictation insertion logging", .serialized)
struct DictationInsertionLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func permissionRecord(
        _ sink: CapturingDiagnosticsSink, message: String
    ) -> LogRecord? {
        sink.records.first { $0.category == .appPermissions && $0.message.rendered == message }
    }

    @Test("a paste blocked by accessibility is a notice, and the text stays out of it")
    func blockedPasteIsNoticed() async throws {
        try await withSink { sink in
            try await withPasteboardRestored {
                let inserter = ClipboardPasteInserter(trustCheck: { false })
                await #expect(throws: TextInsertionError.self) {
                    try await inserter.insert("dictated text")
                }
                let record = try #require(
                    permissionRecord(sink, message: "text insertion blocked: accessibility not granted")
                )
                #expect(record.level == .notice)
                #expect(record.fields.isEmpty)
                #expect(record.formattedLine.contains("dictated text") == false)
            }
        }
    }

    @Test("blocked keystrokes are noticed on their own path")
    func blockedKeystrokesAreNoticed() async throws {
        try await withSink { sink in
            try await withPasteboardRestored {
                let inserter = KeystrokeTextInserter(trustCheck: { false })
                await #expect(throws: TextInsertionError.self) {
                    try await inserter.insert("typed text")
                }
                let record = try #require(
                    permissionRecord(sink, message: "keystroke insertion blocked: accessibility not granted")
                )
                #expect(record.level == .notice)
                #expect(record.fields.isEmpty)
                #expect(record.formattedLine.contains("typed text") == false)
            }
        }
    }

    @Test("a granted insertion logs nothing")
    func grantedInsertionIsSilent() async throws {
        try await withSink { sink in
            try await withPasteboardRestored {
                let inserter = KeystrokeTextInserter(trustCheck: { true })
                try await inserter.insert("")
                #expect(sink.records.filter { $0.category == .appPermissions }.isEmpty)
            }
        }
    }
}
