import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Settings copy: one name and one home per setting", .serialized)
struct SettingsCopyTests {
    private func makeModel(_ label: String) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL(label), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
    }

    /// What VoiceOver reads on a hosted pane.
    private func elements(_ pane: some View, model: AppModel) -> [HostedAccessibility.Element] {
        let hosted = HostedWindow(
            ScrollView { pane.padding() }
                .environment(model)
                .environment(LiveCaptionsController(showsPanel: false)),
            width: 900, height: 2400
        )
        defer { hosted.close() }
        return HostedAccessibility.elements(in: hosted.host)
    }

    private func words(_ pane: some View, model: AppModel) -> [String] {
        elements(pane, model: model).flatMap(\.words)
    }

    @Test("speaker detection and word timestamps live in Transcription Defaults alone, under plain names")
    func oneHomeForSpeakersAndTimestamps() {
        let model = makeModel("settings-copy-speakers")
        let general = words(GeneralPane(), model: model)
        #expect(!general.contains("Word timestamps"), "\(general)")
        #expect(!general.contains("Diarize speakers"), "\(general)")

        let defaults = words(TranscriptionDefaultsPane(), model: model)
        #expect(defaults.contains("Detect speakers"), "\(defaults)")
        #expect(defaults.contains("Word timestamps"), "\(defaults)")
        let karaoke = defaults.filter { $0.localizedCaseInsensitiveContains("karaoke") }
        #expect(karaoke.isEmpty, "\(karaoke)")

        let peopleSwitches = elements(PeoplePane(), model: model)
            .filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
            .compactMap(\.name)
        #expect(peopleSwitches == ["Show most used people in the sidebar"])

        #expect(SettingsPaneScope.transcriptionDefaults.defaultsKeys.contains("diarize"))
        #expect(SettingsPaneScope.transcriptionDefaults.defaultsKeys.contains("wordTimestamps"))
        for scope in [SettingsPaneScope.general, .people] {
            #expect(!scope.defaultsKeys.contains("diarize"), "\(scope)")
            #expect(!scope.defaultsKeys.contains("wordTimestamps"), "\(scope)")
        }
    }
}
