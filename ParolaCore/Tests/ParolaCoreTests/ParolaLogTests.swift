import Foundation
import Testing
@testable import ParolaCore

@Suite("Parola log facade", .serialized)
struct ParolaLogTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) throws -> Void) rethrows {
        let sink = CapturingDiagnosticsSink()
        ParolaLog.install(sink)
        defer { ParolaLog.uninstall() }
        try body(sink)
    }

    @Test("an emitted record reaches the installed sink")
    func reachesSink() throws {
        try withSink { sink in
            ParolaLog.error(.models, "download failed", [.model: .safe(ModelToken("openai_whisper-large-v3_turbo"))])
            let records = sink.records.filter { $0.category == .models }
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.level == .error)
            #expect(record.category == .models)
            #expect(record.message.rendered == "download failed")
            #expect(record.fields[.model]?.text == "openai_whisper-large-v3_turbo")
        }
    }

    @Test("call site metadata is captured automatically")
    func capturesCallSite() throws {
        try withSink { sink in
            ParolaLog.notice(.library, "swept")
            let records = sink.records.filter { $0.category == .library }
            let record = try #require(records.first)
            #expect(record.file.contains("ParolaLogTests"))
            #expect(record.line > 0)
        }
    }

    @Test("logging with no sink installed does not trap")
    func noSinkIsSafe() {
        ParolaLog.uninstall()
        ParolaLog.error(.models, "no sink installed")
    }

    @Test("every level reaches the sink")
    func allLevels() {
        withSink { sink in
            ParolaLog.debug(.cli, "d")
            ParolaLog.info(.cli, "i")
            ParolaLog.notice(.cli, "n")
            ParolaLog.error(.cli, "e")
            ParolaLog.fault(.cli, "f")
            let records = sink.records.filter { $0.category == .cli }
            #expect(records.map(\.level) == [.debug, .info, .notice, .error, .fault])
        }
    }

    @Test("the subsystem is configurable by the frontend")
    func configurableSubsystem() throws {
        try withSink { sink in
            ParolaLog.configure(subsystem: .app)
            defer { ParolaLog.configure(subsystem: .core) }
            ParolaLog.info(.appLifecycle, "launched")
            let records = sink.records.filter { $0.category == .appLifecycle }
            let record = try #require(records.first)
            #expect(record.subsystem == "app.parola.app")
        }
    }
}
