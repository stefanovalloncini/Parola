import SwiftUI

extension AppModel.Route {
    /// The page's search field and Edit ▸ Search both use this name; Statistics and the Stage have nothing to search.
    func searchTitle(bundle: Bundle = .main) -> String? {
        switch self {
        case .transcript: String(localized: "Search Library", bundle: bundle)
        case .queue: String(localized: "Search Queue", bundle: bundle)
        case .batch: String(localized: "Search Batch", bundle: bundle)
        case .recentlyDeleted: String(localized: "Search Recently Deleted", bundle: bundle)
        case .statistics, .recording: nil
        }
    }
}

/// A page's search field at the toolbar's end; Edit ▸ Search (⌥⌘F) puts the caret in whichever page shows one.
struct ToolbarSearch: ViewModifier {
    @Binding var text: String
    let route: AppModel.Route

    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: Text(verbatim: route.searchTitle() ?? ""))
            .searchFocused($focused)
            .onChange(of: model.librarySearchFocusRequests) { _, _ in focused = true }
    }
}

extension View {
    func toolbarSearch(text: Binding<String>, for route: AppModel.Route) -> some View {
        modifier(ToolbarSearch(text: text, route: route))
    }
}
