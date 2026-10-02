import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func recordingCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "startRecording",
                area: .recording,
                summary: "Starts recording from microphone or system audio.",
                kind: .mutating,
                args: [
                    .init(
                        name: "source",
                        kind: .string(enum: ["microphone", "systemAudio"]),
                        required: false,
                        summary: "Audio source",
                        defaultValue: .string("microphone")
                    ),
                    .init(
                        name: "category",
                        kind: .string(enum: EntryCategory.allCases.map(\.rawValue)),
                        required: false,
                        summary: "EntryCategory rawValue for the resulting library entry; without one, systemAudio files as meeting, microphone as transcription"
                    ),
                    .init(
                        name: "targetBundleIDs",
                        kind: .stringArray,
                        required: false,
                        summary: "Capture only these apps' audio (systemAudio source only)"
                    ),
                ],
                handler: { args, ctx in
                    let source = (try args.optionalString("source")) ?? "microphone"
                    let recordSource: AppModel.RecordSource = (source == "systemAudio") ? .systemAudio : .microphone
                    try ctx.require(recordSource.feature)
                    let category = try args.optionalString("category").flatMap(EntryCategory.init(rawValue:))
                    let targets = try args.optionalStringArray("targetBundleIDs") ?? []
                    ctx.model.pendingRecordingCategory = category
                    if !targets.isEmpty { ctx.model.pendingCaptureBundleIDs = Set(targets) }
                    ctx.model.startRecording(source: recordSource)
                    return .object([
                        "started": .bool(true),
                        "source": .string(source),
                        "category": .string((category ?? AppModel.defaultCategory(for: recordSource)).rawValue),
                    ])
                }
            ),

            AutomationCommand(
                name: "stopRecording",
                area: .recording,
                summary: "Stops recording and starts transcription; a take still counting in or starting ends the way Cancel ends it.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.stopTake()
                    return .object(["stopped": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "pauseRecording",
                area: .recording,
                summary: "Pauses the take that is recording, as the Stage's Pause does. Test-mode only.",
                kind: .mutating,
                handler: { _, ctx in
                    try requireTestMode(ctx)
                    let paused = ctx.model.pauseTake()
                    return .object([
                        "paused": .bool(paused),
                        "recording": ParolaAutomationServer.recordingState(of: ctx.model, now: Date()),
                    ])
                }
            ),

            AutomationCommand(
                name: "resumeRecording",
                area: .recording,
                summary: "Resumes a paused take. Test-mode only.",
                kind: .mutating,
                handler: { _, ctx in
                    try requireTestMode(ctx)
                    let resumed = ctx.model.resumeTake()
                    return .object([
                        "resumed": .bool(resumed),
                        "recording": ParolaAutomationServer.recordingState(of: ctx.model, now: Date()),
                    ])
                }
            ),

            AutomationCommand(
                name: "addRecordingMarker",
                area: .recording,
                summary: "Marks this moment of the take, as ⌘B on the Stage does. Test-mode only.",
                kind: .mutating,
                handler: { _, ctx in
                    try requireTestMode(ctx)
                    let marker = ctx.model.addTakeMarker()
                    return .object([
                        "marker": marker.map { .double($0) } ?? .null,
                        "recording": ParolaAutomationServer.recordingState(of: ctx.model, now: Date()),
                    ])
                }
            ),

            AutomationCommand(
                name: "discardRecording",
                area: .recording,
                summary: "The Stage's confirmed Discard: the take's audio is deleted and nothing is saved. Test-mode only.",
                kind: .async,
                handler: { _, ctx in
                    try requireTestMode(ctx)
                    let takeID = ctx.model.recording?.takeID
                    await ctx.model.discardTake()
                    return .object([
                        "discarded": .bool(takeID != nil && ctx.model.recording?.takeID != takeID),
                        "recording": ParolaAutomationServer.recordingState(of: ctx.model, now: Date()),
                    ])
                }
            ),

            AutomationCommand(
                name: "toggleLiveCaptions",
                area: .recording,
                summary: "Toggles live captions; waits up to 1s for the flip.",
                kind: .async,
                handler: { _, ctx in
                    try ctx.require(.liveCaptions)
                    let before = ctx.model.liveCaptions?.isActive ?? false
                    ctx.model.toggleLiveCaptions()
                    let clock = ctx.model.clock
                    var waitedMs = 0
                    while (ctx.model.liveCaptions?.isActive ?? false) == before, waitedMs < 1000 {
                        try? await Task.sleep(for: .milliseconds(50), clock: clock)
                        waitedMs += 50
                    }
                    return .object(["liveCaptionsActive": .bool(ctx.model.liveCaptions?.isActive ?? false)])
                }
            ),

            AutomationCommand(
                name: "getLiveCaptionsState",
                area: .recording,
                summary: "Returns the live-captions state (active, partial, confirmed lines).",
                kind: .sync,
                handler: { _, ctx in
                    let s = ctx.model.liveCaptions?.state ?? LiveCaptionsState()
                    return .object([
                        "isActive": .bool(s.isActive),
                        "isLoading": .bool(s.isLoading),
                        "partial": .string(s.partial),
                        "confirmedLines": .array(s.confirmedLines.map { .string($0) }),
                        "displayedText": .string(s.displayedText),
                        "error": s.error.map { .string($0) } ?? .null,
                    ])
                }
            ),

            AutomationCommand(
                name: "setUseStreaming",
                area: .recording,
                summary: "Enables or disables streaming decoding.",
                kind: .mutating,
                args: [
                    .init(name: "on", kind: .boolean, required: true, summary: "true to enable streaming"),
                ],
                handler: { args, ctx in
                    let on = try args.bool("on")
                    ctx.model.useStreaming = on
                    return .object(["useStreaming": .bool(on)])
                }
            ),

            AutomationCommand(
                name: "setTranslate",
                area: .recording,
                summary: "Enables or disables translate-to-English mode.",
                kind: .mutating,
                args: [
                    .init(name: "on", kind: .boolean, required: true, summary: "true to enable translate"),
                ],
                handler: { args, ctx in
                    let on = try args.bool("on")
                    ctx.model.translate = on
                    return .object(["translate": .bool(on)])
                }
            ),
        ]
    }
}
