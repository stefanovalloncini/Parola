import Foundation
import AppKit

@MainActor
struct AccessibilityTreeWalker {
    enum Filter: Sendable {
        case actionable
        case all
    }

    struct WalkResult: Sendable {
        let truncated: Bool
        let elementCount: Int
        let tree: AXNode
    }

    struct AXNode: Sendable {
        var identifier: String?
        var role: String
        var label: String?
        var value: String?
        var frame: CGRect
        var enabled: Bool
        var selected: Bool?
        var focused: Bool?
        var children: [AXNode]
    }

    private static let actionableRoles: Set<String> = [
        NSAccessibility.Role.button.rawValue,
        NSAccessibility.Role.menuItem.rawValue,
        NSAccessibility.Role.textField.rawValue,
        NSAccessibility.Role.checkBox.rawValue,
        NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.comboBox.rawValue,
        NSAccessibility.Role.link.rawValue,
        NSAccessibility.Role.slider.rawValue,
        NSAccessibility.Role.toolbar.rawValue,
        NSAccessibility.Role.tabGroup.rawValue,
    ]

    private static let selectableRoles: Set<String> = [
        NSAccessibility.Role.row.rawValue,
        NSAccessibility.Role.cell.rawValue,
        NSAccessibility.Role.radioButton.rawValue,
        NSAccessibility.Role.tabGroup.rawValue,
        NSAccessibility.Role.menuItem.rawValue,
    ]

    func walk(
        rootWindow: NSWindow,
        filter: Filter = .actionable,
        maxDepth: Int = 12,
        maxElements: Int = 500
    ) -> WalkResult {
        walk(rootElement: rootWindow, filter: filter, maxDepth: maxDepth, maxElements: maxElements)
    }

    func walk(
        rootElement: Any,
        filter: Filter = .actionable,
        maxDepth: Int = 12,
        maxElements: Int = 500
    ) -> WalkResult {
        var state = WalkState(
            filter: filter,
            maxDepth: max(0, min(maxDepth, Self.hardDepthCap)),
            maxElements: max(1, min(maxElements, Self.hardElementCap))
        )
        let root = makeNode(for: rootElement, depth: 0, state: &state)
        return WalkResult(truncated: state.truncated, elementCount: state.elementCount, tree: root)
    }

    private static let hardDepthCap = 40
    private static let hardElementCap = 5000

    func toAutomationValue(_ node: AXNode) -> AutomationValue {
        var dict: [String: AutomationValue] = [
            "role": .string(node.role),
            "frame": .array([
                .double(Double(node.frame.origin.x)),
                .double(Double(node.frame.origin.y)),
                .double(Double(node.frame.size.width)),
                .double(Double(node.frame.size.height)),
            ]),
            "enabled": .bool(node.enabled),
            "children": .array(node.children.map { toAutomationValue($0) }),
        ]
        if let id = node.identifier, !id.isEmpty { dict["id"] = .string(id) }
        if let label = node.label, !label.isEmpty { dict["label"] = .string(label) }
        if let value = node.value, !value.isEmpty { dict["value"] = .string(value) }
        if let selected = node.selected { dict["selected"] = .bool(selected) }
        if let focused = node.focused { dict["focused"] = .bool(focused) }
        return .object(dict)
    }

    private struct WalkState {
        let filter: Filter
        let maxDepth: Int
        let maxElements: Int
        var elementCount: Int = 0
        var truncated: Bool = false
    }

    private struct Attributes {
        var identifier: String?
        var role: String = ""
        var label: String?
        var value: String?
        var frame: CGRect = .zero
        var enabled: Bool = false
        var selected: Bool?
        var focused: Bool?
    }

    private func makeNode(for element: Any, depth: Int, state: inout WalkState) -> AXNode {
        state.elementCount += 1

        var attrs = Attributes()
        _ = ParolaCatchingNSException {
            attrs.role = self.readRole(from: element)
            attrs.identifier = self.readIdentifier(from: element)
            attrs.label = self.readLabel(from: element)
            attrs.value = self.readValue(from: element)
            attrs.frame = self.readFrame(from: element)
            attrs.enabled = self.readEnabled(from: element)
            attrs.selected = self.readSelected(from: element, role: attrs.role)
            attrs.focused = self.readFocused(from: element)
        }

        var children: [AXNode] = []
        if depth < state.maxDepth, !state.truncated {
            for child in safeChildren(of: element) {
                if state.elementCount >= state.maxElements {
                    state.truncated = true
                    break
                }
                let childNode = makeNode(for: child, depth: depth + 1, state: &state)
                if shouldKeep(childNode, filter: state.filter) {
                    children.append(childNode)
                } else {
                    children.append(contentsOf: childNode.children)
                }
            }
        }

        return AXNode(
            identifier: attrs.identifier,
            role: attrs.role,
            label: attrs.label,
            value: attrs.value,
            frame: attrs.frame,
            enabled: attrs.enabled,
            selected: attrs.selected,
            focused: attrs.focused,
            children: children
        )
    }

    private func safeChildren(of element: Any) -> [Any] {
        var result: [Any] = []
        _ = ParolaCatchingNSException { result = self.readChildren(from: element) }
        return result
    }

    private func shouldKeep(_ node: AXNode, filter: Filter) -> Bool {
        switch filter {
        case .all:
            return true
        case .actionable:
            return Self.actionableRoles.contains(node.role)
        }
    }

    // Typed NSAccessibilityProtocol accessors, not KVC `value(forKey:)`. SwiftUI's AX proxy objects
    // are not reliably KVC-compliant for these keys, and a raised NSUnknownKeyException from KVC is an
    // Objective-C exception Swift can't catch — it crashes the process. The protocol methods are safe.
    private func readChildren(from element: Any) -> [Any] {
        guard let ax = element as? any NSAccessibilityProtocol else { return [] }
        return ax.accessibilityChildren() ?? []
    }

    private func readIdentifier(from element: Any) -> String? {
        guard let ax = element as? any NSAccessibilityProtocol else { return nil }
        let id = ax.accessibilityIdentifier()
        return (id?.isEmpty == false) ? id : nil
    }

    private func readRole(from element: Any) -> String {
        guard let ax = element as? any NSAccessibilityProtocol else { return "" }
        return ax.accessibilityRole()?.rawValue ?? ""
    }

    private func readLabel(from element: Any) -> String? {
        guard let ax = element as? any NSAccessibilityProtocol else { return nil }
        let label = ax.accessibilityLabel()
        return (label?.isEmpty == false) ? label : nil
    }

    private func readValue(from element: Any) -> String? {
        guard let ax = element as? any NSAccessibilityProtocol else { return nil }
        switch ax.accessibilityValue() {
        case let s as String:
            return s.isEmpty ? nil : s
        case let n as NSNumber:
            return n.stringValue
        case .some(let other):
            return String(describing: other)
        case nil:
            return nil
        }
    }

    private func readFrame(from element: Any) -> CGRect {
        guard let ax = element as? any NSAccessibilityProtocol else { return .zero }
        return ax.accessibilityFrame()
    }

    private func readEnabled(from element: Any) -> Bool {
        guard let ax = element as? any NSAccessibilityProtocol else { return false }
        return ax.isAccessibilityEnabled()
    }

    private func readSelected(from element: Any, role: String) -> Bool? {
        guard Self.selectableRoles.contains(role) else { return nil }
        guard let ax = element as? any NSAccessibilityProtocol else { return nil }
        return ax.isAccessibilitySelected()
    }

    private func readFocused(from element: Any) -> Bool? {
        guard let ax = element as? any NSAccessibilityProtocol else { return nil }
        return ax.isAccessibilityFocused()
    }
}
