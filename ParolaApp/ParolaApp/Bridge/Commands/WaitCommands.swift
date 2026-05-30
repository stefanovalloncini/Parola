import Foundation
import ParolaCore
import ParolaDictation

extension ParolaAutomationServer {
    func waitCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "waitForPhase",
                area: .core,
                summary: "Resolves once model.phase equals the named phase.",
                kind: .waiter,
                args: [
                    .init(name: "phase", kind: .string(), required: true, summary: "Expected phase name"),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(10_000)),
                ],
                handler: { args, ctx in
                    let expected = try args.string("phase")
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 10_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: { ["phase": .string(ParolaAutomationServer.phaseName(ctx.model.phase))] },
                        predicate: { ParolaAutomationServer.phaseName(ctx.model.phase) == expected }
                    )
                }
            ),

            AutomationCommand(
                name: "waitForBatchJob",
                area: .batch,
                summary: "Resolves when the named batch job reaches a final state, including removal.",
                kind: .waiter,
                args: [
                    .init(name: "jobID", kind: .string(), required: true, summary: "Batch job ID"),
                    .init(name: "finalStates", kind: .stringArray, required: false, summary: "States that count as final", defaultValue: .array([.string("done"), .string("failed"), .string("cancelled"), .string("removed")])),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(300_000)),
                ],
                handler: { args, ctx in
                    let jobID = try args.string("jobID")
                    let finals = Set((try? args.stringArray("finalStates")) ?? ["done", "failed", "cancelled", "removed"])
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 300_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: {
                            let state = batchJobState(ctx.model, jobID: jobID)
                            return ["jobID": .string(jobID), "state": .string(state)]
                        },
                        predicate: {
                            let state = batchJobState(ctx.model, jobID: jobID)
                            return finals.contains(state)
                        },
                        successFields: {
                            let state = batchJobState(ctx.model, jobID: jobID)
                            return ["finalState": .string(state)]
                        }
                    )
                }
            ),

            AutomationCommand(
                name: "waitForBatchEmpty",
                area: .batch,
                summary: "Resolves when no batch jobs remain.",
                kind: .waiter,
                args: [
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(600_000)),
                ],
                handler: { args, ctx in
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 600_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: { ["batchJobCount": .int(ctx.model.batchJobs.count)] },
                        predicate: { ctx.model.batchJobs.isEmpty }
                    )
                }
            ),

            AutomationCommand(
                name: "waitForPromptOutput",
                area: .prompt,
                summary: "Resolves when isRunningPrompt becomes false after running a prompt.",
                kind: .waiter,
                args: [
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(120_000)),
                ],
                handler: { args, ctx in
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 120_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: { ["isRunningPrompt": .bool(ctx.model.isRunningPrompt)] },
                        predicate: { !ctx.model.isRunningPrompt }
                    )
                }
            ),

            AutomationCommand(
                name: "waitForTranscriptLoaded",
                area: .transcript,
                summary: "Resolves when a transcript loads. Matches a specific entryID if given.",
                kind: .waiter,
                args: [
                    .init(name: "entryID", kind: .string(), required: false, summary: "Library entry ID, or any if absent", defaultValue: .null),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(30_000)),
                ],
                handler: { args, ctx in
                    let entryID = try args.optionalString("entryID")
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 30_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: {
                            [
                                "selectedEntryID": .string(ctx.model.selectedEntryID ?? ""),
                                "hasTranscript": .bool(ctx.model.transcript != nil),
                            ]
                        },
                        predicate: {
                            guard ctx.model.transcript != nil else { return false }
                            if let expected = entryID {
                                return ctx.model.selectedEntryID == expected
                            }
                            return true
                        }
                    )
                }
            ),

            AutomationCommand(
                name: "waitForDictationState",
                area: .dictation,
                summary: "Resolves when the dictation controller reports the named state.",
                kind: .waiter,
                args: [
                    .init(name: "state", kind: .string(enum: ["idle", "listening", "transcribing", "stopped"]), required: true, summary: "Target dictation state"),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(10_000)),
                ],
                handler: { args, ctx in
                    let target = try args.string("state")
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 10_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: {
                            [
                                "state": .string("\(ctx.model.dictationState)"),
                                "running": .bool(ctx.model.dictationController.isRunning),
                                "dictationEnabled": .bool(ctx.model.dictationEnabled),
                            ]
                        },
                        predicate: {
                            switch target {
                            case "listening": return ctx.model.dictationState == .listening
                            case "transcribing": return ctx.model.dictationState == .transcribing
                            case "idle": return ctx.model.dictationState == .idle
                            case "stopped": return !ctx.model.dictationController.isRunning
                            default: return false
                            }
                        }
                    )
                }
            ),

            AutomationCommand(
                name: "waitForLibraryCount",
                area: .library,
                summary: "Resolves when the library entry count matches the given operator.",
                kind: .waiter,
                args: [
                    .init(name: "op", kind: .string(enum: ["==", ">=", "<="]), required: true, summary: "Comparison operator"),
                    .init(name: "count", kind: .integer, required: true, summary: "Reference count"),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(10_000)),
                ],
                handler: { args, ctx in
                    let op = try args.string("op")
                    let target = try args.int("count")
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 10_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: { ["libraryCount": .int(ctx.model.libraryEntries.count)] },
                        predicate: {
                            let current = ctx.model.libraryEntries.count
                            switch op {
                            case "==": return current == target
                            case ">=": return current >= target
                            case "<=": return current <= target
                            default: return false
                            }
                        }
                    )
                }
            ),

            AutomationCommand(
                name: "waitForRevision",
                area: .core,
                summary: "Resolves when the server's state revision counter is at least `min`.",
                kind: .waiter,
                args: [
                    .init(name: "min", kind: .integer, required: true, summary: "Minimum revision to wait for"),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(10_000)),
                ],
                handler: { args, ctx in
                    let min = try args.int("min")
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 10_000
                    return await waitForCondition(
                        ctx: ctx,
                        timeoutMs: timeoutMs,
                        observed: { ["revision": .int(ctx.server.currentRevision())] },
                        predicate: { ctx.server.currentRevision() >= min }
                    )
                }
            ),
        ]
    }
}

@MainActor
private func waitForCondition(
    ctx: AutomationContext,
    timeoutMs: Int,
    observed: @MainActor () -> [String: AutomationValue],
    predicate: @MainActor () -> Bool,
    successFields: @MainActor () -> [String: AutomationValue] = { [:] }
) async -> AutomationValue {
    let clock = ctx.model.clock
    let pollIntervalMs = 50
    func matchedResult() -> AutomationValue {
        var result: [String: AutomationValue] = [
            "matched": .bool(true),
            "observed": .object(observed()),
        ]
        for (k, v) in successFields() { result[k] = v }
        return .object(result)
    }
    var elapsedMs = 0
    while elapsedMs < timeoutMs {
        if predicate() { return matchedResult() }
        try? await Task.sleep(for: .milliseconds(pollIntervalMs), clock: clock)
        elapsedMs += pollIntervalMs
    }
    if predicate() { return matchedResult() }
    return .object([
        "matched": .bool(false),
        "timedOut": .bool(true),
        "observed": .object(observed()),
    ])
}

@MainActor
private func batchJobState(_ model: AppModel, jobID: String) -> String {
    if let job = model.batchJobs.first(where: { $0.id.uuidString == jobID }) {
        switch job.status {
        case .pending:      return "pending"
        case .transcribing: return "transcribing"
        case .done:         return "done"
        case .failed:       return "failed"
        case .cancelled:    return "cancelled"
        }
    }
    return "removed"
}
