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

    @Test("setting the mode writes the menu bar key the controller reads")
    func modeWritesMenuBarKey() {
        let defaults = temporaryDefaults()
        let model = makeModel("visibility-menubar", defaults: defaults)

        model.appVisibilityMode = .dockOnly

        #expect(model.showMenuBarExtra == false)
        #expect(defaults.bool(forKey: "showMenuBarExtra") == false)
        #expect(defaults.string(forKey: "appVisibilityMode") == "dockOnly")

        model.appVisibilityMode = .menuBarOnly

        #expect(model.showMenuBarExtra)
        #expect(defaults.bool(forKey: "showMenuBarExtra"))
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
