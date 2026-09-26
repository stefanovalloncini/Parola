import Foundation
import Testing
import ParolaCore
@testable import parola

@Suite("parola engines list")
struct EnginesListTests {
    @Test("Apple Speech is listed without word timestamps, Whisper and Parakeet with them")
    func wordTimestampColumnMatchesTheEngines() async {
        let rows = await Engines.List().engineRows()
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        #expect(byID[.whisperKit]?.cells == ["WhisperKit", "All", "yes", "yes", "yes", "yes"])
        #expect(byID[.parakeet]?.cells == ["Parakeet", "All", "no", "no", "yes", "yes"])
        #expect(byID[.appleSpeech]?.cells == ["Apple Speech", "All", "no", "no", "no", "no"])
    }
}
