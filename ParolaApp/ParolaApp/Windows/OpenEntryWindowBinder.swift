import SwiftUI
import ParolaCore

/// Hands the scene's `openWindow` to the model: it exists only inside scene content, and every opener goes through the model.
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
