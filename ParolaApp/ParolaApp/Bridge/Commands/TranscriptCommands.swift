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
                summary: "Downloads + transcribes the given YouTube URL. Parks the link while a take or run is in flight.",
                kind: .mutating,
                args: [
                    .init(name: "url", kind: .string(), required: true, summary: "YouTube URL"),
                ],
                followsWith: ["waitForPhase"],
                handler: { args, ctx in
                    try ctx.require(.youtube)
                    let url = try args.string("url")
                    let handoff = ctx.model.transcribeYouTube(urlString: url)
                    return .object([
                        "started": .bool(handoff == .started),
                        "parked": .bool(handoff == .parked),
                    ])
                }
            ),

            AutomationCommand(
                name: "toggleInspector",
                area: .transcript,
                summary: "Toggles the transcript inspector, the same way ⌘⇧I does.",
                kind: .mutating,
                handler: { _, ctx in
                    let isNarrow = ctx.model.transcriptPaneIsNarrow
                    InspectorVisibility.toggle(in: ctx.model.defaults, isNarrow: isNarrow)
                    let visible = InspectorVisibility.isVisible(
                        preference: InspectorVisibility.preference(in: ctx.model.defaults),
                        forcedAtNarrowWidth: ctx.model.defaults.bool(forKey: InspectorVisibility.forcedAtNarrowWidthKey),
                        isNarrow: isNarrow
                    )
                    return .object(["visible": .bool(visible), "narrow": .bool(isNarrow)])
                }
            ),

            AutomationCommand(
                name: "clearTranscript",
                area: .transcript,
                summary: "Clears the loaded transcript and returns to idle.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.clearLoadedEntry()
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
                    .init(
                        name: "includeTimestamps",
                        kind: .boolean,
                        required: false,
                        summary: "Overrides the saved timestamp preference for txt, md and html"
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
                    let includeTimestamps = try args.optionalBool("includeTimestamps")
                    ctx.model.performExport(ctx.model.exportSpec(for: format, includeTimestamps: includeTimestamps))
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
                name: "translateTranscript",
                area: .transcript,
                summary: "Translates the open transcript into a language and stores the result. Uses whichever translator is installed.",
                kind: .mutating,
                args: [
                    .init(name: "language", kind: .string(), required: true, summary: "BCP-47 language code to translate into"),
                ],
                handler: { args, ctx in
                    let language = try args.string("language")
                    guard ctx.model.transcript != nil else {
                        throw AutomationError.precondition("no transcript is open")
                    }
                    let before = ctx.model.transcript?.translation
                    await ctx.model.translateTranscript(to: language)
                    guard let translation = ctx.model.transcript?.translation, translation != before else {
                        return .object([
                            "translated": .bool(false),
                            "reason": .string(translationRefusal(ctx.model)),
                        ])
                    }
                    return .object([
                        "translated": .bool(true),
                        "targetLanguage": .string(translation.targetLanguage),
                        "segmentCount": .int(translation.segments.count),
                        "provider": .string(translation.provider),
                    ])
                }
            ),

            AutomationCommand(
                name: "removeTranslation",
                area: .transcript,
                summary: "Drops the open transcript's translation.",
                kind: .mutating,
                handler: { _, ctx in
                    let had = ctx.model.transcript?.translation != nil
                    await ctx.model.removeTranslation()
                    return .object(["removed": .bool(had)])
                }
            ),

            AutomationCommand(
                name: "setTheme",
                area: .transcript,
                summary: "Sets the appearance (light/dark/system) and/or the color preset.",
                kind: .mutating,
                args: [
                    .init(name: "theme", kind: .string(enum: ["light", "dark", "system"]), required: false, summary: "Appearance: light, dark, or system"),
                    .init(name: "preset", kind: .string(enum: ThemePreset.allCases.map(\.rawValue)), required: false, summary: "Color preset"),
                    .init(name: "palette", kind: .object, required: false, summary: "Custom palette: hex strings for accent/canvas/surface/surfaceElevated/divider/textPrimary/textSecondary"),
                ],
                handler: { args, ctx in
                    if let theme = try args.optionalString("theme") {
                        ctx.model.appTheme = theme
                    }
                    if let preset = try args.optionalString("preset") {
                        guard ThemePreset(rawValue: preset) != nil else {
                            throw AutomationError.invalidArgs(field: "preset", reason: "unknown preset '\(preset)'")
                        }
                        ctx.model.selectThemePreset(preset)
                    }
                    if let raw = args.rawValue("palette"), case .object(let obj) = raw {
                        ctx.model.applyCustomPalette(buildCustomPalette(obj))
                    }
                    return .object([
                        "appTheme": .string(ctx.model.appTheme),
                        "themePreset": .string(ctx.model.appAccentRaw),
                        "themeIsCustom": .bool(ctx.model.themeIsCustom),
                    ])
                }
            ),
        ]
    }
}

/// Why a translation produced nothing: the run's own message when it failed, otherwise the guard
/// that refused it.
@MainActor
private func translationRefusal(_ model: AppModel) -> String {
    if case .failed(let message) = model.translationCoordinator.state { return message }
    if model.translationCoordinator.isRunning { return "another translation is already running" }
    if model.selectedEntryID == nil { return "the transcript is not a library entry" }
    return "the transcript has no text to translate"
}

private func buildCustomPalette(_ obj: [String: AutomationValue]) -> ThemePalette {
    let base = ThemePreset.defaultPreset.palette
    func token(_ key: String, _ fallback: ThemeColor) -> ThemeColor {
        if case .string(let hex)? = obj[key], let rgba = RGBA(hex: hex) { return .uniform(rgba) }
        return fallback
    }
    return ThemePalette(
        accent: token("accent", base.accent),
        canvas: token("canvas", base.canvas),
        surface: token("surface", base.surface),
        surfaceElevated: token("surfaceElevated", base.surfaceElevated),
        divider: token("divider", base.divider),
        textPrimary: token("textPrimary", base.textPrimary),
        textSecondary: token("textSecondary", base.textSecondary),
        success: base.success,
        warning: base.warning,
        danger: base.danger
    )
}
