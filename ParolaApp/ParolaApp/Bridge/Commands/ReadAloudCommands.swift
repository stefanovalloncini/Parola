import Foundation
import ParolaCore
import ParolaSpeech

extension ParolaAutomationServer {
    func readAloudCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "readAloud",
                area: .readAloud,
                summary: "Starts reading an entry aloud, replacing any reading. Replies {started: true}, or {started: false, reason} with blockedReason while a take, dictation or live captions block reading.",
                kind: .mutating,
                args: [
                    .init(name: "source", kind: .string(enum: ["transcript", "summary", "translation"]), required: false, summary: "What to read", defaultValue: .string("transcript")),
                    .init(name: "entryID", kind: .string(), required: false, summary: "Entry to read; omitted reads the open one"),
                    .init(name: "fromSegment", kind: .integer, required: false, summary: "Segment id to start from (transcript only)"),
                ],
                followsWith: ["waitForReadingState"],
                handler: { args, ctx in
                    let kind: ReadAloudRequest.Kind
                    switch (try args.optionalString("source")) ?? "transcript" {
                    case "summary": kind = .summary
                    case "translation": kind = .translation
                    default: kind = .transcript
                    }
                    let request = ReadAloudRequest(
                        kind: kind, entryID: try args.optionalString("entryID"), fromSegment: try args.optionalInt("fromSegment")
                    )
                    return ParolaAutomationServer.refusalReply(await ctx.model.readAloud(request))
                }
            ),

            AutomationCommand(
                name: "pauseReading",
                area: .readAloud,
                summary: "Pauses the reading as the Pause button does. Replies {state} with the state after.",
                kind: .mutating,
                handler: { _, ctx in
                    await ctx.model.pauseReading()
                    return .object(["state": .string(ctx.model.readAloud.state.name)])
                }
            ),

            AutomationCommand(
                name: "resumeReading",
                area: .readAloud,
                summary: "Resumes a paused reading. Replies {resumed: true, state}, or {resumed: false, reason, blockedReason, state} while a take, dictation or live captions block reading.",
                kind: .mutating,
                handler: { _, ctx in
                    let refusal = await ctx.model.resumeReading()
                    var reply = ParolaAutomationServer.refusalReply(refusal, key: "resumed")
                    if case .object(var fields) = reply {
                        fields["state"] = .string(ctx.model.readAloud.state.name)
                        reply = .object(fields)
                    }
                    return reply
                }
            ),

            AutomationCommand(
                name: "skipReading",
                area: .readAloud,
                summary: "Skips to the next sentence (by 1) or goes back (by -1); going back restarts the sentence once more than 1.5 s of it has played.",
                kind: .mutating,
                args: [
                    .init(name: "by", kind: .integer, required: true, summary: "1 or -1"),
                ],
                handler: { args, ctx in
                    let by = try args.int("by")
                    guard by == 1 || by == -1 else {
                        throw AutomationError.invalidArgs(field: "by", reason: "must be 1 or -1")
                    }
                    await ctx.model.skipReading(by: by)
                    return .object(["state": .string(ctx.model.readAloud.state.name)])
                }
            ),

            AutomationCommand(
                name: "setReadingSpeed",
                area: .readAloud,
                summary: "Sets the reading speed: 0.75, 1, 1.25, 1.5 or 2. Saved as the readAloudRate setting.",
                kind: .mutating,
                args: [
                    .init(name: "rate", kind: .double, required: true, summary: "One of 0.75, 1, 1.25, 1.5, 2"),
                ],
                handler: { args, ctx in
                    let rate = try args.double("rate")
                    guard ReadAloudController.speeds.contains(rate) else {
                        throw AutomationError.invalidArgs(field: "rate", reason: "must be one of 0.75, 1, 1.25, 1.5, 2")
                    }
                    ctx.model.setReadingSpeed(rate)
                    return .object(["speed": .double(ctx.model.readAloud.speed)])
                }
            ),

            AutomationCommand(
                name: "stopReading",
                area: .readAloud,
                summary: "Stops the reading and clears it.",
                kind: .mutating,
                handler: { _, ctx in
                    await ctx.model.stopReading()
                    return .object(["stopped": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "waitForReadingState",
                area: .readAloud,
                summary: "Resolves once the reading reaches the named state. For paused, pausedBy narrows it to one reason.",
                kind: .waiter,
                args: [
                    .init(name: "state", kind: .string(enum: ["idle", "preparing", "reading", "paused", "waiting", "failed", "noVoice"]), required: true, summary: "Target state"),
                    .init(name: "pausedBy", kind: .string(enum: ReadAloudController.PauseReason.allCases.map(\.rawValue)), required: false, summary: "With paused: the reason"),
                    .init(name: "unitIndex", kind: .integer, required: false, summary: "Also wait for the reading to be at least this far"),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(10_000)),
                ],
                handler: { args, ctx in
                    let target = try args.string("state")
                    let reason = try args.optionalString("pausedBy")
                    let unit = try args.optionalInt("unitIndex")
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 10_000
                    let controller = ctx.model.readAloud
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: { ParolaAutomationServer.readingFields(ctx.model) },
                        predicate: {
                            controller.state.name == target
                                && (reason == nil || controller.state.pauseReason?.rawValue == reason)
                                && (unit == nil || (controller.item?.unitIndex ?? -1) >= unit!)
                        },
                        successFields: { ["readAloud": ParolaAutomationServer.readAloudState(ctx.model)] }
                    )
                }
            ),

            AutomationCommand(
                name: "installMockVoice",
                area: .test,
                summary: "Test mode: reads with a silent voice whose every sentence lasts msPerUnit. failAtUnit makes that sentence fail. Clear it with clearMocks scope speech.",
                kind: .mutating,
                args: [
                    .init(name: "msPerUnit", kind: .integer, required: false, summary: "How long each sentence plays, in ms", defaultValue: .int(MockVoiceSettings.defaultMsPerUnit)),
                    .init(name: "failAtUnit", kind: .integer, required: false, summary: "Sentence index that fails before any audio"),
                ],
                handler: { args, ctx in
                    try requireTestMode(ctx)
                    guard let voice = ctx.model.readAloud.mockVoice else {
                        throw AutomationError.precondition("this launch reads with the real voice")
                    }
                    let ms = (try args.optionalInt("msPerUnit")) ?? MockVoiceSettings.defaultMsPerUnit
                    guard ms > 0 else { throw AutomationError.invalidArgs(field: "msPerUnit", reason: "must be positive") }
                    let failAt = try args.optionalInt("failAtUnit")
                    voice.install(msPerUnit: ms, failAtUnit: failAt)
                    return .object([
                        "installed": .bool(true),
                        "msPerUnit": .int(ms),
                        "failAtUnit": failAt.map { .int($0) } ?? .null,
                    ])
                }
            ),
        ]
    }

    static func refusalReply(_ refusal: ReadAloudRefusal?, key: String = "started") -> AutomationValue {
        guard let refusal else { return .object([key: .bool(true)]) }
        switch refusal {
        case .blocked(let reason):
            return .object([key: .bool(false), "reason": .string("blocked"), "blockedReason": .string(reason.rawValue)])
        case .noTranscript:
            return .object([key: .bool(false), "reason": .string("noTranscript")])
        case .unknownEntry:
            return .object([key: .bool(false), "reason": .string("unknownEntry")])
        case .nothingToRead:
            return .object([key: .bool(false), "reason": .string("nothingToRead")])
        }
    }

    static func readingFields(_ model: AppModel) -> [String: AutomationValue] {
        let controller = model.readAloud
        return [
            "state": .string(controller.state.name),
            "pausedBy": controller.state.pauseReason.map { .string($0.rawValue) } ?? .null,
            "unitIndex": controller.item.map { .int($0.unitIndex) } ?? .null,
        ]
    }

    static func readAloudState(_ model: AppModel) -> AutomationValue {
        let controller = model.readAloud
        let item = controller.item
        var source: AutomationValue = .null
        if let item {
            switch item.source {
            case .transcript: source = .string("transcript")
            case .summary: source = .string("summary")
            case .translation: source = .string("translation")
            }
        }
        return .object([
            "state": .string(controller.state.name),
            "pausedBy": controller.state.pauseReason.map { .string($0.rawValue) } ?? .null,
            "source": source,
            "entryID": item.map { .string($0.entryID) } ?? .null,
            "unitIndex": item.map { .int($0.unitIndex) } ?? .null,
            "unitCount": item.map { .int($0.unitCount) } ?? .null,
            "language": item.map { .string($0.language) } ?? .null,
            "voiceID": item.map { .string($0.voice.rawValue) } ?? .null,
            "engine": item.map { .string(Self.engineName(for: $0.voice)) } ?? .null,
            "speed": .double(controller.speed),
            "blockedReason": model.readingBlockedReason.map { .string($0.rawValue) } ?? .null,
        ])
    }

    private static func engineName(for voice: VoiceID) -> String {
        switch voice.kind {
        case .appleAutomatic, .apple: SpeechEngineKind.apple.rawValue
        case .neural(let pack, _): pack
        }
    }
}
