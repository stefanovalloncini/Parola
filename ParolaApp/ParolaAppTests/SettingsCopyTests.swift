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

    @Test("the speaker switch is Detect speakers on the Library page, in the Speakers sheet and in its warning")
    func detectSpeakersEverywhere() throws {
        let model = makeModel("settings-copy-detect-speakers")
        model.diarize = true
        let intake = words(IntakeSettingsPopover(), model: model)
        #expect(intake.contains("Detect speakers"), "\(intake)")
        #expect(!intake.contains { $0.localizedCaseInsensitiveContains("identify speakers") || $0.contains("diariz") }, "\(intake)")

        let sheet = words(SpeakersSheet(transcript: Transcript(segments: [], language: "en", modelName: "mock")), model: model)
        let hint = "This transcript has no speakers. Turn on Detect speakers in Settings › Transcription Defaults, then choose Transcript ▸ Transcribe Again."
        #expect(sheet.contains(hint), "\(sheet)")

        model.selectedModel = "apple-speech-analyzer"
        let warning = try #require(model.diarizeMismatchWarning)
        #expect(warning.hasSuffix(" can't detect speakers, so speaker detection is skipped."), "\(warning)")
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        let key = "%@ can't detect speakers, so speaker detection is skipped."
        #expect(italian.localizedString(forKey: key, value: "MISSING", table: nil) != "MISSING")
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

    @Test("Record Meetings always asks for Screen Recording; System Audio Recording only with app-only capture")
    func recordMeetingsAsksForWhatItUses() {
        #expect(RecordMeetingsPane.neededPermissions(appOnly: false) == .init(screenRecording: true, systemAudio: false))
        #expect(RecordMeetingsPane.neededPermissions(appOnly: true) == .init(screenRecording: true, systemAudio: true))

        let model = makeModel("settings-copy-meetings")
        for appOnly in [false, true] {
            model.meetingCaptureAppOnly = appOnly
            let words = words(RecordMeetingsPane(), model: model)
            let notNeeded = words.filter { $0 == "Not needed" }.count
            #expect(notNeeded == (appOnly ? 0 : 1), "\(appOnly): \(words)")
            #expect(!words.contains("Parola watches running applications; nothing leaves your Mac."))
        }
    }

    @Test("Live Captions says it captions what you say, and starts from its own pane")
    func liveCaptionsStartsFromThePane() {
        #expect(SettingsRoute.liveCaptions.summary == "Captions of what you say, in a floating window.")
        let model = makeModel("settings-copy-captions")
        let pane = elements(LiveCaptionsPane(), model: model)
        let buttons = pane.filter { $0.role == NSAccessibility.Role.button.rawValue }.compactMap(\.name)
        #expect(buttons.contains("Start Live Captions"), "\(buttons)")
        let words = pane.flatMap(\.words)
        #expect(!words.contains("Status"), "\(words)")
    }

    @Test("the yt-dlp pane is named for the job, and without Homebrew it offers the download instead of a dead install")
    func linksPane() {
        #expect(SettingsRoute.integrations.label == "Links")
        #expect(SettingsRoute.integrations.symbol == "link")
        #expect(SettingsPaneScope.integrations.localizedLabel == "Links")
        #expect(IntegrationsPane.installChoice(available: false, homebrewAvailable: true) == .homebrew)
        #expect(IntegrationsPane.installChoice(available: false, homebrewAvailable: false) == .download)
        #expect(IntegrationsPane.installChoice(available: true, homebrewAvailable: false) == nil)

        let model = makeModel("settings-copy-links")
        model.ytDlpLocator = { nil }
        model.brewLocator = { nil }
        model.refreshYtDlpAvailability()
        #expect(model.homebrewAvailable == false)
        model.brewLocator = { "/opt/homebrew/bin/brew" }
        model.refreshYtDlpAvailability()
        #expect(model.homebrewAvailable)
    }

    @Test("a downloaded model is made the default with Use as Default, and the chosen one reads Default")
    func modelRowsSayDefault() throws {
        let variant = try #require(ModelCatalog.all.first)
        let model = makeModel("settings-copy-default-model")
        let installed = words(ModelCardRow(variant: variant, kind: .installed, primaryAction: {}), model: model)
        #expect(installed.contains("Use as Default"), "\(installed)")
        #expect(!installed.contains("Activate"), "\(installed)")
        let active = words(ModelCardRow(variant: variant, kind: .active, primaryAction: {}), model: model)
        #expect(active.contains("Default"), "\(active)")
    }

    @Test("Translation splits Apple Translation after transcribing from Whisper while transcribing, with no read-only provider row")
    func translationNamesItsTwoEngines() {
        let model = makeModel("settings-copy-translation")
        let words = words(TranslationPane(), model: model)
        #expect(!words.contains("Translation provider"), "\(words)")
        let after = words.firstIndex(of: "After transcribing")
        let sideBySide = words.firstIndex(of: "Show translations side by side")
        let during = words.firstIndex(of: "While transcribing")
        let byDefault = words.firstIndex(of: "Translate to English by default")
        #expect(after != nil && during != nil, "\(words)")
        if let after, let sideBySide, let during, let byDefault {
            #expect(after < sideBySide && sideBySide < during && during < byDefault, "\(words)")
        }
    }

    @Test("export presets go by one name in Settings, and Batch Export has no fake Drag & Drop row")
    func exportPresetsHaveOneName() {
        #expect(SettingsRoute.exportFormats.label == "Export Presets")
        #expect(SettingsPaneScope.exportFormats.localizedLabel == "Export Presets")
        let model = makeModel("settings-copy-presets")
        let batch = words(BatchExportSettingsPane(), model: model)
        #expect(batch.contains("Export Presets"), "\(batch)")
        let sidecar = batch.filter { $0.localizedCaseInsensitiveContains("sidecar") }
        #expect(sidecar.isEmpty, "\(sidecar)")
        #expect(!batch.contains("Drag & Drop"), "\(batch)")
    }

    @Test("AI Services calls the on-device model Apple Intelligence everywhere and adds a service from one menu")
    func aiServicesNamesAppleIntelligenceOnce() {
        let model = makeModel("settings-copy-ai-names")
        let pane = elements(AIServicesPane(), model: model)
        let words = pane.flatMap(\.words)
        #expect(!words.contains("On device"), "\(words)")
        #expect(!words.contains("ADD A SERVICE"), "\(words)")
        let names = pane.compactMap(\.name)
        #expect(names.contains("Transcript menu prompts"), "\(names)")
        #expect(!names.contains("Prompts"), "\(names)")
        #expect(names.contains("Add Service"), "\(names)")
    }

    @Test("the models folder has one row, on Local Models, showing the folder in use, and Advanced no longer repeats it")
    func oneModelsFolderRow() {
        let model = makeModel("settings-copy-models-folder")
        let row = words(StorageRow(), model: model)
        #expect(row.contains("Models folder:"), "\(row)")
        #expect(row.contains(model.cacheDirectoryDisplayPath), "\(row)")
        #expect(row.contains("Reveal in Finder"), "\(row)")
        let advanced = words(AdvancedPane(), model: model)
        #expect(!advanced.contains("Model storage"), "\(advanced)")
        #expect(!advanced.contains(model.cacheDirectoryDisplayPath), "\(advanced)")
    }

    @Test("the Live Captions panel's title is translated")
    func liveCaptionsTitleIsTranslated() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(LiveCaptionsWindow.title(bundle: it) == "Sottotitoli in tempo reale")
        let panel = LiveCaptionsWindow.make { EmptyView() }
        #expect(panel.title == LiveCaptionsWindow.title())
    }
}
