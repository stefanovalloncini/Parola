import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            MacLibrarySidebar()
        } detail: {
            ContentRoutes()
                .toolbar { ContentToolbar() }
                .modifier(HideToolbarTitleIfAvailable())
        }
        .contentSheets()
    }
}
