import SwiftUI
import Translation

/// Zero-sized carrier for `.translationTask`. The framework only hands out a `TranslationSession`
/// inside that modifier on a live view, so the coordinator asks for one by publishing a configuration
/// and gets it back here.
struct TranslationHostView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(model.translationCoordinator.sessionConfiguration) { session in
                await model.translationCoordinator.run(session: session)
            }
    }
}
