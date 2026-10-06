import SwiftUI
import ParolaCore

/// Transcript ▸ Transcribe Again. Its own view, so the transcript and library reads behind it don't rebuild the rest of the menu.
struct TranscribeAgainMenu: View {
    let model: AppModel

    var body: some View {
        let variants = model.transcribeAgainModels
        Menu("Transcribe Again") {
            Button("Same Model and Language") { model.askToTranscribeAgain() }
                .axLeaf("Menu.Transcript.TranscribeAgainSame")
            Divider()
            TranscribeAgainModelChoices(model: model, variants: variants)
            Divider()
            Menu("Language") {
                TranscribeAgainLanguageChoices(model: model, variants: variants)
            }
        }
        .disabled(!model.mainTranscriptCommandsEnabled || !model.canTranscribeAgain)
        .axLeaf("Menu.Transcript.TranscribeAgain")
    }
}

/// The installed models, the transcript's own one checked; picking another asks to run it.
struct TranscribeAgainModelChoices: View {
    let model: AppModel
    let variants: [ModelVariant]

    var body: some View {
        ForEach(variants, id: \.id) { variant in
            TranscribeAgainChoice(
                title: "\(variant.displayName) — \(variant.engineID.displayName)",
                isCurrent: variant.id == model.transcript?.modelName,
                isAllowed: true
            ) {
                model.askToTranscribeAgain(model: variant.id, label: variant.displayName)
            }
        }
    }
}

/// Auto, then every language, the transcript's own one checked and the ones the run's model refuses shut.
struct TranscribeAgainLanguageChoices: View {
    let model: AppModel
    let variants: [ModelVariant]

    var body: some View {
        let scope = model.transcribeAgainLanguages(among: variants)
        let current = model.transcriptLanguageCode
        TranscribeAgainChoice(title: LanguagePickerPopover.autoLabel, isCurrent: current == nil, isAllowed: true) {
            model.askToTranscribeAgain(language: nil, label: LanguagePickerPopover.autoLabel)
        }
        Divider()
        ForEach(SupportedLanguages.codes, id: \.self) { code in
            let name = SupportedLanguages.displayName(for: code)
            TranscribeAgainChoice(title: name, isCurrent: code == current, isAllowed: scope.allows(code)) {
                model.askToTranscribeAgain(language: code, label: name)
            }
        }
    }
}

private struct TranscribeAgainChoice: View {
    let title: String
    let isCurrent: Bool
    let isAllowed: Bool
    let action: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isCurrent }, set: { _ in action() })) {
            Text(verbatim: title)
        }
        .disabled(!isAllowed)
    }
}
