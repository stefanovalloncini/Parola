import Foundation
import Testing
@testable import ParolaCore

@Suite("Apple Speech transcriber")
struct AppleSpeechTranscriberTests {
    @Test("pickLocale honors an explicit language code")
    func pickLocaleExplicit() {
        let locale = AppleSpeechTranscriber.pickLocale(language: "it")
        #expect(locale.identifier.starts(with: "it"))
    }

    @Test("pickLocale falls back to current when language is nil")
    func pickLocaleNilFallback() {
        let locale = AppleSpeechTranscriber.pickLocale(language: nil)
        #expect(locale.identifier.isEmpty == false)
    }

    @Test("synthetic model id is stable")
    func syntheticIDStable() {
        #expect(AppleSpeechTranscriber.syntheticModelID == "apple-speech-analyzer")
    }

    @Test("ModelCatalog exposes apple speech variant on macOS 26+")
    func catalogExposesVariant() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let entry = ModelCatalog.variant(id: AppleSpeechTranscriber.syntheticModelID)
        #expect(entry != nil)
        #expect(entry?.engineID == .appleSpeech)
        #expect(entry?.sizeBytes == 0)
    }

    @Test("ModelStore reports apple speech as installed without disk presence")
    func storeReportsInstalled() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ModelStore(modelsDirectory: tmp)
        #expect(store.isInstalled(AppleSpeechTranscriber.syntheticModelID))
    }

    @Test("cancelInFlight without a running transcribe is a no-op")
    func cancelInFlightIdle() async {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ModelStore(modelsDirectory: tmp)
        let engine = AppleSpeechTranscriber(modelStore: store)
        await engine.cancelInFlight()
        let loaded = await engine.loadedModelName()
        #expect(loaded == nil)
    }
}
