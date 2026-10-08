import AppKit
import SwiftUI

/// A window that keeps the frame it is given; AppKit otherwise pulls a titled one back onto a screen.
final class OffscreenWindow: NSWindow {
    static let origin = NSPoint(x: -12_000, y: -12_000)

    convenience init(width: CGFloat, height: CGFloat, styleMask: NSWindow.StyleMask) {
        self.init(
            contentRect: NSRect(origin: Self.origin, size: NSSize(width: width, height: height)),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        setFrameOrigin(Self.origin)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A view ordered in far off every screen, laid out twice around a run loop turn, so it is drawn as a window would draw it.
@MainActor
struct HostedWindow {
    let host: NSView
    let window: NSWindow

    /// With `toolbar`, a titled window that hands the view's `.toolbar` to AppKit, so its items are read from `window`.
    init(_ view: some View, width: CGFloat = 1180, height: CGFloat = 760, toolbar: Bool = false) {
        let hosting = NSHostingView(rootView: view)
        if toolbar { hosting.sceneBridgingOptions = [.toolbars] }
        host = hosting
        window = OffscreenWindow(
            width: width,
            height: height,
            styleMask: toolbar ? [.titled, .closable, .resizable] : [.borderless]
        )
        // A view's dismiss closes the window it sits in; ARC still holds it then.
        window.isReleasedWhenClosed = false
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

    /// The rows the hosted list has realised, laying it out first; 0 before a table is in.
    var rowCount: Int {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return table?.numberOfRows ?? 0
    }

    var table: NSTableView? {
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(table(in:)).first
        }
        return table(in: host)
    }

    /// The row whose content carries an element with this identifier.
    func row(identifiedBy identifier: String) -> Int? {
        guard let table else { return nil }
        return (0..<table.numberOfRows).first { row in
            guard let view = table.rowView(atRow: row, makeIfNecessary: true) else { return false }
            return HostedAccessibility.elements(in: view).contains { $0.identifier?.hasSuffix(identifier) == true }
        }
    }
}

extension HostedWindow {
    enum Key {
        case escape
        case `return`

        var code: UInt16 { self == .escape ? 53 : 36 }
        var characters: String { self == .escape ? "\u{1b}" : "\r" }
    }

    /// The key as the window offers it to its views before anything else; true when a keyboard shortcut took it.
    @discardableResult
    func press(_ key: Key) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
            isARepeat: false, keyCode: key.code
        )
        guard let event else { return false }
        let taken = window.performKeyEquivalent(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return taken
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
        /// Its title, or the label of the element that titles it, the way a settings row's text names its switch.
        let title: String?
        let role: String?
        /// In screen coordinates.
        let frame: CGRect
        /// The named actions VoiceOver lists in its Actions rotor.
        let actions: [String]
        /// Whether VoiceOver reads it as the chosen one.
        let isSelected: Bool
        /// False for a control VoiceOver reads as dimmed.
        let isEnabled: Bool
        /// The grey hint an empty text field shows.
        let placeholder: String?

        var words: [String] { [label, value].compactMap { $0 }.filter { !$0.isEmpty } }
        /// What VoiceOver calls the element: its label, or else its title element's.
        var name: String? { [label, title].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } }
    }

    static func elements(in root: NSObject) -> [Element] {
        withAssistiveApp { walk(root) }
    }

    /// Only the controls AppKit draws for SwiftUI, which answer with no assistive app asking: a bordered menu, a picker.
    static func appKitElements(in root: NSObject) -> [Element] {
        walk(root)
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

    /// Views are entered through their subviews too: a list's row elements don't hand over the cells hosting each row.
    private static func walk(_ root: NSObject) -> [Element] {
        var found: [Element] = []
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        func visit(_ node: NSObject, depth: Int) {
            guard depth < 80 else { return }
            let children = (read("accessibilityChildren", of: node) as? [NSObject] ?? [])
                + ((node as? NSView)?.subviews ?? [])
            for child in children where seen.insert(ObjectIdentifier(child)).inserted {
                found.append(Element(
                    object: child,
                    identifier: read("accessibilityIdentifier", of: child) as? String,
                    label: read("accessibilityLabel", of: child) as? String,
                    value: read("accessibilityValue", of: child) as? String,
                    title: (read("accessibilityTitle", of: child) as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (read("accessibilityTitleUIElement", of: child) as? NSObject).flatMap {
                            (read("accessibilityLabel", of: $0) as? String) ?? (read("accessibilityValue", of: $0) as? String)
                        },
                    role: (read("accessibilityRole", of: child) as? NSAccessibility.Role)?.rawValue
                        ?? read("accessibilityRole", of: child) as? String,
                    frame: (read("accessibilityFrame", of: child) as? NSValue)?.rectValue ?? .zero,
                    actions: (read("accessibilityCustomActions", of: child) as? [NSAccessibilityCustomAction])?.map(\.name) ?? [],
                    isSelected: (read("isAccessibilitySelected", of: child) as? Bool) ?? false,
                    isEnabled: (read("isAccessibilityEnabled", of: child) as? Bool) ?? true,
                    placeholder: read("accessibilityPlaceholderValue", of: child) as? String
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
