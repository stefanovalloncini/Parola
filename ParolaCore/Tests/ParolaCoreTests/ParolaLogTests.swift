import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("Parola log facade", .serialized, .logFacade)
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

    @Test("a filtered call builds neither its message nor its fields")
    func filteredCallBuildsNothing() {
        ParolaLog.uninstall()
        let logger = Logger(
            subsystem: LogSubsystem.core.rawValue, category: LogCategory.models.rawValue
        )
        guard !logger.isEnabled(type: .debug) else { return }
        var builds = 0
        func token() -> ModelToken {
            builds += 1
            return ModelToken("openai_whisper-tiny")
        }
        ParolaLog.debug(.models, "loading \(token())", [.model: .safe(token())])
        #expect(builds == 0)
    }

    @Test("a call an installed sink will see builds its message and fields")
    func capturedCallBuildsEverything() {
        withSink { sink in
            var builds = 0
            func token() -> ModelToken {
                builds += 1
                return ModelToken("openai_whisper-tiny")
            }
            ParolaLog.debug(.models, "loading \(token())", [.model: .safe(token())])
            #expect(builds == 2)
            #expect(sink.records.filter { $0.category == .models }.count == 1)
        }
    }

    @Test("a record's subsystem follows its category, not the host process")
    func subsystemFollowsCategory() throws {
        try withSink { sink in
            ParolaLog.info(.appLifecycle, "launched")
            ParolaLog.info(.library, "swept")
            ParolaLog.info(.cli, "ran")
            #expect(sink.records.first { $0.category == .appLifecycle }?.subsystem == .app)
            #expect(sink.records.first { $0.category == .library }?.subsystem == .core)
            #expect(sink.records.first { $0.category == .cli }?.subsystem == .cli)
        }
    }

    @Test("every engine category stays on the subsystem its signposter hardcodes")
    func engineCategoriesStayOnCore() {
        let engineCategories: [LogCategory] = [.engineWhisperKit, .engineParakeet, .engineAppleSpeech]
        for category in engineCategories {
            #expect(
                category.subsystem == .core,
                "\(category.rawValue) must match OSSignposter(subsystem: \"app.parola.core\")"
            )
        }
    }

    @Test("no category falls outside the three known subsystems")
    func everyCategoryMapsSomewhere() {
        let byApp = LogCategory.allCases.filter { $0.subsystem == .app }.map(\.rawValue)
        #expect(byApp.sorted() == ["app.bridge", "app.lifecycle", "app.permissions", "app.recovery"])
        #expect(LogCategory.allCases.filter { $0.subsystem == .cli }.map(\.rawValue) == ["cli"])
    }
}
