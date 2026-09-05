import Foundation
import Testing
@testable import ParolaCore

@Suite("Scoped capturing sink")
struct ScopedCapturingSinkTests {
    private func record(_ text: StaticString) -> LogRecord {
        LogRecord(
            timestamp: Date(timeIntervalSince1970: 1_755_871_082),
            level: .info, subsystem: .core, category: .models,
            message: LogMessage(stringLiteral: text), fields: [:],
            file: "T.swift", line: 1
        )
    }

    @Test("records emitted inside the scope are kept, and none are dropped")
    func keepsItsOwnRecords() async {
        let sink = ScopedCapturingSink()
        await sink.scope {
            sink.enqueue(record("mine"))
            sink.enqueue(record("mine too"))
        }
        #expect(sink.records.map(\.message.rendered) == ["mine", "mine too"])
        #expect(sink.droppedCount == 0)
    }

    @Test("a record from outside the scope is dropped and counted")
    func dropsAndCountsForeignRecords() async {
        let sink = ScopedCapturingSink()
        sink.enqueue(record("before"))
        await sink.scope { sink.enqueue(record("mine")) }
        sink.enqueue(record("after"))

        #expect(sink.records.map(\.message.rendered) == ["mine"])
        #expect(sink.droppedCount == 2)
    }

    @Test("two sinks in flight keep their own records apart")
    func sinksDoNotSeeEachOther() async {
        let first = ScopedCapturingSink()
        let second = ScopedCapturingSink()
        await first.scope {
            first.enqueue(record("first"))
            second.enqueue(record("first"))
        }
        #expect(first.records.count == 1)
        #expect(second.records.isEmpty)
        #expect(second.droppedCount == 1)
    }
}
