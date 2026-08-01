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

            AutomationCommand(
                name: "clickElement",
                area: .window,
                summary: "Presses the control whose accessibility identifier matches (e.g. Customization.Button.Theme.blue). Needs Accessibility; uses the out-of-process AX server so it can reach SwiftUI controls.",
                kind: .async,
                args: [
                    .init(name: "id", kind: .string(), required: true, summary: "accessibilityIdentifier of the control"),
                ],
                handler: { args, _ in
                    let id = try args.string("id")
                    try requireAXTrust()
                    return try await onAXThread {
                        guard let element = axFind(in: appAXElement(), identifier: id, depth: 0) else {
                            throw AutomationError.notFound(kind: "element", id: id)
                        }
                        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                        guard result == .success else {
                            throw AutomationError.precondition("press failed (AXError \(result.rawValue)) for \(id)")
                        }
                        return .object(["pressed": .bool(true), "id": .string(id)])
                    }
                }
            ),

            AutomationCommand(
                name: "listClickable",
                area: .window,
                summary: "Lists every control that has an accessibility identifier (id, role, label, enabled), via the out-of-process AX server. Needs Accessibility. Use the ids with clickElement.",
                kind: .async,
                handler: { _, _ in
                    try requireAXTrust()
                    return try await onAXThread {
                        var found: [AutomationValue] = []
                        axCollectIdentified(appAXElement(), into: &found, depth: 0)
                        return .array(found)
                    }
                }
            ),
        ]
    }
}

@MainActor
private func requireAXTrust() throws {
    guard AXIsProcessTrusted() else {
        throw AutomationError.permission("needs Accessibility. Grant Parola in System Settings > Privacy & Security > Accessibility.")
    }
}

/// Same-process AX is answered inline on the calling thread, so SwiftUI evaluates its nodes here and only main is legal.
/// A press that opens a modal holds main until the modal closes, so it comes back as `timeout` even though it landed.
private func onAXThread(_ work: @escaping @MainActor @Sendable () throws -> AutomationValue) async throws -> AutomationValue {
    try await onMainThread(deadlineSeconds: 5, work)
}

/// Runs `work` on the main thread and fails the call once the deadline passes, so a wedged main
/// thread can't park a bridge command forever.
func onMainThread<T: Sendable>(
    deadlineSeconds: Double,
    _ work: @escaping @MainActor @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let winner = FirstResume()
        let watchdog = DispatchWorkItem {
            if winner.claim() {
                continuation.resume(throwing: AutomationError.timeout("main thread did not answer within \(deadlineSeconds)s"))
            }
        }
        winner.arm(watchdog)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let result = Result { try work() }
                if winner.claim() { continuation.resume(with: result) }
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadlineSeconds, execute: watchdog)
    }
}

// @unchecked is safe: both fields are guarded by the lock.
private final class FirstResume: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    private var watchdog: DispatchWorkItem?

    func arm(_ item: DispatchWorkItem) {
        lock.lock()
        defer { lock.unlock() }
        watchdog = item
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        watchdog?.cancel()
        watchdog = nil
        return true
    }
}

private func appAXElement() -> AXUIElement {
    AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    func array(_ attr: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
    return array(kAXChildrenAttribute as String) + array(kAXWindowsAttribute as String)
}

private func axString(_ element: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
    let s = value as? String
    return (s?.isEmpty == false) ? s : nil
}

private func axFind(in element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
    if depth > 80 { return nil }
    if axString(element, kAXIdentifierAttribute as String) == identifier { return element }
    for child in axChildren(element) {
        if let hit = axFind(in: child, identifier: identifier, depth: depth + 1) { return hit }
    }
    return nil
}

private func axCollectIdentified(_ element: AXUIElement, into found: inout [AutomationValue], depth: Int) {
    if depth > 80 || found.count >= 600 { return }
    if let id = axString(element, kAXIdentifierAttribute as String) {
        var node: [String: AutomationValue] = ["id": .string(id)]
        if let role = axString(element, kAXRoleAttribute as String) { node["role"] = .string(role) }
        if let label = axString(element, kAXTitleAttribute as String) ?? axString(element, kAXDescriptionAttribute as String) {
            node["label"] = .string(label)
        }
        found.append(.object(node))
    }
    for child in axChildren(element) {
        axCollectIdentified(child, into: &found, depth: depth + 1)
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
