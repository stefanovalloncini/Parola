import SwiftUI
import ParolaCore

struct TranslationSection: View {
    @Environment(AppModel.self) private var model
    @State private var targets: [String] = SupportedLanguages.codes

    var body: some View {
        InspectorSection(title: "Translation") {
            switch model.translationState {
            case .preparing:
                progressRow(completed: nil, total: nil)
            case .translating(let completed, let total):
                progressRow(completed: completed, total: total)
            case .failed(let message):
                failureRow(message)
            case .idle:
                if let translation = model.transcript?.translation {
                    translatedRows(translation)
                } else {
                    idleRows
                }
            }
        }
        .task { targets = await model.translationCoordinator.supportedTargets() }
    }

    private var idleRows: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            targetMenu(title: "Translate to…")
            Text("\(model.transcriptText.count) characters")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }
    }

    private func translatedRows(_ translation: TranscriptTranslation) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text("Translated to \(LanguageDisplay.name(for: translation.targetLanguage) ?? translation.targetLanguage)")
                .font(DS.Font.body)
            HStack(spacing: DS.Spacing.small) {
                Button("Remove translation") { Task { await model.removeTranslation() } }
                    .controlSize(.small)
                    .axLeaf("Translation.Button.Remove")
                Spacer()
                targetMenu(title: "Translate again")
            }
        }
    }

    private func progressRow(completed: Int?, total: Int?) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Text(progressLabel(completed: completed, total: total))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Button("Cancel") { model.cancelTranslation() }
                    .controlSize(.small)
                    .axLeaf("Translation.Button.Cancel")
            }
            DSProgressBar(value: fraction(completed: completed, total: total))
        }
    }

    private func failureRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            AIStatusNote(message: message, kind: .failure)
            HStack(spacing: DS.Spacing.small) {
                Button("Retry") { retry() }
                    .controlSize(.small)
                    .disabled(model.translationCoordinator.activeTarget == nil)
                    .axLeaf("Translation.Button.Retry")
                Spacer()
                targetMenu(title: "Translate to…")
            }
        }
    }

    private func targetMenu(title: LocalizedStringKey) -> some View {
        Menu(title) {
            ForEach(menuTargets, id: \.code) { target in
                Button(target.name) { translate(to: target.code) }
            }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(!model.canTranslateTranscript || menuTargets.isEmpty)
        .axLeaf("Translation.Menu.TranslateTo")
    }

    private var menuTargets: [(code: String, name: String)] {
        let source = model.transcript.flatMap { TranslationCoordinator.sourceLanguage(for: $0.language) }
        return targets
            .filter { $0 != source }
            .map { (code: $0, name: SupportedLanguages.displayName(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func progressLabel(completed: Int?, total: Int?) -> String {
        guard let completed, let total else { return String(localized: "Preparing the translation…") }
        return String(localized: "Translating \(completed) of \(total)…")
    }

    private func fraction(completed: Int?, total: Int?) -> Double? {
        guard let completed, let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    private func translate(to code: String) {
        Task { await model.translateTranscript(to: code) }
    }

    private func retry() {
        guard let target = model.translationCoordinator.activeTarget else { return }
        translate(to: target)
    }
}
