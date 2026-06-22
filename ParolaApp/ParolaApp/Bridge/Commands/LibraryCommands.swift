import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func libraryCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "listEntries",
                area: .library,
                summary: "Lists library entries, optionally filtered by category.",
                kind: .sync,
                args: [
                    .init(name: "limit", kind: .integer, required: false, summary: "Maximum entries to return", defaultValue: .int(50)),
                    .init(name: "category", kind: .string(), required: false, summary: "Filter by EntryCategory.rawValue"),
                ],
                handler: { args, ctx in
                    let limit = max(0, (try args.optionalInt("limit")) ?? 50)
                    let category = try args.optionalString("category")
                    let entries = ctx.model.libraryEntries.filter { entry in
                        guard let category, !category.isEmpty else { return true }
                        return entry.category.rawValue == category
                    }.prefix(limit)
                    return .array(entries.map { entry in
                        .object([
                            "id": .string(entry.id),
                            "title": .string(entry.title),
                            "category": .string(entry.category.rawValue),
                            "createdAt": .double(entry.createdAt.timeIntervalSince1970),
                        ])
                    })
                }
            ),

            AutomationCommand(
                name: "loadEntry",
                area: .library,
                summary: "Loads a library entry as the current transcript.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Library entry ID"),
                ],
                followsWith: ["waitForPhase"],
                handler: { args, ctx in
                    let id = try args.string("id")
                    ctx.model.loadEntry(id)
                    return .object(["loaded": .string(id)])
                }
            ),

            AutomationCommand(
                name: "deleteEntry",
                area: .library,
                summary: "Soft-deletes a library entry.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Library entry ID"),
                ],
                handler: { args, ctx in
                    let id = try args.string("id")
                    ctx.model.deleteEntry(id)
                    return .object(["deleted": .string(id)])
                }
            ),

            AutomationCommand(
                name: "search",
                area: .library,
                summary: "Searches the library and waits up to 2s for results to land.",
                kind: .async,
                args: [
                    .init(name: "query", kind: .string(), required: true, summary: "Search query"),
                    .init(name: "limit", kind: .integer, required: false, summary: "Max results", defaultValue: .int(20)),
                ],
                handler: { args, ctx in
                    let query = try args.string("query")
                    ctx.model.searchResults = nil
                    ctx.model.search(query)
                    let clock = ctx.model.clock
                    var waitedMs = 0
                    while ctx.model.searchResults == nil, waitedMs < 2000 {
                        try? await Task.sleep(for: .milliseconds(50), clock: clock)
                        waitedMs += 50
                    }
                    let results = ctx.model.searchResults ?? []
                    let limit = max(0, (try args.optionalInt("limit")) ?? 20)
                    return .array(results.prefix(limit).map { e in
                        .object([
                            "id": .string(e.id),
                            "title": .string(e.title),
                            "category": .string(e.category.rawValue),
                        ])
                    })
                }
            ),

            AutomationCommand(
                name: "restoreEntry",
                area: .library,
                summary: "Restores a soft-deleted entry.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Library entry ID"),
                ],
                handler: { args, ctx in
                    let id = try args.string("id")
                    ctx.model.restoreEntry(id)
                    return .object(["restored": .string(id)])
                }
            ),

            AutomationCommand(
                name: "purgeEntry",
                area: .library,
                summary: "Permanently removes a deleted entry.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Library entry ID"),
                ],
                handler: { args, ctx in
                    let id = try args.string("id")
                    ctx.model.purgeEntry(id)
                    return .object(["purged": .string(id)])
                }
            ),

            AutomationCommand(
                name: "listDeletedEntries",
                area: .library,
                summary: "Lists soft-deleted entries (trash).",
                kind: .sync,
                args: [
                    .init(name: "limit", kind: .integer, required: false, summary: "Max entries", defaultValue: .int(50)),
                ],
                handler: { args, ctx in
                    let limit = max(0, (try args.optionalInt("limit")) ?? 50)
                    return .array(ctx.model.deletedEntries.prefix(limit).map { e in
                        .object([
                            "id": .string(e.id),
                            "title": .string(e.title),
                            "category": .string(e.category.rawValue),
                            "createdAt": .double(e.createdAt.timeIntervalSince1970),
                            "deletedAt": .double(e.deletedAt?.timeIntervalSince1970 ?? 0),
                        ])
                    })
                }
            ),

            AutomationCommand(
                name: "summarizeLatestEntry",
                area: .library,
                summary: "Runs the summarise prompt on the most recent library entry.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.summarizeLatestEntry()
                    return .object(["started": .bool(true)])
                }
            ),
        ]
    }
}
