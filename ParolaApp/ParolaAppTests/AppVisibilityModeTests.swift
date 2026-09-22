import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("App visibility mode", .serialized)
struct AppVisibilityModeTests {

    @MainActor
    private final class AppliedPolicies {
        var policies: [NSApplication.ActivationPolicy] = []
    }

    private func makeModel(_ label: String, defaults: UserDefaults = temporaryDefaults()) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL(label))
    }

    @Test("each mode maps to one activation policy and one menu bar answer")
    func mappingIsExhaustive() {
        #expect(AppVisibilityMode.dockAndMenuBar.activationPolicy == .regular)
        #expect(AppVisibilityMode.dockAndMenuBar.showsMenuBarExtra)

        #expect(AppVisibilityMode.menuBarOnly.activationPolicy == .accessory)
        #expect(AppVisibilityMode.menuBarOnly.showsMenuBarExtra)

        #expect(AppVisibilityMode.dockOnly.activationPolicy == .regular)
        #expect(AppVisibilityMode.dockOnly.showsMenuBarExtra == false)

        for mode in AppVisibilityMode.allCases {
            #expect(mode.id == mode.rawValue)
            #expect(mode.label.isEmpty == false)
        }
    }

    @Test("the default mode shows both")
    func defaultMode() {
        let model = makeModel("visibility-default")

        #expect(model.appVisibilityMode == .dockAndMenuBar)
        #expect(model.showMenuBarExtra)
    }

    @Test("setting the mode drives the menu bar flag the controller reads")
    func modeDrivesTheMenuBarFlag() {
        let defaults = temporaryDefaults()
        let model = makeModel("visibility-menubar", defaults: defaults)

        model.appVisibilityMode = .dockOnly

        #expect(model.showMenuBarExtra == false)
        #expect(defaults.string(forKey: "appVisibilityMode") == "dockOnly")

        model.appVisibilityMode = .menuBarOnly

        #expect(model.showMenuBarExtra)
        // The mode is the stored answer; the flag is derived and never written back.
        #expect(defaults.object(forKey: "showMenuBarExtra") == nil)
    }

    @Test("the old toggle is spent once it has been read, so a reset can restore the default")
    func migrationRunsOnceAndAResetRestoresTheDefault() {
        let defaults = temporaryDefaults()
        defaults.set(false, forKey: "showMenuBarExtra")

        let model = makeModel("visibility-reset", defaults: defaults)
        #expect(model.appVisibilityMode == .dockOnly)
        #expect(defaults.object(forKey: "showMenuBarExtra") == nil)

        defaults.removeObject(forKey: "appVisibilityMode")
        model.reloadSettings()

        #expect(model.appVisibilityMode == .dockAndMenuBar)
        #expect(model.showMenuBarExtra)
    }

    @Test("every change hands the activation policy to the applier")
    func modeAppliesTheActivationPolicy() {
        let model = makeModel("visibility-policy")
        let applied = AppliedPolicies()
        model.activationPolicyApplier = { applied.policies.append($0) }

        model.appVisibilityMode = .menuBarOnly
        model.appVisibilityMode = .dockOnly

        #expect(applied.policies == [.accessory, .regular])
    }

    @Test("the mode is read at bootstrap and again on reload")
    func modeLoadsAtBootstrapAndOnReload() {
        let defaults = temporaryDefaults()
        defaults.set("menuBarOnly", forKey: "appVisibilityMode")

        let model = makeModel("visibility-bootstrap", defaults: defaults)
        #expect(model.appVisibilityMode == .menuBarOnly)
        #expect(model.showMenuBarExtra)

        defaults.set("dockOnly", forKey: "appVisibilityMode")
        model.reloadSettings()

        #expect(model.appVisibilityMode == .dockOnly)
        #expect(model.showMenuBarExtra == false)
    }

    @Test("an install that only ever answered the old toggle keeps its answer")
    func migratesFromTheOldMenuBarToggle() {
        let hidden = temporaryDefaults()
        hidden.set(false, forKey: "showMenuBarExtra")
        let hiddenModel = makeModel("visibility-migrate-off", defaults: hidden)
        #expect(hiddenModel.appVisibilityMode == .dockOnly)
        #expect(hiddenModel.showMenuBarExtra == false)
        #expect(hidden.string(forKey: "appVisibilityMode") == "dockOnly")
        #expect(hidden.object(forKey: "showMenuBarExtra") == nil)

        let shown = temporaryDefaults()
        shown.set(true, forKey: "showMenuBarExtra")
        let shownModel = makeModel("visibility-migrate-on", defaults: shown)
        #expect(shownModel.appVisibilityMode == .dockAndMenuBar)
        #expect(shownModel.showMenuBarExtra)
    }

    @Test("a fresh install shows both, because neither key was ever answered")
    func freshInstallShowsBoth() {
        let defaults = temporaryDefaults()
        #expect(defaults.object(forKey: "showMenuBarExtra") == nil)

        let model = makeModel("visibility-fresh", defaults: defaults)

        #expect(model.appVisibilityMode == .dockAndMenuBar)
        #expect(model.showMenuBarExtra)
    }

    @Test("the stored mode always wins over the old toggle")
    func storedModeWinsOverTheOldToggle() {
        let defaults = temporaryDefaults()
        defaults.set(true, forKey: "showMenuBarExtra")
        defaults.set("dockOnly", forKey: "appVisibilityMode")

        let model = makeModel("visibility-stored-wins", defaults: defaults)

        #expect(model.appVisibilityMode == .dockOnly)
        #expect(model.showMenuBarExtra == false)
    }

    @Test("a headless launch grows neither a Dock icon nor a menu bar item")
    func headlessKeepsBothOff() {
        let model = makeModel("visibility-headless")
        let applied = AppliedPolicies()
        model.activationPolicyApplier = { applied.policies.append($0) }
        model.isHeadless = true

        model.appVisibilityMode = .menuBarOnly

        #expect(model.showMenuBarExtra == false)
        #expect(applied.policies.isEmpty)

        model.appVisibilityMode = .dockAndMenuBar

        #expect(model.showMenuBarExtra == false)
        #expect(applied.policies.isEmpty)
    }

    @Test("a stored mode this build doesn't know falls back to showing both")
    func unknownStoredModeFallsBack() {
        let defaults = temporaryDefaults()
        defaults.set("holographic", forKey: "appVisibilityMode")

        let model = makeModel("visibility-unknown", defaults: defaults)

        #expect(model.appVisibilityMode == .dockAndMenuBar)
        #expect(model.showMenuBarExtra)
    }

    @Test("the picker writes the key the bridge and the General pane share")
    func modePersistsUnderTheSharedKey() {
        let defaults = temporaryDefaults()
        let model = makeModel("visibility-key", defaults: defaults)

        model.appVisibilityMode = .menuBarOnly

        #expect(defaults.string(forKey: "appVisibilityMode") == "menuBarOnly")
        #expect(ParolaAutomationServer.writableSettingKeys.contains("appVisibilityMode"))
        #expect(SettingsPaneScope.general.defaultsKeys.contains("appVisibilityMode"))
    }
}
