import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Transcript display mode source of truth")
struct TranscriptDisplayModeTests {

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("displaymode"))
    }

    @Test("default display mode is the continuous transcript")
    func defaultsToTranscript() {
        let model = makeModel(temporaryDefaults())
        #expect(model.transcriptDisplayMode == .transcript)
    }

    @Test("setting the mode persists to the model's defaults under transcriptDisplayMode")
    func writePersists() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)

        model.transcriptDisplayMode = .segments

        #expect(model.transcriptDisplayMode == .segments)
        #expect(defaults.string(forKey: "transcriptDisplayMode") == TranscriptDisplayMode.segments.rawValue)
    }

    @Test("a persisted value is read back at bootstrap")
    func readsPersistedValueOnInit() {
        let defaults = temporaryDefaults()
        defaults.set(TranscriptDisplayMode.segments.rawValue, forKey: "transcriptDisplayMode")

        let model = makeModel(defaults)

        #expect(model.transcriptDisplayMode == .segments)
    }

    @Test("reloadObservedSetting reflects an external default write into the live property")
    func externalWriteReflectsAfterReload() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        #expect(model.transcriptDisplayMode == .transcript)

        defaults.set(TranscriptDisplayMode.segments.rawValue, forKey: "transcriptDisplayMode")
        model.reloadObservedSetting(key: "transcriptDisplayMode")

        #expect(model.transcriptDisplayMode == .segments)
    }

    @Test("an unknown persisted value falls back to the continuous transcript")
    func unknownRawFallsBack() {
        let defaults = temporaryDefaults()
        defaults.set("garbage", forKey: "transcriptDisplayMode")

        let model = makeModel(defaults)

        #expect(model.transcriptDisplayMode == .transcript)
    }
}
