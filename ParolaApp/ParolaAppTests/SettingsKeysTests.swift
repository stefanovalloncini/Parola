import Foundation
import Testing
@testable import Parola

@Suite("Settings pane scope")
struct SettingsPaneScopeTests {

    @Test("every scope has a non-empty label and a stable id")
    func labelsAndIds() {
        for scope in SettingsPaneScope.allCases {
            #expect(scope.label.isEmpty == false)
            #expect(scope.id == scope.rawValue)
        }
    }

    @Test("labels map to their display strings")
    func labelMapping() {
        #expect(SettingsPaneScope.general.label == "General")
        #expect(SettingsPaneScope.findReplace.label == "Find & Replace")
        #expect(SettingsPaneScope.automation.label == "MCP & Automation")
        #expect(SettingsPaneScope.autoExport.label == "Auto-Export")
    }

    @Test("the customization pane resets the theme and accent keys")
    func customizationDefaultsKeys() {
        let keys = SettingsPaneScope.customization.defaultsKeys
        #expect(keys.contains("appTheme"))
        #expect(keys.contains("appAccentColor"))
        #expect(keys.contains("sidebarDensity"))
    }

    @Test("the dictation pane resets the full hotkey and override key set")
    func dictationDefaultsKeys() {
        let keys = SettingsPaneScope.dictation.defaultsKeys
        #expect(keys.contains("dictationEnabled"))
        #expect(keys.contains("dictationKeyCode"))
        #expect(keys.contains("dictationPerAppOverridesJSON"))
    }

    @Test("panes with no persisted state expose no reset keys")
    func panesWithoutDefaults() {
        #expect(SettingsPaneScope.exportFormats.defaultsKeys.isEmpty)
        #expect(SettingsPaneScope.integrations.defaultsKeys.isEmpty)
        #expect(SettingsPaneScope.prompts.defaultsKeys.isEmpty)
        #expect(SettingsPaneScope.advanced.defaultsKeys.isEmpty)
    }

    @Test("a pane with persisted state always offers search keywords")
    func searchKeywordsPresent() {
        for scope in SettingsPaneScope.allCases where scope.defaultsKeys.isEmpty == false {
            #expect(scope.searchKeywords.isEmpty == false)
        }
    }

    @Test("no defaults key is claimed by more than one pane")
    func defaultsKeysAreDisjoint() {
        var seen: Set<String> = []
        for scope in SettingsPaneScope.allCases {
            for key in scope.defaultsKeys {
                #expect(seen.contains(key) == false, "key \(key) appears in two panes")
                seen.insert(key)
            }
        }
    }
}

@MainActor
@Suite("Settings reset service", .serialized)
struct SettingsResetServiceTests {

    private let scope = SettingsPaneScope.customization

    private func clearScopeKeys() {
        let defaults = UserDefaults.standard
        for key in scope.defaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }

    @Test("reset removes every defaults key for the scope")
    func resetRemovesScopeKeys() {
        let defaults = UserDefaults.standard
        clearScopeKeys()
        defer { clearScopeKeys() }

        for key in scope.defaultsKeys {
            defaults.set("sentinel", forKey: key)
        }
        for key in scope.defaultsKeys {
            #expect(defaults.object(forKey: key) != nil)
        }

        SettingsResetService.reset(scope: scope)

        for key in scope.defaultsKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test("reset leaves another pane's keys untouched")
    func resetIsScoped() {
        let defaults = UserDefaults.standard
        let otherKey = "test-reset-isolation-\(UUID().uuidString)"
        clearScopeKeys()
        defer {
            clearScopeKeys()
            defaults.removeObject(forKey: otherKey)
        }

        defaults.set("keep", forKey: otherKey)
        for key in scope.defaultsKeys {
            defaults.set("clear", forKey: key)
        }

        SettingsResetService.reset(scope: scope)

        #expect(defaults.string(forKey: otherKey) == "keep")
    }

    @Test("reset posts a notification carrying the scope")
    func resetPostsNotification() async {
        clearScopeKeys()
        defer { clearScopeKeys() }

        await confirmation("scope notification fires") { confirmed in
            let token = NotificationCenter.default.addObserver(
                forName: .parolaSettingsReset,
                object: nil,
                queue: nil
            ) { note in
                if note.object as? SettingsPaneScope == scope {
                    confirmed()
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            SettingsResetService.reset(scope: scope)
        }
    }
}
