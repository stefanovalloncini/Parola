import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Watched folders across a settings reload", .serialized)
struct WatchedFolderReloadTests {

    private struct Rig {
        let model: AppModel
        let defaults: UserDefaults
        let root: URL
        let folder: WatchedFolder
        let previous: UserDefaults
    }

    private func makeFolder(_ root: URL, _ name: String, formats: [UUID]) throws -> WatchedFolder {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var options = WatchedFolderOptions()
        options.exportPresetIDs = formats
        options.savesToLibrary = false
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        return WatchedFolder(bookmark: bookmark, displayPath: url.path, options: options.normalized)
    }

    private func makeRig(_ label: String, custom: Bool) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-reload-\(label)-\(UUID().uuidString)", isDirectory: true)
        let defaults = temporaryDefaults()
        let previous = DefaultsStore.current
        DefaultsStore.current = defaults
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("reload-\(label)"))
        let format = custom
            ? model.addExportPreset(name: "Short SRT", spec: ExportPreset.builtIn(for: .srt)!.spec).id
            : ExportPreset.builtIn(for: .srt)!.id
        let folder = try makeFolder(root, "Old", formats: [format])
        defaults.set(try JSONEncoder().encode([folder]), forKey: "watchedFolders")
        return Rig(model: model, defaults: defaults, root: root, folder: folder, previous: previous)
    }

    private func finish(_ rig: Rig) async {
        await rig.model.watchedFolders.stopWatching()
        DefaultsStore.current = rig.previous
        try? FileManager.default.removeItem(at: rig.root)
    }

    @Test("Reset All removes a folder whose format was a custom preset, and stops watching it")
    func resetAllWithACustomPreset() async throws {
        let rig = try makeRig("reset-custom", custom: true)
        let store = rig.model.watchedFolders
        await waitUntil { store.watcher(for: rig.folder.id) != nil }

        SettingsResetService.resetAll()
        rig.model.reloadSettings()

        await waitUntil { store.watcher(for: rig.folder.id) == nil }
        #expect(store.folders.isEmpty)
        #expect(rig.defaults.data(forKey: "watchedFolders") == nil)
        await finish(rig)
    }

    @Test("Reset All removes a folder whose format was a built-in preset")
    func resetAllWithABuiltInPreset() async throws {
        let rig = try makeRig("reset-builtin", custom: false)
        let store = rig.model.watchedFolders
        await waitUntil { store.watcher(for: rig.folder.id) != nil }

        SettingsResetService.resetAll()
        rig.model.reloadSettings()

        await waitUntil { store.watcher(for: rig.folder.id) == nil }
        #expect(store.folders.isEmpty)
        await finish(rig)
    }

    @Test("an import over existing folders keeps the imported ones, not the old ones")
    func importWins() async throws {
        let rig = try makeRig("import", custom: true)
        let store = rig.model.watchedFolders
        await waitUntil { store.watcher(for: rig.folder.id) != nil }
        let imported = try makeFolder(rig.root, "Imported", formats: [ExportPreset.builtIn(for: .txt)!.id])
        rig.defaults.set(try JSONEncoder().encode([imported]), forKey: "watchedFolders")
        rig.defaults.removeObject(forKey: "exportPresets")

        rig.model.reloadSettings()

        await waitUntil { store.watcher(for: imported.id) != nil && store.watcher(for: rig.folder.id) == nil }
        #expect(store.folders.map(\.id) == [imported.id])
        #expect(store.options(for: imported.id).exportPresetIDs == imported.options.exportPresetIDs)
        await finish(rig)
    }

    @Test("an import whose presets lack a format a folder names prunes that folder after the load")
    func importPrunesAgainstTheImportedPresets() async throws {
        let rig = try makeRig("import-prune", custom: false)
        let store = rig.model.watchedFolders
        await waitUntil { store.watcher(for: rig.folder.id) != nil }
        let missing = UUID()
        var changed = rig.folder
        changed.options.exportPresetIDs = [missing]
        rig.defaults.set(try JSONEncoder().encode([changed]), forKey: "watchedFolders")

        rig.model.reloadSettings()

        #expect(store.options(for: rig.folder.id).exportPresetIDs.isEmpty)
        #expect(store.options(for: rig.folder.id).savesToLibrary)
        await finish(rig)
    }
}

@MainActor
@Suite("Bridge watched-folder options errors", .serialized)
struct WatchedFolderOptionsBridgeTests {

    private func makeRig(buildStore: Bool) throws -> (AppModel, AutomationContext, AutomationCommand, UUID, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-bridge-options-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let bookmark = try inbox.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = WatchedFolder(bookmark: bookmark, displayPath: inbox.path)
        let defaults = temporaryDefaults()
        defaults.set(try JSONEncoder().encode([folder]), forKey: "watchedFolders")
        let bootstrap = AppBootstrap(
            mode: .test, library: makeTempLibraryURL("bridge-options"), defaultsOverride: defaults, sideEffects: [],
            filePicker: TestFilePicker(), enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        let model = AppModel(bootstrap: bootstrap)
        let server = try ParolaAutomationServer(model: model)
        let context = AutomationContext(model: model, server: server)
        if buildStore { _ = model.watchedFolders }
        let command = try #require(server.exportCommands().first { $0.name == "setWatchedFolderOptions" })
        return (model, context, command, folder.id, root)
    }

    private func failure(_ command: AutomationCommand, _ args: [String: AutomationValue], _ context: AutomationContext) async -> AutomationError? {
        do {
            _ = try await command.handler(try command.validate(AutomationArgs(args)), context)
            return nil
        } catch let error as AutomationError {
            return error
        } catch {
            return nil
        }
    }

    @Test("without a built store the command says the pane has to be open")
    func storeNotBuilt() async throws {
        let (_, context, command, id, root) = try makeRig(buildStore: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let error = await failure(command, ["id": .string(id.uuidString), "autoTranscribe": .bool(false)], context)

        guard case .precondition? = error else { Issue.record("expected a precondition, got \(String(describing: error))"); return }
    }

    @Test("an unknown preset id and an Auto-Export destination with no folder are INVALID_ARGS")
    func invalidArguments() async throws {
        let (model, context, command, id, root) = try makeRig(buildStore: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unknown = await failure(command, ["id": .string(id.uuidString), "exportPresetIDs": .array([.string(UUID().uuidString)])], context)
        guard case .invalidArgs(let presetField, _)? = unknown else { Issue.record("expected INVALID_ARGS for the preset"); return }
        #expect(presetField == "exportPresetIDs")

        let noFolder = await failure(command, ["id": .string(id.uuidString), "exportTo": .string("autoExportFolder")], context)
        guard case .invalidArgs(let destinationField, _)? = noFolder else { Issue.record("expected INVALID_ARGS for the destination"); return }
        #expect(destinationField == "exportTo")
        #expect(model.watchedFolders.options(for: id) == .default)
        await model.watchedFolders.stopWatching()
    }
}
