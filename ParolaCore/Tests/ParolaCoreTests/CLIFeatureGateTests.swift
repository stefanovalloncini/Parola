import Testing
@testable import ParolaCore

@Suite("CLI feature gating")
struct CLIFeatureGateTests {
    @Test func gatedSubcommandsDropOut() {
        let names = CLISubcommandPolicy.visible(features: FeatureSet(enabled: [.batch]))
        #expect(!names.contains("record"))
        #expect(!names.contains("mcp"))
        #expect(names.contains("transcribe"))
        #expect(names.contains("models"))
    }

    @Test func recordStaysWithEitherCaptureFeature() {
        #expect(CLISubcommandPolicy.visible(features: FeatureSet(enabled: [.micRecording])).contains("record"))
        #expect(CLISubcommandPolicy.visible(features: FeatureSet(enabled: [.meetings])).contains("record"))
    }

    @Test func fullSetKeepsEverything() {
        let names = CLISubcommandPolicy.visible(features: .all)
        #expect(names.contains("record"))
        #expect(names.contains("mcp"))
        #expect(names.first == "transcribe")
    }
}
