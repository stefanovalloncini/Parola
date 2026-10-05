import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Shortcut catalog")
struct ShortcutCatalogTests {
    @Test("catalog has at least four sections")
    func sectionCount() {
        #expect(ShortcutCatalog.sections(features: .all).count >= 4)
    }

    @Test("every section has at least one entry")
    func sectionsNonEmpty() {
        for section in ShortcutCatalog.sections(features: .all) {
            #expect(section.entries.isEmpty == false)
        }
    }

    @Test("section titles are unique")
    func uniqueSections() {
        let titles = ShortcutCatalog.sections(features: .all).map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test("the take's own keys are listed: Space on the Stage, ⌘B, ⌘↩, and Esc while it starts")
    func takeShortcuts() {
        let recording = ShortcutCatalog.sections(features: .all).first { $0.title == "Recording" }
        #expect(recording?.entries.map(\.label) == ["Pause or Resume Recording", "Add Marker", "Stop Recording", "Cancel a Starting Recording"])
        #expect(recording?.entries.map(\.keys) == ["Space", "⌘ B", "⌘ ↩", "Esc"])
    }

    @Test("a build that records nothing lists none of the take's keys; one that records meetings does")
    func takeShortcutsNeedRecording() {
        let batchOnly = ShortcutCatalog.sections(features: FeatureSet(enabled: [.batch])).map(\.title)
        #expect(!batchOnly.contains("Recording"))
        let meetingsOnly = ShortcutCatalog.sections(features: FeatureSet(enabled: [.meetings])).map(\.title)
        #expect(meetingsOnly.contains("Recording"))
    }

    @Test("the sheet reads in Italian, every title and label")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        let sections = ShortcutCatalog.sections(features: .all, bundle: it)
        #expect(sections.map(\.title) == [
            "Acquisizione", "Registrazione", "Trascrizione", "Trova", "Copia ed esporta", "Riproduzione", "Navigazione", "Aiuto",
        ])
        let italian = sections.flatMap(\.entries).map(\.label)
        let english = ShortcutCatalog.sections(features: .all).flatMap(\.entries).map(\.label)
        let untranslated = zip(english, italian).filter { $0.0 == $0.1 }.map(\.0)
        #expect(untranslated.isEmpty, "still English: \(untranslated)")
        let keys = sections.flatMap(\.entries).map(\.keys)
        #expect(keys.contains("Spazio"))
    }

    @Test("the Stage buttons' help names their keys, in Italian too")
    @MainActor
    func stageHelp() throws {
        #expect(StageControls.help(for: .pause) == "Pause Recording (Space)")
        #expect(StageControls.help(for: .resume) == "Resume Recording (Space)")
        #expect(StageControls.help(for: .mark) == "Add Marker (⌘B)")
        #expect(StageControls.help(for: .stop) == "Stop recording and transcribe (⌘↩)")
        #expect(StageControls.help(for: .cancel) == "Cancel the recording before it starts (Esc)")
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let it = try #require(Bundle(path: path))
        #expect(StageControls.help(for: .pause, bundle: it) == "Metti in pausa la registrazione (Spazio)")
        #expect(StageControls.help(for: .stop, bundle: it) == "Ferma la registrazione e trascrivi (⌘↩)")
        #expect(StageControls.help(for: .cancel, bundle: it) == "Annulla la registrazione prima che inizi (Esc)")
    }

    @Test("entry labels and keys are non-empty")
    func entriesValid() {
        for section in ShortcutCatalog.sections(features: .all) {
            for entry in section.entries {
                #expect(entry.label.isEmpty == false)
                #expect(entry.keys.isEmpty == false)
            }
        }
    }

    private static func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/ShortcutCatalogTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Every `keyboardShortcut("x", modifiers: …)` in a file, written the way the sheet writes keys: "⌘ ⌥ N".
    private static func shortcuts(in name: String) throws -> [String] {
        let text = try source(name)
        let pattern = #/[kK]eyboardShortcut\(\s*(?:"(?<char>[^"]+)"|\.(?<named>\w+))\s*(?:,\s*modifiers:\s*(?<mods>\[[^\]]*\]|\.\w+))?\s*\)/#
        let glyphs = ["return": "↩", "upArrow": "↑", "downArrow": "↓", "leftArrow": "←", "rightArrow": "→"]
        var found: [String] = []
        for match in text.matches(of: pattern) {
            let key: String
            if let char = match.output.char {
                key = char.uppercased()
            } else if let named = match.output.named, let glyph = glyphs[String(named)] {
                key = glyph
            } else {
                continue
            }
            let mods = match.output.mods.map(String.init) ?? ".command"
            var parts: [String] = []
            if mods.contains(".command") { parts.append("⌘") }
            if mods.contains(".control") { parts.append("⌃") }
            if mods.contains(".option") { parts.append("⌥") }
            if mods.contains(".shift") { parts.append("⇧") }
            found.append((parts + [key]).joined(separator: " "))
        }
        return found
    }

    private static let menuFiles = ["Views/AppCommands", "Views/MiniPlayerCommand", "Views/Chat/FocusChatComposerCommand"]

    @Test("no two menu commands share a key")
    func menuKeysAreUnique() throws {
        let keys = try Self.menuFiles.flatMap { try Self.shortcuts(in: $0) }
        let repeated = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(keys.count > 30)
        #expect(repeated.isEmpty, "shared: \(repeated)")
    }

    @Test("the Keyboard Shortcuts window lists every menu key and the Find bar's")
    func everyMenuKeyIsListed() throws {
        let listed = Set(ShortcutCatalog.sections(features: .all).flatMap(\.entries).map(\.keys))
        let keys = try (Self.menuFiles + ["Views/FindBar"]).flatMap { try Self.shortcuts(in: $0) }
        let missing = Set(keys).subtracting(listed).sorted()
        #expect(missing.isEmpty, "not listed: \(missing)")
    }

    @Test("⌘E is named for the preset on top of the Export As menu")
    func commandENamesTheTopPreset() throws {
        let srt = try #require(ExportPreset.builtIn(for: .srt))
        let entries = ShortcutCatalog.sections(features: .all, exportPreset: srt).flatMap(\.entries)
        let commandE = entries.filter { $0.keys == "⌘ E" }.map(\.label)
        #expect(commandE == ["Export as Subtitles (.srt)"])
        let none = ShortcutCatalog.sections(features: .all, exportPreset: nil).flatMap(\.entries)
        let listsCommandE = none.contains { $0.keys == "⌘ E" }
        #expect(!listsCommandE)
    }
}
