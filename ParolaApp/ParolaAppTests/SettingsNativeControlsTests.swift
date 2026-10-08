import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

/// Settings draws the system's controls, so a pane has one button style and its lists read like System Settings.
@MainActor
@Suite("Settings native controls", .serialized)
struct SettingsNativeControlsTests {
    /// The app's own drawn buttons; a Settings pane uses none of them.
    nonisolated static let appButtonStyles = ["DSPillButtonStyle", "DSIconChipButtonStyle", "GlyphButtonStyle"]

    nonisolated static let localModelsFiles = [
        "Views/ModelsSettingsPane",
        "Views/ModelCardRow",
        "Views/Settings/Models/DownloadedRow",
        "Views/Settings/Models/EarlierDownloadRow",
        "Views/Settings/Models/OrphansRow",
        "Views/Settings/Models/RecommendedRow",
        "Views/Settings/Models/StorageRow",
        "Views/Settings/Models/UsageRow",
    ]

    /// Every file Settings draws from: the panes, their rows and editors, and the Local Models files outside the folder.
    nonisolated static var settingsFiles: [String] {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ParolaApp")
        let folder = app.appendingPathComponent("Views/Settings")
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { "Views/Settings/" + $0.path.dropFirst(folder.path.count + 1).dropLast(".swift".count) } ?? []
        return (found + ["Views/SettingsView"] + localModelsFiles).sorted()
    }

    private static func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/SettingsNativeControlsTests.swift", with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("Local Models' rows and storage line draw the system's buttons", arguments: localModelsFiles)
    func localModelsButtonsAreNative(_ file: String) throws {
        let text = try Self.source(file)
        let drawn = Self.appButtonStyles.filter { text.contains($0) }
        #expect(drawn.isEmpty, "\(file) still draws \(drawn)")
    }

    @Test("every Settings pane draws the system's buttons, toggles and pickers, so a pane has one button style",
          arguments: settingsFiles)
    func settingsControlsAreNative(_ file: String) throws {
        let text = try Self.source(file)
        let drawn = Self.appButtonStyles.filter { text.contains($0) }
        #expect(drawn.isEmpty, "\(file) still draws \(drawn)")
        let chips = text.ranges(of: /\bChip\(/).count
        #expect(chips == 0, "\(file) still draws \(chips) app chips")
    }

    @Test("Local Models: search, the filter and sort sit on one line right above the first list, not in a box of their own")
    func localModelsControlsHeadTheList() async throws {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("local-models-controls"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
        let hosted = HostedWindow(ModelsSettingsPane().environment(model), width: 760, height: 2400)
        defer { hosted.close() }
        await model.awaitModelListRefresh()
        hosted.host.layoutSubtreeIfNeeded()
        let found = HostedAccessibility.elements(in: hosted.host)
        func leaf(_ suffix: String) -> HostedAccessibility.Element? {
            found.first { $0.identifier?.hasSuffix(suffix) == true }
        }
        let search = try #require(leaf("Models.TextField.Search"))
        let filter = try #require(leaf("Models.Picker.Filter"), "the filter isn't a native picker")
        let sort = try #require(leaf("ModelsSettings.Menu.Sort"))
        let titles = [String(localized: "On This Mac"), String(localized: "Recommended models")]
        let headings = found.filter { element in element.words.contains { titles.contains($0) } }
        let first = try #require(headings.max { $0.frame.maxY < $1.frame.maxY }, "no list heading")
        #expect(abs(search.frame.midY - filter.frame.midY) < 8, "the filter sits on its own line")
        #expect(abs(search.frame.midY - sort.frame.midY) < 8, "sort sits on its own line")
        #expect(search.frame.minY > first.frame.maxY, "the controls aren't above the first list")
        #expect(search.frame.minY - first.frame.maxY < 24, "the controls sit \(search.frame.minY - first.frame.maxY) pt above the first list")
    }

    @Test("Transcription Defaults' model and language are native pop-ups, named by their rows, showing the current pick")
    func transcriptionDefaultsPopUps() async throws {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("defaults-popups"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
        await model.awaitModelListRefresh()
        model.selectedLanguage = "it"
        let hosted = HostedWindow(TranscriptionDefaultsPane().environment(model), width: 760, height: 1400)
        defer { hosted.close() }
        let found = HostedAccessibility.elements(in: hosted.host)
        let popUp = NSAccessibility.Role.popUpButton.rawValue
        let modelPicker = try #require(found.first { $0.identifier?.hasSuffix("TranscriptionDefaults.Picker.Model") == true })
        let languagePicker = try #require(found.first { $0.identifier?.hasSuffix("TranscriptionDefaults.Picker.Language") == true })
        #expect(modelPicker.role == popUp, "the model picker reads as \(modelPicker.role ?? "nothing")")
        #expect(languagePicker.role == popUp, "the language picker reads as \(languagePicker.role ?? "nothing")")
        #expect(modelPicker.name == String(localized: "Default model"))
        #expect(languagePicker.name == String(localized: "Default language"))
        let current = ModelCatalog.variant(id: model.selectedModel)?.displayName ?? model.selectedModel
        #expect(modelPicker.value == current)
        #expect(languagePicker.value == SupportedLanguages.displayName(for: "it"))
    }
}
