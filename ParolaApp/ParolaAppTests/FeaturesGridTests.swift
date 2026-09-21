import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Introduction feature grid")
struct FeaturesGridTests {
    @Test("cards pair two to a row, an odd last one stays alone")
    func arrangementTable() {
        #expect(FeaturesScene.arrangement(count: 0) == [])
        #expect(FeaturesScene.arrangement(count: 1) == [[0]])
        #expect(FeaturesScene.arrangement(count: 2) == [[0, 1]])
        #expect(FeaturesScene.arrangement(count: 3) == [[0, 1], [2]])
        #expect(FeaturesScene.arrangement(count: 4) == [[0, 1], [2, 3]])
    }

    @Test("every deployment's rows fit two grid rows, in order")
    func arrangementCoversEveryRowCount() {
        for count in 0...4 {
            let rows = FeaturesScene.arrangement(count: count)
            #expect(rows.count <= 2)
            #expect(rows.flatMap(\.self) == Array(0..<count))
            #expect(rows.allSatisfy { $0.count <= 2 })
        }
    }

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
