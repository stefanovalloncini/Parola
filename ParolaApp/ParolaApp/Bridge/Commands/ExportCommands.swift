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
        ]
    }
}
