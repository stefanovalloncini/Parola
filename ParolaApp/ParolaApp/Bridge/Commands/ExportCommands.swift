import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func exportCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "openExportSheet",
                area: .transcript,
                summary: "Opens the Export sheet on the loaded transcript.",
                kind: .mutating,
                followsWith: ["setExportSpec", "getState"],
                handler: { _, ctx in
                    ctx.model.openExportSheet()
                    guard ctx.model.exportSheetOpen else {
                        throw AutomationError.precondition("no transcript to export")
                    }
                    return .object([
                        "open": .bool(true),
                        "spec": ParolaAutomationServer.encode(ctx.model.exportSheetSpec),
                    ])
                }
            ),

            AutomationCommand(
                name: "setExportSpec",
                area: .transcript,
                summary: "Merges the given fields over the Export sheet's spec.",
                kind: .mutating,
                args: [
                    .init(name: "spec", kind: .object, required: true, summary: "ExportSpec fields to merge over the current spec"),
                ],
                handler: { args, ctx in
                    let merged = try ctx.model.mergedExportSpec(overriding: try args.object("spec"))
                    ctx.model.setExportSpec(merged)
                    return .object(["spec": ParolaAutomationServer.encode(ctx.model.exportSheetSpec)])
                }
            ),

            AutomationCommand(
                name: "exportWithSpec",
                area: .transcript,
                summary: "Writes the loaded transcript to a path with the given spec.",
                kind: .async,
                args: [
                    .init(name: "spec", kind: .object, required: true, summary: "ExportSpec fields to merge over the current spec"),
                    .init(name: "path", kind: .string(), required: true, summary: "Absolute path of the file to write"),
                ],
                handler: { args, ctx in
                    let spec = try ctx.model.mergedExportSpec(overriding: try args.object("spec"))
                    let url = URL(fileURLWithPath: try args.string("path"))
                    try await ctx.model.exportTranscript(spec: spec, to: url)
                    return .object(["path": .string(url.path), "format": .string(spec.format.rawValue)])
                }
            ),

            AutomationCommand(
                name: "setExportPresets",
                area: .settings,
                summary: "Replaces the saved export presets. Built-ins are kept and re-stamped.",
                kind: .mutating,
                args: [
                    .init(name: "presets", kind: .any, required: true, summary: "Array of ExportPreset objects"),
                ],
                handler: { args, ctx in
                    guard case .array(let raw)? = args.rawValue("presets") else {
                        throw AutomationError.invalidArgs(field: "presets", reason: "must be an array of presets")
                    }
                    let json = raw.map(\.jsonObject)
                    guard let data = try? JSONSerialization.data(withJSONObject: json),
                          let decoded = try? JSONDecoder().decode([ExportPreset].self, from: data) else {
                        throw AutomationError.invalidArgs(field: "presets", reason: "could not decode the given presets")
                    }
                    ctx.model.setExportPresets(decoded)
                    return .object(["exportPresets": ParolaAutomationServer.encode(ctx.model.exportPresets)])
                }
            ),

            AutomationCommand(
                name: "openWatchedFolderOptions",
                area: .test,
                summary: "Test mode: opens one watched folder's Options sheet in the Watched Folders pane, which has to be on screen; no id closes it. Replies {open}.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: false, summary: "The folder's id, from getSettings watchedFolders"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    guard let store = ctx.model.watchedFoldersIfWatching else {
                        throw AutomationError.precondition("Watched Folders isn't running; open its Settings pane first")
                    }
                    guard let raw = try args.optionalString("id") else {
                        store.optionsSheetFolderID = nil
                        return .object(["open": .null])
                    }
                    guard let id = UUID(uuidString: raw), store.folders.contains(where: { $0.id == id }) else {
                        throw AutomationError.invalidArgs(field: "id", reason: "no watched folder has this id")
                    }
                    store.optionsSheetFolderID = id
                    return .object(["open": .string(id.uuidString)])
                }
            ),

            AutomationCommand(
                name: "setWatchedFolderOptions",
                area: .test,
                summary: "Test mode: sets fields of one watched folder's options, as the Options sheet does. Replies {id, options}.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "The folder's id, from getSettings watchedFolders"),
                    .init(name: "autoTranscribe", kind: .boolean, required: false, summary: "False sends new files to Batch as pending jobs"),
                    .init(name: "includeSubfolders", kind: .boolean, required: false, summary: "False watches the folder itself only"),
                    .init(name: "saveToLibrary", kind: .boolean, required: false, summary: "False exports the transcript and keeps nothing in the library"),
                    .init(name: "exportPresetIDs", kind: .stringArray, required: false, summary: "Export preset ids, in order; replaces the list"),
                    .init(name: "exportTo", kind: .string(), required: false, summary: "nextToFile or autoExportFolder"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    guard let store = ctx.model.watchedFoldersIfWatching else {
                        throw AutomationError.precondition("Watched Folders isn't running; open its Settings pane first")
                    }
                    guard let id = UUID(uuidString: try args.string("id")),
                          store.folders.contains(where: { $0.id == id }) else {
                        throw AutomationError.invalidArgs(field: "id", reason: "no watched folder has this id")
                    }
                    var options = store.options(for: id)
                    if let value = try args.optionalBool("autoTranscribe") { options.autoTranscribes = value }
                    if let value = try args.optionalBool("includeSubfolders") { options.includesSubfolders = value }
                    if let value = try args.optionalBool("saveToLibrary") { options.savesToLibrary = value }
                    if let ids = try args.optionalStringArray("exportPresetIDs") {
                        let known = Set(ctx.model.exportPresets.map(\.id))
                        let parsed = ids.map { UUID(uuidString: $0) }
                        guard parsed.allSatisfy({ $0.map(known.contains) == true }) else {
                            throw AutomationError.invalidArgs(field: "exportPresetIDs", reason: "every id must name an export preset")
                        }
                        options.exportPresetIDs = parsed.compactMap { $0 }
                    }
                    if let destination = try args.optionalString("exportTo") {
                        switch destination {
                        case "nextToFile": options.exportsToAutoExportFolder = false
                        case "autoExportFolder":
                            guard ctx.model.autoExportFolder != nil else {
                                throw AutomationError.invalidArgs(field: "exportTo", reason: "choose an Auto-Export folder first")
                            }
                            options.exportsToAutoExportFolder = true
                        default: throw AutomationError.invalidArgs(field: "exportTo", reason: "must be nextToFile or autoExportFolder")
                        }
                    }
                    store.setOptions(options, for: id)
                    return .object([
                        "id": .string(id.uuidString),
                        "options": ParolaAutomationServer.watchedFolderOptionsValue(store.options(for: id)),
                    ])
                }
            ),
        ]
    }
}
