import Foundation
import AppKit

enum WindowFrameRequest {
    static func resolve(current: CGRect, x: Double?, y: Double?, w: Double?, h: Double?) throws -> CGRect {
        CGRect(
            x: x ?? current.origin.x,
            y: y ?? current.origin.y,
            width: try extent(w, field: "w") ?? current.size.width,
            height: try extent(h, field: "h") ?? current.size.height
        )
    }

    private static func extent(_ value: Double?, field: String) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value > 0 else {
            throw AutomationError.invalidArgs(field: field, reason: "must be a positive number of points")
        }
        return value
    }
}

extension ParolaAutomationServer {
    func windowCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "listWindows",
                area: .window,
                summary: "Lists all visible NSWindows.",
                kind: .sync,
                handler: { _, _ in
                    .array(NSApp.windows.compactMap { win -> AutomationValue? in
                        guard win.isVisible else { return nil }
                        return .object([
                            "title": .string(win.title),
                            "windowNumber": .int(win.windowNumber),
                            "frame": .object([
                                "w": .int(Int(win.frame.size.width)),
                                "h": .int(Int(win.frame.size.height)),
                            ]),
                            "isKey": .bool(win.isKeyWindow),
                            "isMain": .bool(win.isMainWindow),
                        ])
                    })
                }
            ),

            AutomationCommand(
                name: "setWindowFrame",
                area: .window,
                summary: "Moves and resizes the main window. Omitted fields keep their current value, and the window's own minimum size still clamps the result, so the reply carries the frame that landed.",
                kind: .mutating,
                args: [
                    .init(name: "x", kind: .double, required: false, summary: "Left edge in screen points"),
                    .init(name: "y", kind: .double, required: false, summary: "Bottom edge in screen points"),
                    .init(name: "w", kind: .double, required: false, summary: "Width in points"),
                    .init(name: "h", kind: .double, required: false, summary: "Height in points"),
                ],
                handler: { args, _ in
                    guard let window = ParolaAutomationServer.mainAutomationWindow() else {
                        throw AutomationError.precondition("no visible main window to resize")
                    }
                    let target = try WindowFrameRequest.resolve(
                        current: window.frame,
                        x: args.optionalDouble("x"),
                        y: args.optionalDouble("y"),
                        w: args.optionalDouble("w"),
                        h: args.optionalDouble("h")
                    )
                    window.setFrame(target, display: true)
                    let applied = window.frame
                    return .object([
                        "x": .int(Int(applied.origin.x)),
                        "y": .int(Int(applied.origin.y)),
                        "w": .int(Int(applied.size.width)),
                        "h": .int(Int(applied.size.height)),
                    ])
                }
            ),

            AutomationCommand(
                name: "openYouTubeSheet",
                area: .window,
                summary: "Opens the YouTube URL sheet.",
                kind: .mutating,
                handler: { _, ctx in
                    try ctx.require(.youtube)
                    ctx.model.youtubeSheetOpen = true
                    return .object(["open": .bool(true)])
                }
            ),

            AutomationCommand(
                name: "closeYouTubeSheet",
                area: .window,
                summary: "Closes the YouTube URL sheet.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.youtubeSheetOpen = false
                    return .object(["open": .bool(false)])
                }
            ),

            AutomationCommand(
                name: "fetchYouTubeSubs",
                area: .window,
                summary: "Fetches subtitles for a YouTube URL without transcribing. Parks the link while a take or run is in flight.",
                kind: .mutating,
                args: [
                    .init(name: "url", kind: .string(), required: true, summary: "YouTube URL"),
                ],
                handler: { args, ctx in
                    try ctx.require(.youtube)
                    let url = try args.string("url")
                    let handoff = ctx.model.fetchYouTubeSubs(urlString: url)
                    return .object([
                        "started": .bool(handoff == .started),
                        "parked": .bool(handoff == .parked),
                    ])
                }
            ),

            AutomationCommand(
                name: "openRecentlyDeleted",
                area: .window,
                summary: "Routes the main window to the Recently Deleted page.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.openRecentlyDeleted()
                    return .object(["open": .bool(true), "route": .string(ctx.model.route.rawValue)])
                }
            ),

            AutomationCommand(
                name: "selectDeletedEntries",
                area: .window,
                summary: "Selects rows on the Recently Deleted page, the way a click would. No ids clears the selection.",
                kind: .mutating,
                args: [
                    .init(name: "ids", kind: .stringArray, required: false, summary: "Entry ids; omit to clear the selection"),
                ],
                handler: { args, ctx in
                    let requested = Set(try args.optionalStringArray("ids") ?? [])
                    let deleted = Set(ctx.model.deletedEntries.map(\.id))
                    ctx.model.recentlyDeletedSelection = requested.intersection(deleted)
                    return .object([
                        "selected": .int(ctx.model.recentlyDeletedSelection.count),
                        "ids": .array(ctx.model.recentlyDeletedSelection.sorted().map { .string($0) }),
                    ])
                }
            ),

            AutomationCommand(
                name: "closeRecentlyDeleted",
                area: .window,
                summary: "Leaves the Recently Deleted page for the route it was opened from.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.closeRecentlyDeleted()
                    return .object(["open": .bool(false), "route": .string(ctx.model.route.rawValue)])
                }
            ),

            AutomationCommand(
                name: "screenshot",
                area: .window,
                summary: "Captures the main window via ScreenCaptureKit and writes a PNG. Needs Screen Recording; if denied it errors with the windowNumber so a granted process can `screencapture -l<n>`.",
                kind: .async,
                args: [
                    .init(name: "path", kind: .string(), required: false, summary: "Bare filename inside the cache; default is timestamped"),
                ],
                handler: { args, ctx in
                    let requested = try args.optionalString("path")
                    return try await ctx.server.runScreenshot(requestedFileName: requested)
                }
            ),

            AutomationCommand(
                name: "revealCacheDirectory",
                area: .window,
                summary: "Reveals the Parola cache directory in Finder.",
                kind: .mutating,
                handler: { _, ctx in
                    ctx.model.revealCacheDirectory()
                    return .object(["revealed": .bool(true)])
                }
            ),
        ]
    }
}
