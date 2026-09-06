import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Dictation logging", .serialized)
struct DictationLoggingTests {
    private actor SilentHotkey: HotkeyMonitor {
        func start(handler: @escaping @Sendable (HotkeyEvent) -> Void) async {}
        func stop() async {}
    }

    private struct StartFailure: Error, LocalizedError {
        var errorDescription: String? { "microphone is busy" }
    }

    private struct TranscribeFailure: Error, LocalizedError {
        var errorDescription: String? { "the engine gave up" }
    }

    private actor ScriptedRecorder: DictationRecorder {
        enum Outcome: Sendable {
            case text(String)
            case startThrows
            case transcribeThrows
        }

        private let outcome: Outcome

        init(_ outcome: Outcome) { self.outcome = outcome }

        func start() async throws {
            if case .startThrows = outcome { throw StartFailure() }
        }

        func stopAndTranscribe() async throws -> String {
            switch outcome {
            case .text(let text): return text
            case .transcribeThrows: throw TranscribeFailure()
            case .startThrows: return ""
            }
        }

        func stopAndDiscard() async {}
    }

    private actor SilentInserter: TextInserter {
        func insert(_ text: String) async {}
    }

    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func dictationRecords(_ sink: CapturingDiagnosticsSink) -> [LogRecord] {
        sink.records.filter { $0.category == .dictation }
    }

    private func makeCoordinator(
        _ outcome: ScriptedRecorder.Outcome,
        mode: DictationMode = .pushToTalk
    ) -> DictationCoordinator {
        DictationCoordinator(
            hotkey: SilentHotkey(),
            recorder: ScriptedRecorder(outcome),
            inserter: SilentInserter(),
            mode: mode,
            features: .all
        )
    }

    @Test("a recorder that will not start is logged with the mode it was in")
    func recorderStartFailure() async throws {
        try await withSink { sink in
            let coordinator = makeCoordinator(.startThrows, mode: .toggle)
            await coordinator.startMonitoring()
            await coordinator.handle(.press)

            let record = try #require(
                dictationRecords(sink).first {
                    $0.message.rendered == "dictation recorder failed to start in toggle"
                }
            )
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("microphone is busy") == false)
        }
    }

    @Test("a finish that throws is logged with the mode and how long it took")
    func finishFailure() async throws {
        try await withSink { sink in
            let coordinator = makeCoordinator(.transcribeThrows)
            await coordinator.startMonitoring()
            await coordinator.handle(.press)
            await coordinator.handle(.release)

            let record = try #require(
                dictationRecords(sink).first {
                    $0.message.rendered == "dictation finish failed in pushToTalk"
                }
            )
            #expect(record.level == .error)
            #expect(record.fields[.elapsed] != nil)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("the engine gave up") == false)
        }
    }

    @Test("every state transition is a debug record, in order")
    func stateTransitions() async {
        await withSink { sink in
            let coordinator = makeCoordinator(.text("hello"))
            await coordinator.startMonitoring()
            await coordinator.handle(.press)
            await coordinator.handle(.release)

            let transitions = dictationRecords(sink)
                .filter { $0.message.rendered.hasPrefix("dictation state") }
            #expect(transitions.map(\.message.rendered) == [
                "dictation state → listening",
                "dictation state → transcribing",
                "dictation state → idle",
            ])
            #expect(transitions.allSatisfy { $0.level == .debug })
            #expect(transitions.allSatisfy { $0.fields.isEmpty })
        }
    }

    @Test("a failed transition logs the case name, never the failure text")
    func failedTransitionDropsItsPayload() async {
        await withSink { sink in
            let coordinator = makeCoordinator(.transcribeThrows)
            await coordinator.startMonitoring()
            await coordinator.handle(.press)
            await coordinator.handle(.release)

            let transitions = dictationRecords(sink)
                .filter { $0.message.rendered.hasPrefix("dictation state") }
            #expect(transitions.map(\.message.rendered).last == "dictation state → failed")
            #expect(dictationRecords(sink).allSatisfy {
                $0.formattedLine.contains("the engine gave up") == false
            })
        }
    }
}
