import Foundation

extension ParolaAutomationServer {
    func revisionLogCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "getRevisionLog",
                area: .core,
                summary: "Returns the most recent state revisions.",
                kind: .sync,
                args: [
                    .init(name: "count", kind: .integer, required: false, summary: "Max entries to return (default 50)", defaultValue: .int(50)),
                ],
                handler: { args, ctx in
                    let count = (try? args.int("count")) ?? 50
                    let entries = await ctx.server.revisionLog.recent(count: count)
                    return .array(entries.map(\.automationValue))
                }
            ),

            AutomationCommand(
                name: "getRevisionLogSince",
                area: .core,
                summary: "Returns revisions strictly greater than the given revision number.",
                kind: .sync,
                args: [
                    .init(name: "revision", kind: .integer, required: true, summary: "Lower-bound exclusive revision number"),
                ],
                handler: { args, ctx in
                    let revision = try args.int("revision")
                    let entries = await ctx.server.revisionLog.since(revision)
                    return .array(entries.map(\.automationValue))
                }
            ),
        ]
    }
}
