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

@MainActor
@Suite("Introduction permission rows")
struct ReadySceneRowsTests {
    private func rows(_ features: ParolaFeature...) -> [ReadyScene.PermissionKind] {
        ReadyScene.permissionRows(features: FeatureSet(enabled: Set(features)))
    }

    @Test("a full deployment asks for all three")
    func allThree() {
        #expect(ReadyScene.permissionRows(features: .all) == [.microphone, .systemAudio, .accessibility])
    }

    @Test("the microphone row stands for recording, dictation and captions alike")
    func microphoneGating() {
        #expect(rows(.micRecording) == [.microphone])
        #expect(rows(.liveCaptions) == [.microphone])
        #expect(rows(.dictation) == [.microphone, .accessibility])
    }

    @Test("system audio belongs to meetings")
    func systemAudioGating() {
        #expect(rows(.meetings) == [.systemAudio])
        #expect(rows(.meetings, .micRecording) == [.microphone, .systemAudio])
    }

    @Test("a deployment that needs nothing gets no section")
    func noRows() {
        #expect(rows(.batch).isEmpty)
        #expect(rows().isEmpty)
    }
}

@Suite("The welcome sheet is gone")
struct WelcomeSheetRetirementTests {
    @Test("no source names the retired sheet or its accessibility ids")
    func noWelcomeReferences() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ParolaApp")
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated()
            where line.contains("WelcomeSheet") || line.contains("Welcome.Button") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }

        #expect(scanned > 0, "no sources found under \(sources.path)")
        #expect(offenders.isEmpty, "the welcome sheet lives on at \(offenders.joined(separator: ", "))")
    }
}
