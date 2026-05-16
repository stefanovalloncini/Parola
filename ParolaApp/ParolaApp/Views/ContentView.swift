import SwiftUI

struct ContentView: View {
    @State private var showingTrash = false

    var body: some View {
        NavigationSplitView {
            MacLibrarySidebar()
        } detail: {
            ContentRoutes()
                .toolbar { ContentToolbar(showingTrash: $showingTrash) }
                .modifier(HideToolbarTitleIfAvailable())
        }
        .contentSheets(showingTrash: $showingTrash)
    }
}
