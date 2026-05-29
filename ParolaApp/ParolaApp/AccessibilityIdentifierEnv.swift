import SwiftUI

extension EnvironmentValues {
    @Entry var accessibilityIdentifierPath: [String] = []
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
