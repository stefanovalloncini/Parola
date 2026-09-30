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

    // The general pasteboard is shared with every other test and process on the Mac.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("insertion-logging-test-\(UUID().uuidString)"))
    }

    @Test("a paste blocked by accessibility is a notice, and the text stays out of it")
    func blockedPasteIsNoticed() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let pasteboardName = pasteboard.name
        try await withSink { sink in
            let inserter = ClipboardPasteInserter(trustCheck: { false }, pasteboardName: pasteboardName)
            var thrown: Error?
            do {
                try await inserter.insert("dictated text")
            } catch {
                thrown = error
            }
            #expect(thrown is TextInsertionError)
            let record = try #require(
                permissionRecord(sink, message: "text insertion blocked: accessibility not granted")
            )
            #expect(record.level == .notice)
            #expect(record.fields.isEmpty)
            #expect(record.formattedLine.contains("dictated text") == false)
        }
    }

    @Test("blocked keystrokes are noticed on their own path")
    func blockedKeystrokesAreNoticed() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let pasteboardName = pasteboard.name
        try await withSink { sink in
            let inserter = KeystrokeTextInserter(trustCheck: { false }, pasteboardName: pasteboardName)
            var thrown: Error?
            do {
                try await inserter.insert("typed text")
            } catch {
                thrown = error
            }
            #expect(thrown is TextInsertionError)
            let record = try #require(
                permissionRecord(sink, message: "keystroke insertion blocked: accessibility not granted")
            )
            #expect(record.level == .notice)
            #expect(record.fields.isEmpty)
            #expect(record.formattedLine.contains("typed text") == false)
        }
    }

    @Test("a granted insertion logs nothing")
    func grantedInsertionIsSilent() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let pasteboardName = pasteboard.name
        try await withSink { sink in
            let inserter = KeystrokeTextInserter(trustCheck: { true }, pasteboardName: pasteboardName)
            try await inserter.insert("")
            let permissionRecords = sink.records.filter { $0.category == .appPermissions }
            #expect(permissionRecords.isEmpty)
        }
    }
}
