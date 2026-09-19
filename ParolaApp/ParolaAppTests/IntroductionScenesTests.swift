import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Introduction feature rows")
struct FeaturesSceneRowsTests {
    private func rows(_ features: ParolaFeature...) -> [FeatureRow.Item] {
        FeaturesScene.rows(features: FeatureSet(enabled: Set(features)))
    }

    @Test("every feature gets a row, transcription first")
    func everyRow() {
        let items = FeaturesScene.rows(features: .all)
        #expect(items.map(\.symbol) == ["text.alignleft", "person.2", "text.cursor", "captions.bubble.fill"])
        #expect(items[0].title == "Transcribe files and links")
        #expect(items[0].line == "Drop audio or video, or paste a YouTube link.")
        #expect(items[1].title == "Record meetings")
        #expect(items[2].title == "Dictate in any app")
        #expect(items[3].title == "Live captions")
    }

    @Test("without YouTube the transcription row stops promising links")
    func withoutYouTube() {
        let items = rows(.batch)
        #expect(items.count == 1)
        #expect(items[0].title == "Transcribe files")
        #expect(items[0].line == "Drop audio or video files.")
    }

    @Test("a disabled unit has no row")
    func disabledUnitsHaveNoRow() {
        #expect(rows(.youtube).map(\.symbol) == ["text.alignleft"])
        #expect(rows(.youtube, .meetings).map(\.symbol) == ["text.alignleft", "person.2"])
        #expect(rows(.youtube, .liveCaptions).map(\.symbol) == ["text.alignleft", "captions.bubble.fill"])
        #expect(rows(.dictation).map(\.symbol) == ["text.alignleft", "text.cursor"])
    }
}
