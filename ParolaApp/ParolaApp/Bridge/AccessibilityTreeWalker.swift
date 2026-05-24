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
        var state = WalkState(filter: filter, maxDepth: maxDepth, maxElements: maxElements)
        let root = makeNode(for: rootWindow, depth: 0, state: &state)
        return WalkResult(truncated: state.truncated, elementCount: state.elementCount, tree: root)
    }

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

    private func makeNode(for element: Any, depth: Int, state: inout WalkState) -> AXNode {
        state.elementCount += 1
        let role = readRole(from: element)
        let identifier = readIdentifier(from: element)
        let label = readLabel(from: element)
        let value = readValue(from: element)
        let frame = readFrame(from: element)
        let enabled = readEnabled(from: element)
        let selected = readSelected(from: element, role: role)
        let focused = readFocused(from: element)

        var children: [AXNode] = []
        if depth < state.maxDepth, !state.truncated {
            for child in readChildren(from: element) {
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
            identifier: identifier,
            role: role,
            label: label,
            value: value,
            frame: frame,
            enabled: enabled,
            selected: selected,
            focused: focused,
            children: children
        )
    }

    private func shouldKeep(_ node: AXNode, filter: Filter) -> Bool {
        switch filter {
        case .all:
            return true
        case .actionable:
            return Self.actionableRoles.contains(node.role)
        }
    }

    private func readChildren(from element: Any) -> [Any] {
        guard let obj = element as? NSObject else { return [] }
        let val = obj.value(forKey: "accessibilityChildren") as? [Any]
        return val ?? []
    }

    private func readIdentifier(from element: Any) -> String? {
        guard let obj = element as? NSObject else { return nil }
        let id = obj.value(forKey: "accessibilityIdentifier") as? String
        return (id?.isEmpty == false) ? id : nil
    }

    private func readRole(from element: Any) -> String {
        guard let obj = element as? NSObject else { return "" }
        return obj.value(forKey: "accessibilityRole") as? String ?? ""
    }

    private func readLabel(from element: Any) -> String? {
        guard let obj = element as? NSObject else { return nil }
        let label = obj.value(forKey: "accessibilityLabel") as? String
        return (label?.isEmpty == false) ? label : nil
    }

    private func readValue(from element: Any) -> String? {
        guard let obj = element as? NSObject else { return nil }
        let raw = obj.value(forKey: "accessibilityValue")
        switch raw {
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
        guard let obj = element as? NSObject else { return .zero }
        return (obj.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    }

    private func readEnabled(from element: Any) -> Bool {
        guard let obj = element as? NSObject else { return false }
        return (obj.value(forKey: "isAccessibilityEnabled") as? Bool) ?? false
    }

    private func readSelected(from element: Any, role: String) -> Bool? {
        guard Self.selectableRoles.contains(role) else { return nil }
        guard let obj = element as? NSObject else { return nil }
        return obj.value(forKey: "isAccessibilitySelected") as? Bool
    }

    private func readFocused(from element: Any) -> Bool? {
        guard let obj = element as? NSObject else { return nil }
        return obj.value(forKey: "isAccessibilityFocused") as? Bool
    }
}
