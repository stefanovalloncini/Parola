import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func coreCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "ping",
                area: .core,
                summary: "Liveness check; returns {pong: true}.",
                kind: .sync,
                handler: { _, _ in
                    .object(["pong": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "_handshake",
                area: .core,
                summary: "Returns serverVersion, app version, and the command catalog for discovery.",
                kind: .sync,
                handler: { _, ctx in
                    let names = ctx.server.commandNames()
                    return .object([
                        "serverVersion": .int(ParolaAutomationServer.serverVersion),
                        "appVersion": .string(Parola.version),
                        "commands": .array(names.map { .string($0) }),
                        "capabilities": .array(ctx.server.capabilities().map { .string($0) }),
                    ])
                }
            ),

            AutomationCommand(
                name: "getState",
                area: .core,
                summary: "Hand-curated snapshot of AppModel state.",
                kind: .sync,
                handler: { _, ctx in
                    ctx.server.snapshotState()
                }
            ),

            AutomationCommand(
                name: "getSettings",
                area: .core,
                summary: "Returns the bridge-readable subset of the app's UserDefaults suite.",
                kind: .sync,
                handler: { _, ctx in
                    let d = ctx.model.defaults
                    let keys = [
                        "useStreaming", "wordTimestamps", "karaokeHighlight", "initialPrompt",
                        "diarize", "batchExportFormats", "batchExportToSourceFolder",
                        "batchExportIncludeTimestamps", "selectedModel", "selectedLanguageRaw",
                        "translate", "dictationEnabled", "appTheme", "monospacedTimestamps",
                        "sidebarDensity", "dictationCleanupPromptID", "dictationPerAppOverridesJSON",
                        "meetingDetectorEnabled",
                    ]
                    var out: [String: AutomationValue] = [:]
                    for key in keys {
                        out[key] = AutomationValue(d.object(forKey: key))
                    }
                    return .object(out)
                }
            ),

            AutomationCommand(
                name: "getStateRevision",
                area: .core,
                summary: "Returns a monotonically increasing counter bumped after every mutating command.",
                kind: .sync,
                handler: { _, ctx in
                    .object(["revision": .int(ctx.server.currentRevision())])
                }
            ),

            AutomationCommand(
                name: "dismissError",
                area: .core,
                summary: "Clears the current failed phase.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.dismissError()
                    return .object(["dismissed": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "cancel",
                area: .core,
                summary: "Cancels the current cancellable operation.",
                kind: .mutating,
                handler: { _, ctx in
                    let wasCancellable = ctx.model.canCancel
                    ctx.model.cancelCurrentWork()
                    return .object(["cancelled": .bool(wasCancellable)])
                }
            ),

            AutomationCommand(
                name: "getTranscript",
                area: .core,
                summary: "Returns the current transcript text and metadata, or null.",
                kind: .sync,
                handler: { _, ctx in
                    guard let t = ctx.model.transcript else { return .null }
                    return .object([
                        "text": .string(t.segments.map(\.text).joined(separator: "\n")),
                        "language": .string(t.language),
                        "modelName": .string(t.modelName),
                        "segmentCount": .int(t.segments.count),
                        "durationSeconds": .double(t.durationSeconds ?? 0),
                    ])
                }
            ),
        ]
    }
}
