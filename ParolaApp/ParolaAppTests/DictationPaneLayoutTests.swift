import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Dictation pane layout", .serialized)
struct DictationPaneLayoutTests {
    private static let controlRoles: Set<String> = [
        NSAccessibility.Role.checkBox.rawValue,
        NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.menuButton.rawValue,
        NSAccessibility.Role.slider.rawValue,
    ]

    private func makeModel(enabled: Bool) -> AppModel {
        let defaults = temporaryDefaults()
        defaults.set(enabled, forKey: "dictationEnabled")
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("dictation-pane"))
        model.dictationPerAppOverridesJSON = "{}"
        return model
    }

    private func host(_ model: AppModel) -> HostedWindow {
        HostedWindow(ScrollView { DictationPane().padding() }.environment(model), width: 900, height: 2400)
    }

    @Test("the on/off switch sits above the preview and every other control")
    func switchComesFirst() throws {
        let model = makeModel(enabled: false)
        let hosted = host(model)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let toggle = try #require(elements.first { $0.identifier?.hasSuffix("Dictation.Toggle.Enabled") == true })
        let preview = try #require(elements.first { $0.words.contains(String(localized: "Preview")) })
        #expect(toggle.frame.minY > preview.frame.maxY, "the preview sits above the switch")
        let others = elements.filter {
            guard let id = $0.identifier, id.contains("Dictation.") else { return false }
            return !id.hasSuffix("Dictation.Toggle.Enabled")
        }
        #expect(others.isEmpty == false)
        for other in others {
            #expect(toggle.frame.minY > other.frame.maxY, "\(other.identifier ?? "") sits above the switch")
        }
    }

    @Test("while dictation is off, only its switch takes a click")
    func offDimsTheRest() throws {
        let model = makeModel(enabled: false)
        let hosted = host(model)
        defer { hosted.close() }
        let controls = HostedAccessibility.elements(in: hosted.host).filter { Self.controlRoles.contains($0.role ?? "") }
        let toggle = try #require(controls.first { $0.identifier?.hasSuffix("Dictation.Toggle.Enabled") == true })
        #expect(toggle.isEnabled)
        let rest = controls.filter { $0.identifier?.hasSuffix("Dictation.Toggle.Enabled") != true }
        #expect(rest.count > 5)
        for control in rest {
            #expect(control.isEnabled == false, "\(control.identifier ?? control.role ?? "") stays live while dictation is off")
        }
    }

    @Test("while dictation is on, its settings take a click")
    func onKeepsTheRestLive() throws {
        let model = makeModel(enabled: true)
        let hosted = host(model)
        defer { hosted.close() }
        let controls = HostedAccessibility.elements(in: hosted.host).filter { Self.controlRoles.contains($0.role ?? "") }
        let mode = try #require(controls.first { $0.identifier?.hasSuffix("Dictation.Picker.Mode") == true })
        #expect(mode.isEnabled)
    }

    @Test("Change… beside the model opens Transcription Defaults")
    func changeModelOpensTranscriptionDefaults() {
        let model = makeModel(enabled: true)
        model.settingsPane = SettingsRoute.dictation.rawValue
        let hosted = host(model)
        defer { hosted.close() }
        #expect(HostedAccessibility.press(endingWith: "Dictation.Button.ChangeModel", in: hosted.host))
        #expect(model.settingsPane == SettingsRoute.transcriptionDefaults.rawValue)
    }

    @Test("the pane doesn't repeat the Accessibility row in a helper")
    func noAccessibilityHelper() {
        let model = makeModel(enabled: false)
        let hosted = host(model)
        defer { hosted.close() }
        let words = HostedAccessibility.words(in: hosted.host)
        #expect(!words.contains { $0.hasPrefix("Dictation needs Accessibility") })
    }

    @Test("Permissions show only while one is missing")
    func permissionsOnlyWhenMissing() {
        let granted = DictationPermissions(trustCheck: { true }, microphoneStatus: { .authorized })
        let allSet = HostedWindow(DictationPermissionsSection(permissions: granted), width: 700, height: 300)
        defer { allSet.close() }
        #expect(HostedAccessibility.words(in: allSet.host).contains(String(localized: "Accessibility")) == false)

        let missing = DictationPermissions(trustCheck: { false }, microphoneStatus: { .authorized })
        let shown = HostedWindow(DictationPermissionsSection(permissions: missing), width: 700, height: 300)
        defer { shown.close() }
        let ids = HostedAccessibility.elements(in: shown.host).compactMap(\.identifier)
        #expect(ids.contains { $0.hasSuffix("Dictation.Button.GrantAccessibility") })
    }
}
