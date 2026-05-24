import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func transcriptCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "transcribeFile",
                area: .transcript,
                summary: "Starts transcription of a local audio/video file.",
                kind: .mutating,
                args: [
                    .init(name: "path", kind: .string(), required: true, summary: "Absolute path to the input file"),
                    .init(name: "translate", kind: .boolean, required: false, summary: "Override translate mode for this run"),
                ],
                followsWith: ["waitForPhase"],
                handler: { args, ctx in
                    let path = try args.string("path")
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw AutomationError.notFound(kind: "file", id: path)
                    }
                    let translate = try args.optionalBool("translate")
                    ctx.model.transcribe(fileURL: url, translateOverride: translate)
                    return .object(["started": .bool(true), "file": .string(url.path)])
                }
            ),

            AutomationCommand(
                name: "transcribeYouTube",
                area: .transcript,
                summary: "Downloads + transcribes the given YouTube URL.",
                kind: .mutating,
                args: [
                    .init(name: "url", kind: .string(), required: true, summary: "YouTube URL"),
                ],
                followsWith: ["waitForPhase"],
                handler: { args, ctx in
                    let url = try args.string("url")
                    ctx.model.transcribeYouTube(urlString: url)
                    return .object(["started": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "clearTranscript",
                area: .transcript,
                summary: "Clears the loaded transcript and returns to idle.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.transcript = nil
                    if case .ready = ctx.model.phase { ctx.model.phase = .idle }
                    return .object(["cleared": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "exportTranscript",
                area: .transcript,
                summary: "Exports the current transcript in the chosen format via a save panel.",
                kind: .mutating,
                args: [
                    .init(
                        name: "format",
                        kind: .string(enum: ExportFormat.allCases.map(\.rawValue)),
                        required: true,
                        summary: "Export format"
                    ),
                ],
                handler: { args, ctx in
                    guard ctx.model.transcript != nil else {
                        throw AutomationError.precondition("no transcript loaded")
                    }
                    let raw = try args.string("format")
                    guard let format = ExportFormat(rawValue: raw) else {
                        throw AutomationError.invalidArgs(field: "format", reason: "invalid format: \(raw)")
                    }
                    ctx.model.performExport(format)
                    return .object(["queued": .bool(true), "format": .string(raw)])
                }
            ),

            AutomationCommand(
                name: "setLanguage",
                area: .transcript,
                summary: "Sets the spoken-language hint (empty string = auto).",
                kind: .mutating,
                args: [
                    .init(name: "code", kind: .string(), required: false, summary: "BCP-47 language code; empty for auto", defaultValue: .string("")),
                ],
                handler: { args, ctx in
                    let code = (try args.optionalString("code")) ?? ""
                    ctx.model.selectedLanguage = code.isEmpty ? nil : code
                    return .object(["language": .string(code)])
                }
            ),

            AutomationCommand(
                name: "setTheme",
                area: .transcript,
                summary: "Sets the app theme.",
                kind: .mutating,
                args: [
                    .init(name: "theme", kind: .string(enum: ["light", "dark", "system"]), required: true, summary: "light, dark, or system"),
                ],
                handler: { args, ctx in
                    let theme = try args.string("theme")
                    ctx.model.appTheme = theme
                    return .object(["appTheme": .string(theme)])
                }
            ),
        ]
    }
}
