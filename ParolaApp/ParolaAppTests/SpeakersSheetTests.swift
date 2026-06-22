import Testing
@testable import Parola

@MainActor
@Suite("SpeakersSheet suggestion gating")
struct SpeakersSheetTests {
    @Test("offers recent suggestions only when there is a speaker to assign to")
    func offersOnlyWithSpeakers() {
        #expect(SpeakersSheet.offersSuggestions(hasSpeakers: true, hasSuggestions: true))
        #expect(!SpeakersSheet.offersSuggestions(hasSpeakers: false, hasSuggestions: true))
        #expect(!SpeakersSheet.offersSuggestions(hasSpeakers: true, hasSuggestions: false))
        #expect(!SpeakersSheet.offersSuggestions(hasSpeakers: false, hasSuggestions: false))
    }
}
