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

    @Test("pickLocale uses a bare-language locale when no region default exists")
    func pickLocaleNoRegionDefault() {
        // Swedish has no entry in regionDefaults; it must not fabricate an invalid "sv_US".
        let sv = AppleSpeechTranscriber.pickLocale(language: "sv")
        #expect(sv.identifier == "sv")
        #expect(sv.identifier.contains("US") == false)
        // Languages with a known region default still get it.
        #expect(AppleSpeechTranscriber.pickLocale(language: "en").identifier == "en_US")
        #expect(AppleSpeechTranscriber.pickLocale(language: "it").identifier == "it_IT")
    }

    @Test("synthetic model id is stable")
    func syntheticIDStable() {
        #expect(AppleSpeechTranscriber.syntheticModelID == "apple-speech-analyzer")
    }

    @Test("the collector's callback interval is a tenth of a second")
    func callbackIntervalIsATenthOfASecond() {
        #expect(AppleSpeechTranscriber.callbackInterval == .milliseconds(100))
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

    @Test("an unreported tail is measured from the last result, not from the last segment kept")
    func unreportedTailMeasuresTheGap() {
        let gap = try? #require(AppleSpeechTranscriber.unreportedTail(duration: 650.07, lastResultEnd: 607.02))
        #expect(abs((gap ?? 0) - 43.05) < 0.001)
        #expect(AppleSpeechTranscriber.unreportedTail(duration: 951.04, lastResultEnd: 951.0) == nil)
        #expect(AppleSpeechTranscriber.unreportedTail(duration: 20, lastResultEnd: nil) == 20)
        #expect(AppleSpeechTranscriber.unreportedTail(duration: 10, lastResultEnd: nil) == nil)
        #expect(AppleSpeechTranscriber.unreportedTail(duration: 0, lastResultEnd: nil) == nil)
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
