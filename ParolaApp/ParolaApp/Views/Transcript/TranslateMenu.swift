import SwiftUI
import ParolaCore

/// Transcript ▸ Translate To and Remove Translation. Its own view, so the transcript reads behind it don't rebuild the rest of the menu.
struct TranslateMenu: View {
    let model: AppModel

    var body: some View {
        let targets = TranslationTargets.offered(by: model)
        Menu("Translate To") {
            ForEach(targets, id: \.code) { target in
                Button(target.name) { Task { await model.translateTranscript(to: target.code) } }
            }
        }
        .disabled(!model.mainTranscriptCommandsEnabled || !model.canTranslateTranscript)
        .axLeaf("Menu.Transcript.TranslateTo")
        Button("Remove Translation") { Task { await model.removeTranslation() } }
            .disabled(!model.mainTranscriptCommandsEnabled || model.transcript?.translation == nil)
            .axLeaf("Menu.Transcript.RemoveTranslation")
    }
}
