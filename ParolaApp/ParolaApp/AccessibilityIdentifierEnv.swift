import SwiftUI

private struct AccessibilityIdentifierPathKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    var accessibilityIdentifierPath: [String] {
        get { self[AccessibilityIdentifierPathKey.self] }
        set { self[AccessibilityIdentifierPathKey.self] = newValue }
    }
}

struct AccessibilityIdentifierBranch: ViewModifier {
    let segment: String
    @Environment(\.accessibilityIdentifierPath) private var parentPath
    func body(content: Content) -> some View {
        content.environment(\.accessibilityIdentifierPath, parentPath + [segment])
    }
}

struct AccessibilityIdentifierLeaf: ViewModifier {
    let segment: String
    @Environment(\.accessibilityIdentifierPath) private var parentPath
    func body(content: Content) -> some View {
        content.accessibilityIdentifier((parentPath + [segment]).joined(separator: "."))
    }
}

extension View {
    func axBranch(_ segment: String) -> some View { modifier(AccessibilityIdentifierBranch(segment: segment)) }
    func axLeaf(_ segment: String) -> some View { modifier(AccessibilityIdentifierLeaf(segment: segment)) }
}
