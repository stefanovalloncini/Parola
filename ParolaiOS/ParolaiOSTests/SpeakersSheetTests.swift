import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Speakers sheet copy")
struct SpeakersSheetTests {
    @Test("the no-speakers hint names no Settings switch, since iOS has none")
    func noSpeakersHintNamesNoSettingsSwitch() {
        #expect(!SpeakersSheet.noSpeakersHint.localizedCaseInsensitiveContains("settings"))
        #expect(SpeakersSheet.noSpeakersHint == "This transcript has no speakers.")
    }
}
