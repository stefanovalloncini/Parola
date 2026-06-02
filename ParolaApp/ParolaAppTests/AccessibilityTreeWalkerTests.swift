import Foundation
import AppKit
import Testing
@testable import Parola

@MainActor
@Suite("AccessibilityTreeWalker.walk is crash-safe")
struct AccessibilityTreeWalkerWalkTests {

    /// A synthetic AX element whose children can form a cycle or hold non-AX junk — the shapes a
    /// SwiftUI AX proxy tree can present that crashed the bridge.
    final class FakeAXElement: NSAccessibilityElement {
        private let role: NSAccessibility.Role
        private var kids: [Any] = []

        init(role: NSAccessibility.Role = .group) {
            self.role = role
            super.init()
        }

        func setKids(_ kids: [Any]) { self.kids = kids }

        override func accessibilityRole() -> NSAccessibility.Role? { role }
        override func accessibilityChildren() -> [Any]? { kids }
        override func accessibilityFrame() -> NSRect { .zero }
        override func isAccessibilityEnabled() -> Bool { true }
    }

    @Test("a self-referential element terminates instead of recursing forever")
    func cycleTerminates() {
        let node = FakeAXElement()
        node.setKids([node])

        let result = AccessibilityTreeWalker().walk(rootElement: node, filter: .all, maxDepth: 12, maxElements: 500)

        #expect(result.elementCount <= 500)
        #expect(result.tree.role == NSAccessibility.Role.group.rawValue)
    }

    @Test("a two-node cycle is bounded by the depth cap")
    func mutualCycleBounded() {
        let a = FakeAXElement(role: .group)
        let b = FakeAXElement(role: .group)
        a.setKids([b])
        b.setKids([a])

        let result = AccessibilityTreeWalker().walk(rootElement: a, filter: .all, maxDepth: 6, maxElements: 1000)

        #expect(result.elementCount <= 1000)
    }

    @Test("non-accessibility children are skipped without crashing")
    func nonAXChildrenSkipped() {
        let root = FakeAXElement(role: .group)
        root.setKids(["a plain string", 42, NSObject()])

        let result = AccessibilityTreeWalker().walk(rootElement: root, filter: .all, maxDepth: 12, maxElements: 500)

        #expect(result.tree.role == NSAccessibility.Role.group.rawValue)
        #expect(result.elementCount >= 1)
    }

    @Test("a deep chain is cut off at the clamped hard depth cap")
    func depthCapClamped() {
        var chain: [FakeAXElement] = []
        for _ in 0..<60 { chain.append(FakeAXElement(role: .group)) }
        for i in 0..<(chain.count - 1) { chain[i].setKids([chain[i + 1]]) }

        let result = AccessibilityTreeWalker().walk(
            rootElement: chain[0], filter: .all, maxDepth: 1_000_000, maxElements: 5000
        )

        func depth(_ node: AccessibilityTreeWalker.AXNode) -> Int {
            1 + (node.children.map(depth).max() ?? 0)
        }
        #expect(depth(result.tree) <= 41)
    }

    @Test("a non-accessibility root yields an empty node rather than crashing")
    func nonAXRootIsSafe() {
        let result = AccessibilityTreeWalker().walk(rootElement: NSObject(), filter: .all)
        #expect(result.tree.role == "")
        #expect(result.tree.children.isEmpty)
    }
}

@MainActor
@Suite("AccessibilityTreeWalker.toAutomationValue")
struct AccessibilityTreeWalkerTests {

    private func node(
        identifier: String? = nil,
        role: String,
        label: String? = nil,
        value: String? = nil,
        frame: CGRect = .zero,
        enabled: Bool = true,
        selected: Bool? = nil,
        focused: Bool? = nil,
        children: [AccessibilityTreeWalker.AXNode] = []
    ) -> AccessibilityTreeWalker.AXNode {
        AccessibilityTreeWalker.AXNode(
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

    private func object(_ value: AutomationValue) throws -> [String: AutomationValue] {
        guard case .object(let dict) = value else {
            Issue.record("expected .object, got \(value)")
            throw CancellationError()
        }
        return dict
    }

    @Test("always emits role, frame, enabled and children")
    func requiredKeys() throws {
        let dict = try object(AccessibilityTreeWalker().toAutomationValue(node(role: "AXGroup")))
        #expect(dict["role"] == .string("AXGroup"))
        #expect(dict["enabled"] == .bool(true))
        #expect(dict["children"] == .array([]))
        #expect(dict["frame"] != nil)
    }

    @Test("frame is emitted as origin x, origin y, width, height in that order")
    func frameOrder() throws {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        let dict = try object(AccessibilityTreeWalker().toAutomationValue(node(role: "AXButton", frame: frame)))
        #expect(dict["frame"] == .array([.double(10), .double(20), .double(100), .double(40)]))
    }

    @Test("optional string fields are dropped when nil or empty")
    func omitsEmptyOptionals() throws {
        let dict = try object(AccessibilityTreeWalker().toAutomationValue(
            node(identifier: "", role: "AXButton", label: "", value: nil)
        ))
        #expect(dict["id"] == nil)
        #expect(dict["label"] == nil)
        #expect(dict["value"] == nil)
        #expect(dict["selected"] == nil)
        #expect(dict["focused"] == nil)
    }

    @Test("populated identifier, label and value are carried through")
    func carriesStrings() throws {
        let dict = try object(AccessibilityTreeWalker().toAutomationValue(
            node(identifier: "save-button", role: "AXButton", label: "Save", value: "ready")
        ))
        #expect(dict["id"] == .string("save-button"))
        #expect(dict["label"] == .string("Save"))
        #expect(dict["value"] == .string("ready"))
    }

    @Test("selected and focused are emitted only when present")
    func selectedAndFocused() throws {
        let on = try object(AccessibilityTreeWalker().toAutomationValue(
            node(role: "AXRow", selected: true, focused: false)
        ))
        #expect(on["selected"] == .bool(true))
        #expect(on["focused"] == .bool(false))

        let off = try object(AccessibilityTreeWalker().toAutomationValue(
            node(role: "AXRow", selected: nil, focused: nil)
        ))
        #expect(off["selected"] == nil)
        #expect(off["focused"] == nil)
    }

    @Test("enabled false is preserved")
    func disabledNode() throws {
        let dict = try object(AccessibilityTreeWalker().toAutomationValue(
            node(role: "AXButton", enabled: false)
        ))
        #expect(dict["enabled"] == .bool(false))
    }

    @Test("children are serialized recursively in order")
    func recursiveChildren() throws {
        let tree = node(role: "AXWindow", children: [
            node(identifier: "a", role: "AXButton", label: "A"),
            node(role: "AXGroup", children: [
                node(identifier: "b", role: "AXTextField", value: "hi"),
            ]),
        ])
        let dict = try object(AccessibilityTreeWalker().toAutomationValue(tree))

        guard case .array(let children) = dict["children"] else {
            Issue.record("expected children array")
            return
        }
        #expect(children.count == 2)

        let first = try object(children[0])
        #expect(first["id"] == .string("a"))
        #expect(first["label"] == .string("A"))

        let second = try object(children[1])
        #expect(second["role"] == .string("AXGroup"))
        guard case .array(let grandchildren) = second["children"] else {
            Issue.record("expected grandchildren array")
            return
        }
        let leaf = try object(grandchildren[0])
        #expect(leaf["id"] == .string("b"))
        #expect(leaf["value"] == .string("hi"))
        #expect(leaf["children"] == .array([]))
    }
}
