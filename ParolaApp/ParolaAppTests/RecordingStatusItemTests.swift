import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private func italianBundle() throws -> Bundle {
    let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
    return try #require(Bundle(path: path))
}

@MainActor
@Suite("Recording surface settings")
struct RecordingSurfaceSettingsTests {
    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("surface-settings"))
    }

    @Test("the menu bar item and the pill start on, and each switch is kept and read back")
    func togglesPersist() {
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        #expect(model.showRecordingStatusItem)
        #expect(model.showRecordingPill)

        model.showRecordingStatusItem = false
        model.showRecordingPill = false
        #expect(defaults.object(forKey: "showRecordingStatusItem") as? Bool == false)
        #expect(defaults.object(forKey: "showRecordingPill") as? Bool == false)

        defaults.set(true, forKey: "showRecordingPill")
        model.reloadSettings()
        #expect(model.showRecordingStatusItem == false)
        #expect(model.showRecordingPill)
    }

    @Test("the Microphone pane's reset turns both back on, and the bridge may set them")
    func resetAndBridge() {
        for key in ["showRecordingStatusItem", "showRecordingPill"] {
            #expect(SettingsPaneScope.microphone.defaultsKeys.contains(key))
            #expect(ParolaAutomationServer.writableSettingKeys.contains(key))
        }
        let defaults = temporaryDefaults()
        let model = makeModel(defaults)
        model.showRecordingStatusItem = false
        model.showRecordingPill = false

        for key in SettingsPaneScope.microphone.defaultsKeys { defaults.removeObject(forKey: key) }
        model.reloadSettings()

        #expect(model.showRecordingStatusItem)
        #expect(model.showRecordingPill)
    }

    @Test("Settings search finds them from the menu bar or the pill")
    func search() {
        #expect(SettingsSidebarCatalog.matches(route: .microphone, query: "pill"))
        #expect(SettingsSidebarCatalog.matches(route: .microphone, query: "menu bar"))
    }

    @Test("the rows read in Italian")
    func italian() throws {
        let it = try italianBundle()
        #expect(String(localized: "Recording controls", bundle: it) == "Controlli di registrazione")
        #expect(String(localized: "Show the recording in the menu bar", bundle: it) == "Mostra la registrazione nella barra dei menu")
        #expect(
            String(localized: "The time stays in the menu bar while you record, with the recording's controls in its menu.", bundle: it)
                == "Il tempo resta nella barra dei menu mentre registri, con i controlli della registrazione nel suo menu."
        )
        #expect(
            String(localized: "Show a floating recording pill when Parola is in the background", bundle: it)
                == "Mostra una pillola di registrazione fluttuante quando Parola è in background"
        )
        #expect(
            String(localized: "The time and a Stop button float over other apps. Drag the pill wherever you like.", bundle: it)
                == "Il tempo e il pulsante Ferma restano sopra le altre app. Trascina la pillola dove preferisci."
        )
    }
}
