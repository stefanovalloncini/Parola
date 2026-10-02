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
                summary: "Hand-curated snapshot of AppModel state. While transcribing, phaseDetail carries progress, stage and hasPartialText.",
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
                    var out: [String: AutomationValue] = [:]
                    for key in ParolaAutomationServer.writableSettingKeys.sorted() {
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
                summary: "Cancels the current cancellable operation, never a take that records or is paused (stopRecording ends that). Returns {cancelled: true} once the run has unwound, {cancelling: true} while it is still stopping, {cancelled: false} when there was nothing to cancel.",
                kind: .mutating,
                handler: { _, ctx in
                    let wasCancellable = ctx.model.canCancel
                    ctx.model.cancelCurrentWork()
                    guard wasCancellable else { return .object(["cancelled": .bool(false)]) }
                    guard await ctx.model.awaitCancelSettled(within: .seconds(2)) else {
                        return .object(["cancelling": .bool(true)])
                    }
                    return .object(["cancelled": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "pressNoticeAction",
                area: .core,
                summary: "Test mode: presses one of the notice strip's buttons by the id getState.exportNotice.actions lists, the way a click does. Replies {pressed, notice}; pressed is false when no notice is up or it has no button with that id.",
                kind: .mutating,
                args: [
                    .init(name: "actionID", kind: .string(), required: true, summary: "The button's id, from getState.exportNotice.actions"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    let id = try args.string("actionID")
                    let action = ctx.model.exportNotice?.actions.first { $0.id.uuidString == id }
                    if let action { ctx.model.performNoticeAction(action) }
                    return .object([
                        "pressed": .bool(action != nil),
                        "notice": ParolaAutomationServer.exportNoticeState(ctx.model.exportNotice),
                    ])
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
