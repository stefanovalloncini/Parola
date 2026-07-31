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
                            "progress": .double(job.progress),
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
