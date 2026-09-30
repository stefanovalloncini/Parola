import SwiftUI

/// A page's search field at the toolbar's end; Edit ▸ Search Library (⌥⌘F) puts the caret in whichever page shows one.
struct ToolbarSearch: ViewModifier {
    @Binding var text: String
    let prompt: LocalizedStringKey

    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: Text(prompt))
            .searchFocused($focused)
            .onChange(of: model.librarySearchFocusRequests) { _, _ in focused = true }
    }
}

extension View {
    func toolbarSearch(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        modifier(ToolbarSearch(text: text, prompt: prompt))
    }
}
