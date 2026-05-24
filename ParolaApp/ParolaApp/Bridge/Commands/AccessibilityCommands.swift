import Foundation
import AppKit
import ApplicationServices

extension ParolaAutomationServer {
    func accessibilityCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "getAccessibilityTree",
                area: .window,
                summary: "Walks the NSAccessibility tree of a window and returns a JSON representation.",
                kind: .sync,
                args: [
                    .init(
                        name: "windowID",
                        kind: .any,
                        required: false,
                        summary: "\"main\" for the primary visible window, or an integer NSWindow.windowNumber.",
                        defaultValue: .string("main")
                    ),
                    .init(
                        name: "filter",
                        kind: .string(enum: ["actionable", "all"]),
                        required: false,
                        summary: "actionable keeps interactive elements; all keeps everything.",
                        defaultValue: .string("actionable")
                    ),
                    .init(
                        name: "maxDepth",
                        kind: .integer,
                        required: false,
                        summary: "Maximum recursion depth.",
                        defaultValue: .int(12)
                    ),
                    .init(
                        name: "maxElements",
                        kind: .integer,
                        required: false,
                        summary: "Cap on total nodes walked; sets truncated when hit.",
                        defaultValue: .int(500)
                    ),
                ],
                handler: { args, _ in
                    let (window, resolvedID) = try resolveWindow(args.rawValue("windowID"))
                    let filter: AccessibilityTreeWalker.Filter
                    switch try args.optionalString("filter") ?? "actionable" {
                    case "all": filter = .all
                    default: filter = .actionable
                    }
                    let maxDepth = try args.optionalInt("maxDepth") ?? 12
                    let maxElements = try args.optionalInt("maxElements") ?? 500

                    let walker = AccessibilityTreeWalker()
                    let result = walker.walk(
                        rootWindow: window,
                        filter: filter,
                        maxDepth: maxDepth,
                        maxElements: maxElements
                    )
                    return .object([
                        "windowID": .string(resolvedID),
                        "truncated": .bool(result.truncated),
                        "elementCount": .int(result.elementCount),
                        "tree": walker.toAutomationValue(result.tree),
                    ])
                }
            ),

            AutomationCommand(
                name: "getAccessibilityHealth",
                area: .window,
                summary: "Reports whether the app is trusted for AX and hints at common issues.",
                kind: .sync,
                handler: { _, _ in
                    let trusted = AXIsProcessTrusted()
                    let hint: String
                    if trusted {
                        hint = "AX trusted; tree walks should reflect current UI."
                    } else {
                        hint = "AX not trusted. Grant Parola accessibility access in System Settings > Privacy & Security > Accessibility."
                    }
                    return .object([
                        "trusted": .bool(trusted),
                        "cacheLikelyStale": .bool(false),
                        "hint": .string(hint),
                    ])
                }
            ),
        ]
    }
}

@MainActor
private func resolveWindow(_ raw: AutomationValue?) throws -> (NSWindow, String) {
    let windows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && $0.contentView != nil }
    switch raw {
    case nil, .null, .string("main"):
        guard let win = windows.first(where: { $0.frame.size.width > 600 }) ?? windows.first else {
            throw AutomationError.precondition("no visible main window")
        }
        return (win, "main")
    case .string(let s):
        if let n = Int(s) { return try findByNumber(n, in: windows) }
        throw AutomationError.invalidArgs(field: "windowID", reason: "must be \"main\" or a window number")
    case .int(let n):
        return try findByNumber(n, in: windows)
    case .double(let d) where d.rounded() == d:
        return try findByNumber(Int(d), in: windows)
    default:
        throw AutomationError.invalidArgs(field: "windowID", reason: "must be \"main\" or a window number")
    }
}

@MainActor
private func findByNumber(_ number: Int, in windows: [NSWindow]) throws -> (NSWindow, String) {
    guard let win = windows.first(where: { $0.windowNumber == number }) else {
        throw AutomationError.notFound(kind: "window", id: String(number))
    }
    return (win, String(number))
}
