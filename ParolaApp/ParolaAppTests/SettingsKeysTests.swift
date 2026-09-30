import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

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
        #expect(keys.contains("themeIsCustom"))
        #expect(keys.contains("themeCustomPaletteJSON"))
    }

    @Test("the dictation pane resets the full hotkey and override key set")
    func dictationDefaultsKeys() {
        let keys = SettingsPaneScope.dictation.defaultsKeys
        #expect(keys.contains("dictationEnabled"))
        #expect(keys.contains("dictationKeyCode"))
        #expect(keys.contains("dictationPerAppOverridesJSON"))
        #expect(keys.contains("dictationHudOpacity"))
        #expect(keys.contains("dictationStripSelfCorrections"))
        #expect(keys.contains("dictationPasteDelayMs"))
        #expect(keys.contains("dictationContextSelection"))
        #expect(keys.contains("dictationContextClipboard"))
        #expect(keys.contains("dictationContextScreen"))
    }

    @Test("the shortcuts pane resets the mic hotkey keys")
    func shortcutsDefaultsKeys() {
        let keys = SettingsPaneScope.shortcuts.defaultsKeys
        #expect(keys.contains("micHotkeyEnabled"))
        #expect(keys.contains("micHotkeyKeyCode"))
        #expect(keys.contains("micHotkeyModifiers"))
    }

    @Test("every user-facing settings key belongs to a pane scope")
    func userFacingKeysAreScoped() {
        let scoped = Set(SettingsPaneScope.allCases.flatMap(\.defaultsKeys))
        let expected = [
            "appVisibilityMode", "duplicateImportPolicy", "playSoundWhenFinished",
            "generateCardMetadata", "showAITitles", "showAISummaries",
            "customTitlePrompt", "customSummaryPrompt",
            "themeIsCustom", "themeCustomPaletteJSON",
            "recordingMaxMinutes", "recordingCountInSeconds",
            "autoMuteWhileRecording", "autoPauseMediaWhileRecording",
            "dictationHudOpacity", "dictationStripSelfCorrections", "dictationPasteDelayMs",
            "dictationContextSelection", "dictationContextClipboard", "dictationContextScreen",
            "micHotkeyEnabled", "micHotkeyKeyCode", "micHotkeyModifiers",
            "subtitleCaptionLength", "markdownTimestamps", "htmlExportTheme", "txtExportTimestamps",
            "pausePlayerOnAppHidden", "parola.userPrivacyMode", "batchExportFormatOptions",
        ]
        for key in expected {
            #expect(scoped.contains(key), "\(key) is missing from every pane scope")
        }
    }

    @Test("the summary options belong to no pane, and still export")
    func summaryKeysAreUnscoped() {
        let scoped = Set(SettingsPaneScope.allCases.flatMap(\.defaultsKeys))
        for key in ["summaryOptions", "autostartSummary"] {
            #expect(scoped.contains(key) == false, "\(key) is not shown by any pane, so no pane's reset may clear it")
            #expect(UnscopedSettingsKeys.all.contains(key), "\(key) must still be backed up and reset with the whole app")
        }
    }

    @Test("the export presets pane resets its own library")
    func exportFormatsResetsThePresets() {
        #expect(SettingsPaneScope.exportFormats.defaultsKeys == ["exportPresets"])
    }

    @Test("the models storage path stays out of every scope")
    func modelsPathStaysExcluded() {
        let scoped = Set(SettingsPaneScope.allCases.flatMap(\.defaultsKeys))
        #expect(scoped.contains("parola.modelsStoragePath") == false)
    }

    @Test("a key nothing but the app derives stays out of every scope")
    func derivedKeysStayExcluded() {
        // showMenuBarExtra follows appVisibilityMode; exporting or resetting it on its own would
        // hand back a value the next launch overwrites.
        let scoped = Set(SettingsPaneScope.allCases.flatMap(\.defaultsKeys))
        #expect(scoped.contains("showMenuBarExtra") == false)
    }

    @Test("panes with no persisted state expose no reset keys")
    func panesWithoutDefaults() {
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

    @Test("no defaults key is claimed by more than one pane, except controls shown on two panes")
    func defaultsKeysAreDisjoint() {
        // Each of these is rendered on two panes, and each pane's reset must cover
        // what it shows: the dictation hotkey (Shortcuts + Dictation) and the word
        // timestamps / diarize toggles (General + Transcription Defaults).
        let sharedKeys: Set<String> = [
            "dictationKeyCode", "dictationKeyModifiers", "wordTimestamps", "diarize",
        ]
        var seen: Set<String> = []
        for scope in SettingsPaneScope.allCases {
            for key in scope.defaultsKeys where !sharedKeys.contains(key) {
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

    @Test("reset-all clears every scoped key")
    func resetAllClearsEveryScopedKey() {
        let defaults = UserDefaults.standard
        let keys = SettingsPaneScope.allCases.flatMap(\.defaultsKeys)
        defer { for key in keys { defaults.removeObject(forKey: key) } }

        for key in keys {
            defaults.set("sentinel", forKey: key)
        }

        SettingsResetService.resetAll()

        for key in keys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived reset-all")
        }
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

@MainActor
@Suite("Settings export/import", .serialized)
struct SettingsExportServiceTests {

    private func makeSuite() -> (UserDefaults, String) {
        let name = temporarySuiteName("parola.test.export.")
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("export → .parola-settings JSON → import round-trips every value type")
    func roundTripsAllTypes() throws {
        let (src, srcName) = makeSuite()
        let (dst, dstName) = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: srcName)
            UserDefaults.standard.removePersistentDomain(forName: dstName)
        }

        let blob = Data([0x01, 0x02, 0xFF, 0x00, 0x7E])
        src.set(true, forKey: "useStreaming")
        src.set(49, forKey: "dictationKeyCode")
        src.set("graphite", forKey: "appTheme")
        src.set(blob, forKey: "snippets")

        let payload = SettingsExportService.exportPayload(defaults: src)
        let fileData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let reparsed = try #require(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])

        SettingsExportService.apply(reparsed, defaults: dst)

        #expect(dst.bool(forKey: "useStreaming") == true)
        #expect(dst.integer(forKey: "dictationKeyCode") == 49)
        #expect(dst.string(forKey: "appTheme") == "graphite")
        #expect(dst.data(forKey: "snippets") == blob)
    }

    @Test("every scoped key survives export → wipe → import")
    func allScopedKeysRoundTrip() throws {
        let (src, srcName) = makeSuite()
        let (dst, dstName) = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: srcName)
            UserDefaults.standard.removePersistentDomain(forName: dstName)
        }

        let keys = Set(SettingsPaneScope.allCases.flatMap(\.defaultsKeys))
        for key in keys {
            src.set("sentinel-\(key)", forKey: key)
        }

        let payload = SettingsExportService.exportPayload(defaults: src)
        let fileData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let reparsed = try #require(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])

        SettingsExportService.apply(reparsed, defaults: dst)

        for key in keys {
            #expect(dst.string(forKey: key) == "sentinel-\(key)", "\(key) lost in the round-trip")
        }
    }

    @Test("import is additive — keys absent from the file keep their current value")
    func importIsAdditive() {
        let (src, srcName) = makeSuite()
        let (dst, dstName) = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: srcName)
            UserDefaults.standard.removePersistentDomain(forName: dstName)
        }

        src.set("graphite", forKey: "appTheme")
        dst.set(true, forKey: "wordTimestamps")

        SettingsExportService.apply(SettingsExportService.exportPayload(defaults: src), defaults: dst)

        #expect(dst.string(forKey: "appTheme") == "graphite")
        #expect(dst.bool(forKey: "wordTimestamps") == true)
    }

    @Test("import ignores keys outside the settings allow-list")
    func importEnforcesAllowList() {
        let (dst, dstName) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: dstName) }

        SettingsExportService.apply(["notASetting": "evil", "appTheme": "graphite"], defaults: dst)

        #expect(dst.object(forKey: "notASetting") == nil)
        #expect(dst.string(forKey: "appTheme") == "graphite")
    }

    @Test("export skips keys with no stored value")
    func exportSkipsUnsetKeys() {
        let (src, srcName) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: srcName) }

        src.set("graphite", forKey: "appTheme")
        let payload = SettingsExportService.exportPayload(defaults: src)

        #expect(payload["appTheme"] as? String == "graphite")
        #expect(payload["useStreaming"] == nil)
    }
}
