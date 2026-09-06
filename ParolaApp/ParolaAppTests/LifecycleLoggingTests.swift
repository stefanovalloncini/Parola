import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("App lifecycle logging", .serialized, .logFacade)
struct LifecycleLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        ParolaLog.install(sink)
        defer { ParolaLog.uninstall() }
        try await body(sink)
    }

    private func appSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/LifecycleLoggingTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("the resolved side effects and features are logged as sorted case names")
    func bootstrapResolved() async throws {
        try await withSink { sink in
            let bootstrap = AppBootstrap(
                mode: .test,
                library: makeTempLibraryURL("lifecycle-logging"),
                defaultsOverride: temporaryDefaults("lifecycle-"),
                sideEffects: [.automationBridge, .diagnosticsLog],
                filePicker: TestFilePicker(),
                enabledFeaturesOverride: [.ai, .batch]
            )
            let model = AppModel(bootstrap: bootstrap)

            let records = sink.records.filter { $0.category == .appLifecycle }
            let record = try #require(records.first)
            #expect(record.level == .info)
            #expect(record.message.rendered == "side effects automationBridge,diagnosticsLog, features ai,batch")
            #expect(record.message.template == "side effects %@, features %@")
            withExtendedLifetime(model) {}
        }
    }

    @Test("a bootstrap with nothing switched on still says so")
    func emptySideEffects() async throws {
        try await withSink { sink in
            let model = AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults("lifecycle-"),
                libraryURL: makeTempLibraryURL("lifecycle-logging-empty"),
                features: []
            )

            let record = try #require(sink.records.first { $0.category == .appLifecycle })
            #expect(record.message.rendered == "side effects none, features none")
            withExtendedLifetime(model) {}
        }
    }

    @Test("a phase renders as its case name, never its payload")
    func phaseTokens() {
        #expect(AppModel.Phase.idle.logToken == "idle")
        #expect(AppModel.Phase.ready.logToken == "ready")
        #expect(AppModel.Phase.failed(message: "/Users/x/secret.wav is missing").logToken == "failed")
        #expect(AppModel.Phase.transcribing(file: URL(fileURLWithPath: "/Users/x/secret.wav")).logToken == "transcribing")
        #expect(AppModel.Phase.downloadingModel(name: "openai_whisper-tiny", progress: 0.5).logToken == "downloadingModel")
    }

    @Test("a version that is not a version number is not echoed")
    func versionToken() throws {
        let bundle = Bundle(for: BundleMarker.self)
        #expect(AppVersionToken(bundle: bundle).logToken.contains("/") == false)

        let plausible = AppVersionToken(bundle: Bundle.main).logToken
        #expect(plausible.contains("(") && plausible.contains(")"))
    }

    /// `applicationDidFinishLaunching` and `applicationWillTerminate` need a live `NSApplication`
    /// delegate callback, so their calls are pinned in source.
    @Test("launch and terminate log the version and the phase, and nothing else")
    func delegateSites() throws {
        let delegate = try appSource("AppDelegate")
        #expect(delegate.contains(
            #"ParolaLog.info(.appLifecycle, "app launched, version \(AppVersionToken())")"#
        ))
        #expect(delegate.contains(
            #"ParolaLog.info(.appLifecycle, "app terminating in phase \(model?.phase)")"#
        ))
    }
}

/// Only there to name the test bundle for `Bundle(for:)`.
private final class BundleMarker {}
