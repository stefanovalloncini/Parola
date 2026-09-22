import Foundation
import ParolaCore

extension ParolaAutomationServer {
    func libraryCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "listEntries",
                area: .library,
                summary: "Lists library entries, optionally filtered by category. Each entry carries id, title (as stored), displayTitle (as the rows show it), category, createdAt, durationSeconds, language, modelName, aiTitle and shortSummary.",
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
                            "displayTitle": .string(LibraryEntryDisplay.title(for: entry)),
                            "category": .string(entry.category.rawValue),
                            "createdAt": .double(entry.createdAt.timeIntervalSince1970),
                            "durationSeconds": entry.durationSeconds.map { .double($0) } ?? .null,
                            "language": .string(entry.language),
                            "modelName": .string(entry.modelName),
                            "aiTitle": entry.aiTitle.map { .string($0) } ?? .null,
                            "shortSummary": entry.shortSummary.map { .string($0) } ?? .null,
                        ])
                    })
                }
            ),

            AutomationCommand(
                name: "generateCardMetadata",
                area: .library,
                summary: "Writes the on-device title and one-line summary for an entry. Needs the AI feature and the generation toggle; use installMockLanguageModel in tests.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Library entry ID"),
                ],
                handler: { args, ctx in
                    let id = try args.string("id")
                    guard ctx.model.features.isEnabled(.ai) else {
                        return .object(["generated": .bool(false), "reason": .string("the AI feature is off")])
                    }
                    guard ctx.model.generatesCardMetadata else {
                        return .object(["generated": .bool(false), "reason": .string("card metadata generation is off")])
                    }
                    let loaded = try await ctx.model.library.load(id)
                    guard let meta = await ctx.model.generateCardMetadata(for: id, transcript: loaded.document.transcript) else {
                        return .object(["generated": .bool(false), "reason": .string("generation failed or the transcript was too short")])
                    }
                    return .object([
                        "generated": .bool(true),
                        "aiTitle": .string(meta.title),
                        "shortSummary": .string(meta.summary),
                    ])
                }
            ),

            AutomationCommand(
                name: "loadEntry",
                area: .library,
                summary: "Opens a library entry the way a double-click does: into the main pane, or into its own window when the 'Always open transcripts in a new window' setting is on.",
                kind: .mutating,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "Library entry ID"),
                ],
                followsWith: ["waitForPhase"],
                handler: { args, ctx in
                    let id = try args.string("id")
                    ctx.model.openEntryFromLibrary(id, inNewWindow: false)
                    return .object([
                        "loaded": .string(id),
                        "inNewWindow": .bool(ctx.model.openEntriesInNewWindow),
                    ])
                }
            ),

            AutomationCommand(
                name: "retranscribeEntry",
                area: .library,
                summary: "Runs a library entry's own audio again into the same entry, the way the Info inspector's Model and Language menus do. Omitted arguments keep what the entry already carries; an empty language means Auto. Favorites, notes, summary, translation, the speaker map and the card metadata are replaced. Refused for an entry with no audio.",
                kind: .mutating,
                args: [
                    .init(name: "entryID", kind: .string(), required: true, summary: "Library entry ID"),
                    .init(name: "model", kind: .string(), required: false, summary: "Catalog model id to run instead"),
                    .init(name: "language", kind: .string(), required: false, summary: "Two-letter language code, or an empty string for Auto"),
                ],
                followsWith: ["waitForPhase"],
                handler: { args, ctx in
                    let id = try args.string("entryID")
                    guard let entry = ctx.model.libraryEntry(id: id) else {
                        throw AutomationError.invalidArgs(field: "entryID", reason: "no library entry with id \(id)")
                    }
                    if ctx.model.selectedEntryID != id {
                        ctx.model.loadEntry(id)
                        var waitedMs = 0
                        while ctx.model.selectedEntryID != id, waitedMs < 4_000 {
                            try? await Task.sleep(for: .milliseconds(25))
                            waitedMs += 25
                        }
                    }
                    guard ctx.model.selectedEntryID == id else {
                        throw AutomationError.precondition("entry \(id) could not be opened")
                    }
                    let modelName = (try args.optionalString("model")) ?? entry.modelName
                    // Read raw: optionalString folds "" into nil, and "" is how a caller asks for Auto.
                    let language: String?
                    if let requested = args.rawValue("language") {
                        if case .string(let code) = requested, !code.isEmpty { language = code } else { language = nil }
                    } else {
                        language = entry.language.isEmpty ? nil : entry.language
                    }
                    ctx.model.retranscribeCurrentEntry(model: modelName, language: language)
                    guard let request = ctx.model.retranscribeRequest else {
                        throw AutomationError.precondition(
                            ctx.model.retranscribeUnavailableReason ?? "a re-transcription is already running"
                        )
                    }
                    return .object([
                        "entryID": .string(request.entryID),
                        "model": .string(request.modelName),
                        "language": request.language.map { .string($0) } ?? .null,
                    ])
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
                name: "goHome",
                area: .library,
                summary: "Selects the sidebar Home row: clears the library filter and any search, and unloads any transcript.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.goHome()
                    return .object(["route": .string(ctx.model.route.rawValue)])
                }
            ),

            AutomationCommand(
                name: "goBack",
                area: .library,
                summary: "Follows the transcript header's back link: unloads the transcript and restores the list it was opened from.",
                kind: .mutating,
                handler: { _, ctx in
                    let origin = ctx.model.transcriptOrigin?.bridgeName ?? ""
                    ctx.model.returnToOrigin()
                    return .object([
                        "origin": .string(origin),
                        "route": .string(ctx.model.route.rawValue),
                        "libraryFilter": .string(ctx.model.libraryFilter?.rawValue ?? ""),
                        "libraryBrowsingAll": .bool(ctx.model.libraryBrowsingAll),
                    ])
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
                    // This command measures what the sidebar does, which never clears the results first; the version tells it when the query landed.
                    let baseline = ctx.model.searchResultsVersion
                    ctx.model.search(query)
                    let clock = ctx.model.clock
                    var waitedMs = 0
                    while ctx.model.searchResultsVersion == baseline, waitedMs < 2000 {
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
                name: "getDuplicateImport",
                area: .library,
                summary: "Reports the \"Already in your library\" sheet: whether it is open, which entry it matched, and how many files the last batch import skipped as duplicates.",
                kind: .sync,
                handler: { _, ctx in
                    let pending = ctx.model.duplicateImport
                    return .object([
                        "open": .bool(pending != nil),
                        "entryID": pending.map { .string($0.entryID) } ?? .null,
                        "entryTitle": pending.map { .string($0.entryTitle) } ?? .null,
                        "modelName": pending.map { .string($0.modelName) } ?? .null,
                        "createdAt": pending.map { .double($0.createdAt.timeIntervalSince1970) } ?? .null,
                        "durationSeconds": pending?.durationSeconds.map { .double($0) } ?? .null,
                        "file": pending.map { .string($0.fileURL.path) } ?? .null,
                        "batchDuplicatesSkipped": .int(ctx.model.batchDuplicatesSkipped),
                        "batchNotice": ctx.model.batchDuplicateNotice.map { .string($0) } ?? .null,
                    ])
                }
            ),

            AutomationCommand(
                name: "resolveDuplicateImport",
                area: .library,
                summary: "Presses one of the duplicate sheet's buttons: openExisting, transcribeAgain or dismiss. With remember: true the choice becomes the duplicateImportPolicy setting, the way the sheet's checkbox does.",
                kind: .mutating,
                args: [
                    .init(
                        name: "choice",
                        kind: .string(enum: ["openExisting", "transcribeAgain", "dismiss"]),
                        required: true,
                        summary: "Which button to press"
                    ),
                    .init(name: "remember", kind: .boolean, required: false, summary: "Tick \"Remember this choice\" before pressing", defaultValue: .bool(false)),
                ],
                followsWith: ["waitForPhase"],
                handler: { args, ctx in
                    guard ctx.model.duplicateImport != nil else {
                        throw AutomationError.invalidArgs(field: "choice", reason: "no duplicate sheet is open")
                    }
                    let choice = try args.string("choice")
                    let remember = (try args.optionalBool("remember")) ?? false
                    switch choice {
                    case "openExisting": ctx.model.openExistingDuplicate(remembering: remember)
                    case "transcribeAgain": ctx.model.transcribeDuplicateAgain(remembering: remember)
                    default: ctx.model.dismissDuplicateImport()
                    }
                    return .object([
                        "choice": .string(choice),
                        "duplicateImportPolicy": .string(ctx.model.duplicateImportPolicy.rawValue),
                    ])
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
                name: "setSegmentFavorite",
                area: .library,
                summary: "Sets whether a segment of the current transcript is a favorite.",
                kind: .mutating,
                args: [
                    .init(name: "segmentID", kind: .integer, required: true, summary: "Segment id within the current transcript"),
                    .init(name: "isFavorite", kind: .boolean, required: true, summary: "Favorite state to set"),
                ],
                handler: { args, ctx in
                    let segmentID = try args.int("segmentID")
                    let isFavorite = try args.bool("isFavorite")
                    guard let applied = try await ctx.model.setSegmentFavorite(segmentID, isFavorite: isFavorite) else {
                        return .object(["applied": .bool(false), "reason": .string("no entry selected")])
                    }
                    return .object([
                        "applied": .bool(true),
                        "segmentID": .int(segmentID),
                        "isFavorite": .bool(applied),
                    ])
                }
            ),

            AutomationCommand(
                name: "summarizeLatestEntry",
                area: .library,
                summary: "Runs the summarise prompt on the most recent library entry.",
                kind: .mutating,
                args: [
                    .init(name: "options", kind: .object, required: false, summary: "SummaryOptions fields to override, merged over the saved options"),
                ],
                handler: { args, ctx in
                    try ctx.require(.ai)
                    let options: SummaryOptions? = try args.contains("options")
                        ? ctx.model.mergedSummaryOptions(overriding: try args.object("options"))
                        : nil
                    ctx.model.summarizeLatestEntry(options: options)
                    return .object(["started": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "setSummaryOptions",
                area: .library,
                summary: "Merges the given fields over the saved summary options and persists the result.",
                kind: .mutating,
                args: [
                    .init(name: "options", kind: .object, required: true, summary: "SummaryOptions fields to merge over the saved options"),
                ],
                handler: { args, ctx in
                    let merged = try ctx.model.mergedSummaryOptions(overriding: try args.object("options"))
                    ctx.model.summaryOptions = merged
                    return .object(["summaryOptions": ParolaAutomationServer.encode(merged)])
                }
            ),

            AutomationCommand(
                name: "setTranscriptPaneMode",
                area: .library,
                summary: "Switches the transcript column between Transcript, Summary and Chat.",
                kind: .mutating,
                args: [
                    .init(
                        name: "mode",
                        kind: .string(enum: AppModel.TranscriptPaneMode.allCases.map(\.rawValue)),
                        required: true,
                        summary: "transcript, summary, or chat"
                    ),
                ],
                handler: { args, ctx in
                    let raw = try args.string("mode")
                    guard let mode = AppModel.TranscriptPaneMode(rawValue: raw) else {
                        throw AutomationError.invalidArgs(field: "mode", reason: "unknown mode: \(raw)")
                    }
                    ctx.model.setTranscriptPaneMode(mode)
                    return .object(["mode": .string(ctx.model.transcriptPaneMode.rawValue)])
                }
            ),
        ]
    }
}
