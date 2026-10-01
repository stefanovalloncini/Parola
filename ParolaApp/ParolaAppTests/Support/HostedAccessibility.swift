import AppKit
import SwiftUI

/// A view ordered in far off screen, laid out twice around a run loop turn, so it is drawn as a window would draw it.
@MainActor
struct HostedWindow {
    let host: NSView
    let window: NSWindow

    init(_ view: some View, width: CGFloat = 1180, height: CGFloat = 760) {
        host = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// What SwiftUI hands VoiceOver in a hosted view; each walk raises an assistive app's flag and lowers it before it returns.
@MainActor
enum HostedAccessibility {
    struct Element {
        let object: NSObject
        let identifier: String?
        let label: String?
        let value: String?

        var words: [String] { [label, value].compactMap { $0 }.filter { !$0.isEmpty } }
    }

    static func elements(in root: NSObject) -> [Element] {
        withAssistiveApp { walk(root) }
    }

    static func words(in root: NSObject) -> [String] {
        elements(in: root).flatMap(\.words)
    }

    /// The press VoiceOver sends; false when no element ends with that identifier.
    @discardableResult
    static func press(endingWith identifier: String, in root: NSObject) -> Bool {
        withAssistiveApp {
            let press = NSSelectorFromString("accessibilityPerformPress")
            guard let element = walk(root).first(where: { $0.identifier?.hasSuffix(identifier) == true }),
                  element.object.responds(to: press) else { return false }
            _ = element.object.perform(press)
            return true
        }
    }

    private static func withAssistiveApp<T>(_ body: () -> T) -> T {
        setAssistiveApp(true)
        defer { setAssistiveApp(false) }
        return body()
    }

    /// The attribute has no typed setter, and the informal one is deprecated, so it goes by selector.
    private static func setAssistiveApp(_ on: Bool) {
        let set = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        _ = NSApp.perform(set, with: NSNumber(value: on), with: "AXEnhancedUserInterface" as NSString)
    }

    private static func walk(_ root: NSObject) -> [Element] {
        var found: [Element] = []
        func visit(_ node: NSObject, depth: Int) {
            guard depth < 60 else { return }
            for child in read("accessibilityChildren", of: node) as? [NSObject] ?? [] {
                found.append(Element(
                    object: child,
                    identifier: read("accessibilityIdentifier", of: child) as? String,
                    label: read("accessibilityLabel", of: child) as? String,
                    value: read("accessibilityValue", of: child) as? String
                ))
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return found
    }

    private static func read(_ key: String, of node: NSObject) -> Any? {
        node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
    }
}
