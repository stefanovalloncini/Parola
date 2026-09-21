import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Introduction feature grid")
struct FeaturesGridTests {
    @Test("the loop phase wraps every four seconds")
    func phaseTable() {
        #expect(FeatureVignettePhase.phase(at: 0) == 0)
        #expect(FeatureVignettePhase.phase(at: 2) == 0.5)
        #expect(FeatureVignettePhase.phase(at: 4) == 0)
        #expect(FeatureVignettePhase.phase(at: 5) == 0.25)
    }

    @Test("a ramp holds at both ends")
    func rampTable() {
        #expect(FeatureVignettePhase.ramp(0, from: 0.2, span: 0.2) == 0)
        #expect(abs(FeatureVignettePhase.ramp(0.3, from: 0.2, span: 0.2) - 0.5) < 1e-9)
        #expect(FeatureVignettePhase.ramp(1, from: 0.2, span: 0.2) == 1)
        #expect(FeatureVignettePhase.ramp(0.5, from: 0.2, span: 0) == 1)
    }

    @Test("every feature row has a vignette")
    func everyRowHasAVignette() {
        for item in FeaturesScene.rows(features: .all) {
            #expect(FeatureVignetteKind(symbol: item.symbol) != nil)
        }
        #expect(FeatureVignetteKind(symbol: "questionmark") == nil)
    }
}
