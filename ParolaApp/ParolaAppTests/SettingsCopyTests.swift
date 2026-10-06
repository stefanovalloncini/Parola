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

    @Test("Customization's summary names what the pane holds")
    func customizationSummary() {
        #expect(SettingsRoute.customization.summary == "Appearance, theme colors and timestamp font.")
    }

    @Test("Keep AI on this Mac sits at the top of AI Services, not in Transcription Defaults")
    func keepAIOnThisMacLivesWithTheServices() throws {
        let model = makeModel("settings-copy-privacy")
        let defaults = words(TranscriptionDefaultsPane(), model: model)
        #expect(!defaults.contains("Privacy mode"), "\(defaults)")
        let services = elements(AIServicesPane(), model: model)
        let checkBox = services.first { $0.role == NSAccessibility.Role.checkBox.rawValue }
        let firstSwitch = try #require(checkBox)
        #expect(firstSwitch.name == "Keep AI on this Mac")
        #expect(SettingsPaneScope.aiServices.defaultsKeys.contains(ManagedConfiguration.userPrivacyModeKey))
        #expect(!SettingsPaneScope.transcriptionDefaults.defaultsKeys.contains(ManagedConfiguration.userPrivacyModeKey))
    }

    private static let textRoles: Set<String> = [NSAccessibility.Role.textField.rawValue, NSAccessibility.Role.textArea.rawValue]

    @Test("the AI title and summary instructions are named fields under Library cards; vocabulary sits with the model it feeds")
    func instructionsAreNamedAndVocabularyMoves() {
        let model = makeModel("settings-copy-instructions")
        let general = elements(GeneralPane(), model: model)
        let generalFields = general.filter { Self.textRoles.contains($0.role ?? "") }.map { $0.name ?? "unnamed" }
        #expect(generalFields == ["Title instructions", "Summary instructions"])
        let generalWords = general.flatMap(\.words)
        #expect(!generalWords.contains("Custom instructions"), "\(generalWords)")
        #expect(!generalWords.contains("Custom vocabulary"), "\(generalWords)")

        let defaults = elements(TranscriptionDefaultsPane(), model: model)
        let defaultsFields = defaults.filter { Self.textRoles.contains($0.role ?? "") }.map { $0.name ?? "unnamed" }
        #expect(defaultsFields == ["Custom vocabulary"])
        #expect(SettingsPaneScope.transcriptionDefaults.defaultsKeys.contains("initialPrompt"))
        #expect(!SettingsPaneScope.general.defaultsKeys.contains("initialPrompt"))
    }

    @Test("Shortcuts holds the two shortcuts Parola lets you set and the permission they need, not a copy of the menus")
    func shortcutsPaneHoldsWhatYouCanSet() {
        let model = makeModel("settings-copy-shortcuts")
        let shortcuts = elements(ShortcutsPane(), model: model)
        let words = shortcuts.flatMap(\.words)
        #expect(!words.contains("Menu equivalents"), "\(words)")
        #expect(!words.contains("⌘O"), "\(words)")
        let inputMonitoring = words.filter { $0.contains("Input Monitoring") }
        #expect(inputMonitoring.isEmpty, "\(inputMonitoring)")
        #expect(words.contains("Dictation shortcut"), "\(words)")
        #expect(words.contains("Recording shortcut"), "\(words)")
        #expect(words.contains("Accessibility"), "\(words)")
    }

    @Test("the microphone error offers System Settings when access is off, whatever language the error is in")
    func micErrorDecidesOnTheStatus() {
        #expect(MicErrorBanner.offersSystemSettings(for: .denied))
        #expect(MicErrorBanner.offersSystemSettings(for: .restricted))
        #expect(!MicErrorBanner.offersSystemSettings(for: .authorized))
        #expect(!MicErrorBanner.offersSystemSettings(for: .notDetermined))
    }

    @Test("Record Meetings asks only for the permission the capture setting uses; the other reads Not needed")
    func recordMeetingsAsksForWhatItUses() {
        #expect(RecordMeetingsPane.neededPermissions(appOnly: false) == .init(screenRecording: true, systemAudio: false))
        #expect(RecordMeetingsPane.neededPermissions(appOnly: true) == .init(screenRecording: false, systemAudio: true))

        let model = makeModel("settings-copy-meetings")
        for appOnly in [false, true] {
            model.meetingCaptureAppOnly = appOnly
            let words = words(RecordMeetingsPane(), model: model)
            let notNeeded = words.filter { $0 == "Not needed" }.count
            #expect(notNeeded == 1, "\(appOnly): \(words)")
            #expect(!words.contains("Parola watches running applications; nothing leaves your Mac."))
        }
    }
}
