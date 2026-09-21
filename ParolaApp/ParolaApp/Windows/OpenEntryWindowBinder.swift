import SwiftUI
import ParolaCore

/// Hands the scene's `openWindow` to the model. `openWindow` only exists inside scene content, and
/// the menu, the library rows and the bridge all open windows through the model.
private struct OpenEntryWindowBinder: ViewModifier {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.bindOpenEntryWindow { entryID in
                openWindow(id: EntryWindowScene.id, value: entryID)
            }
        }
    }
}

enum EntryWindowScene {
    static let id = "transcript"
}

extension View {
    func bindsEntryWindowOpening(to model: AppModel) -> some View {
        modifier(OpenEntryWindowBinder(model: model))
    }
}
