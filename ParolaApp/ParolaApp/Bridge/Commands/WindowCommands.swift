import Foundation
import AppKit

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
                name: "openYouTubeSheet",
                area: .window,
                summary: "Opens the YouTube URL sheet.",
                kind: .mutating,
                handler: { _, ctx in
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
                summary: "Fetches subtitles for a YouTube URL without transcribing.",
                kind: .mutating,
                args: [
                    .init(name: "url", kind: .string(), required: true, summary: "YouTube URL"),
                ],
                handler: { args, ctx in
                    let url = try args.string("url")
                    ctx.model.fetchYouTubeSubs(urlString: url)
                    return .object(["started": .bool(true)])
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
