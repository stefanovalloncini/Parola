import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Watched folder options")
struct WatchedFolderOptionsTests {

    private static let folderBeforeOptions = """
    {"id":"6F1B1D3E-4C7A-4E58-9C41-0A5B1F0E2D11","bookmark":"AAEC","displayPath":"/Users/me/Inbox"}
    """

    private var srt: ExportPreset { ExportPreset.builtIn(for: .srt)! }
    private var txt: ExportPreset { ExportPreset.builtIn(for: .txt)! }

    private func italian() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("a folder saved before options existed decodes with every default")
    func oldJSONDecodesToDefaults() throws {
        let folder = try JSONDecoder().decode(WatchedFolder.self, from: Data(Self.folderBeforeOptions.utf8))
        #expect(folder.options == .default)
        #expect(folder.options.autoTranscribes)
        #expect(folder.options.includesSubfolders)
        #expect(folder.options.savesToLibrary)
        #expect(folder.options.exportPresetIDs.isEmpty)
        #expect(!folder.options.exportsToAutoExportFolder)
        #expect(folder.displayName == "Inbox")
    }

    @Test("options survive an encode and decode")
    func optionsRoundTrip() throws {
        var options = WatchedFolderOptions()
        options.autoTranscribes = false
        options.includesSubfolders = false
        options.savesToLibrary = false
        options.exportPresetIDs = [srt.id, txt.id]
        options.exportsToAutoExportFolder = true
        let folder = WatchedFolder(bookmark: Data([1, 2]), displayPath: "/tmp/In", options: options)
        let decoded = try JSONDecoder().decode(WatchedFolder.self, from: JSONEncoder().encode(folder))
        #expect(decoded == folder)
    }

    @Test("a partial options object fills in the rest")
    func partialOptionsDecode() throws {
        let options = try JSONDecoder().decode(WatchedFolderOptions.self, from: Data(#"{"autoTranscribes":false}"#.utf8))
        #expect(!options.autoTranscribes)
        #expect(options.includesSubfolders)
        #expect(options.savesToLibrary)
    }

    @Test("with no export formats the library save is on and the export folder is off")
    func normalizedWithoutFormats() {
        var options = WatchedFolderOptions()
        options.savesToLibrary = false
        options.exportsToAutoExportFolder = true
        #expect(options.normalized.savesToLibrary)
        #expect(!options.normalized.exportsToAutoExportFolder)
        #expect(options.keepsTranscriptInLibrary)

        options.exportPresetIDs = [srt.id]
        #expect(options.normalized == options)
        #expect(!options.keepsTranscriptInLibrary)
    }

    @Test("the editor's switches follow the formats")
    func editorStates() {
        var options = WatchedFolderOptions()
        #expect(!options.libraryToggleIsEnabled)
        #expect(!options.offersAutoExportFolder(chosen: true))
        options.exportPresetIDs = [txt.id]
        #expect(options.libraryToggleIsEnabled)
        #expect(options.offersAutoExportFolder(chosen: true))
        #expect(!options.offersAutoExportFolder(chosen: false))
    }

    @Test("nothing is said while every option is a default")
    func noSummaryForDefaults() {
        #expect(WatchedFolderOptions().summary(presets: ExportPreset.builtIns) == nil)
    }

    @Test("the summary names only what differs, in a fixed order")
    func summaryLine() {
        var options = WatchedFolderOptions()
        options.includesSubfolders = false
        options.exportPresetIDs = [txt.id, srt.id]
        options.savesToLibrary = false
        #expect(
            options.summary(presets: ExportPreset.builtIns)
                == "Only this folder · Exports TXT, SRT · Not saved to Library"
        )
        options.autoTranscribes = false
        options.exportsToAutoExportFolder = true
        #expect(
            options.summary(presets: ExportPreset.builtIns)
                == "Waits in Batch · Only this folder · Exports TXT, SRT to the Auto-Export folder · Not saved to Library"
        )
    }

    @Test("two presets of one format list the format once")
    func summaryDeduplicatesFormats() {
        var options = WatchedFolderOptions()
        let short = ExportPreset(name: "Short SRT", spec: srt.spec)
        options.exportPresetIDs = [srt.id, short.id]
        #expect(options.summary(presets: ExportPreset.builtIns + [short]) == "Exports SRT")
    }

    @Test("the summary and the toasts read in Italian")
    func italianCopy() throws {
        let bundle = try italian()
        var options = WatchedFolderOptions()
        options.autoTranscribes = false
        options.includesSubfolders = false
        options.exportPresetIDs = [txt.id]
        options.savesToLibrary = false
        #expect(
            options.summary(presets: ExportPreset.builtIns, bundle: bundle)
                == "Resta in Batch · Solo questa cartella · Esporta TXT · Non salvato nella libreria"
        )
        let file = URL(fileURLWithPath: "/tmp/Standup.wav")
        #expect(ArrivalNotice(queued: file).title(bundle: bundle) == "Standup aggiunto a Batch")
        #expect(ArrivalNotice(queued: file, count: 3).title(bundle: bundle) == "3 file aggiunti a Batch")
        #expect(ArrivalNotice(exported: file).title(bundle: bundle) == "Standup trascritto ed esportato")
    }

    @Test("every sheet and pane string has an Italian line")
    func italianStrings() throws {
        let bundle = try italian()
        let keys = [
            "Options…", "New Files", "Auto-Transcribe", "Off: new files wait in Batch until you start them.",
            "Folder Depth", "This Folder Only", "Include Subfolders", "Save to Library",
            "Off: the transcript is only exported.", "Choose an export format first.", "Export Formats", "Export To",
            "Next to the File", "Auto-Export Folder", "Choose an Auto-Export folder in Auto-Export settings.",
            "Open Batch",
        ]
        for key in keys {
            let localized = bundle.localizedString(forKey: key, value: "\u{0}missing", table: nil)
            #expect(localized != "\u{0}missing" && localized != key, "\(key)")
        }
    }
}
