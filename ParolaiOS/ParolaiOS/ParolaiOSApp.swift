import SwiftUI

@main
struct ParolaiOSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in model.openFile(at: url) }
        }
    }
}
