import Foundation

extension ParolaAutomationServer {
    func batchCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "startBatch",
                area: .batch,
                summary: "Starts a new batch job with the given file paths.",
                kind: .mutating,
                args: [
                    .init(name: "paths", kind: .stringArray, required: true, summary: "Absolute paths to input files"),
                ],
                handler: { args, ctx in
                    try ctx.require(.batch)
                    let urls = try resolveExistingPaths(args)
                    ctx.model.startBatch(urls: urls)
                    return .object(["started": .bool(true), "count": .int(urls.count)])
                }
            ),

            AutomationCommand(
                name: "addBatchFiles",
                area: .batch,
                summary: "Adds files to the running or pending batch.",
                kind: .mutating,
                args: [
                    .init(name: "paths", kind: .stringArray, required: true, summary: "Absolute paths to input files"),
                ],
                handler: { args, ctx in
                    try ctx.require(.batch)
                    let urls = try resolveExistingPaths(args)
                    ctx.model.addBatchFiles(urls)
                    return .object(["added": .int(urls.count)])
                }
            ),

            AutomationCommand(
                name: "dropFiles",
                area: .batch,
                summary: "Routes files through the split drop zone: half 'now' transcribes, 'queue' enqueues.",
                kind: .mutating,
                args: [
                    .init(name: "paths", kind: .stringArray, required: true, summary: "Absolute paths to input files"),
                    .init(
                        name: "half",
                        kind: .string(enum: AppModel.DropHalf.allCases.map(\.rawValue)),
                        required: false,
                        summary: "Which half of the drop zone the files landed on",
                        defaultValue: .string(AppModel.DropHalf.now.rawValue)
                    ),
                ],
                handler: { args, ctx in
                    let urls = try resolveExistingPaths(args)
                    let raw = (try args.optionalString("half")) ?? AppModel.DropHalf.now.rawValue
                    guard let half = AppModel.DropHalf(rawValue: raw) else {
                        throw AutomationError.invalidArgs(field: "half", reason: "unknown half: \(raw)")
                    }
                    ctx.model.drop(urls, on: half)
                    return .object([
                        "half": .string(half.rawValue),
                        "count": .int(urls.count),
                        "route": .string(ctx.model.route.rawValue),
                    ])
                }
            ),

            AutomationCommand(
                name: "previewDropZone",
                area: .test,
                summary: "Test mode only: shapes the split drop overlay without a drag so it can be captured.",
                kind: .mutating,
                args: [
                    .init(
                        name: "payload",
                        kind: .string(enum: ["media", "subtitles", "projects", "links", "mixed", "unsupported", ""]),
                        required: false,
                        summary: "Payload kind to shape the overlay for; empty clears the preview",
                        defaultValue: .string("media")
                    ),
                    .init(name: "count", kind: .integer, required: false, summary: "How many items the payload holds", defaultValue: .int(3)),
                    .init(
                        name: "half",
                        kind: .string(enum: AppModel.DropHalf.allCases.map(\.rawValue) + [""]),
                        required: false,
                        summary: "Which half reads as hot; empty for neither",
                        defaultValue: .string("")
                    ),
                ],
                handler: { args, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("previewDropZone needs --test-mode")
                    }
                    let name = (try args.optionalString("payload")) ?? ""
                    guard !name.isEmpty else {
                        ctx.model.dropDragPayload = nil
                        ctx.model.dropHighlight = nil
                        return .object(["payload": .string("")])
                    }
                    let count = (try args.optionalInt("count")) ?? 3
                    guard let payload = DroppedFiles.kind(named: name, count: count) else {
                        throw AutomationError.invalidArgs(field: "payload", reason: "unknown payload: \(name)")
                    }
                    ctx.model.dropDragPayload = payload
                    ctx.model.dropHighlight = AppModel.DropHalf(rawValue: (try args.optionalString("half")) ?? "")
                    return .object([
                        "payload": .string(payload.name),
                        "count": .int(payload.count),
                        "half": .string(ctx.model.dropHighlight?.rawValue ?? ""),
                        "zones": .string(ctx.model.dropZonePlan.name),
                    ])
                }
            ),

            AutomationCommand(
                name: "clearBatch",
                area: .batch,
                summary: "Clears the batch job list.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.clearBatch()
                    return .object(["cleared": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "getBatchJobs",
                area: .batch,
                summary: "Returns the current batch jobs.",
                kind: .sync,
                handler: { _, ctx in
                    .array(ctx.model.batchJobs.map { job in
                        .object([
                            "id": .string(job.id.uuidString),
                            "url": .string(job.url.path),
                            "status": .string(job.status.rawValue),
                            "progress": .double(ctx.model.batchProgress.fraction(for: job.id)),
                            "error": .string(job.error ?? ""),
                            "hasTranscript": .bool(job.transcript != nil),
                        ])
                    })
                }
            ),

            AutomationCommand(
                name: "selectBatchJob",
                area: .batch,
                summary: "Selects a batch job by UUID.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Batch job UUID"),
                ],
                handler: { args, ctx in
                    let idStr = try args.string("id")
                    guard let id = UUID(uuidString: idStr) else {
                        throw AutomationError.invalidArgs(field: "id", reason: "not a valid UUID")
                    }
                    ctx.model.selectBatchJob(id)
                    return .object(["selected": .string(idStr)])
                }
            ),
        ]
    }
}

@MainActor
func resolveExistingPaths(_ args: AutomationArgs) throws -> [URL] {
    let paths = try args.stringArray("paths")
    guard !paths.isEmpty else {
        throw AutomationError.invalidArgs(field: "paths", reason: "must not be empty")
    }
    let urls = paths.map { URL(fileURLWithPath: $0) }
    let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
    guard missing.isEmpty else {
        throw AutomationError.notFound(kind: "file", id: missing.map(\.path).joined(separator: ", "))
    }
    return urls
}
