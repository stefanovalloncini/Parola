import SwiftUI
import ParolaCore

/// A translation on its way, or one that failed, above the text it is for. Transcript ▸ Translate To starts and removes one.
struct TranslationStrip: View {
    @Environment(AppModel.self) private var model
    @State private var targets: [String] = SupportedLanguages.codes
    @State private var menuTargets: [(code: String, name: String)] = []

    static func shows(_ state: TranslationState) -> Bool {
        if case .idle = state { return false }
        return true
    }

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            switch model.translationState {
            case .preparing:
                progressRow(completed: nil, total: nil)
            case .translating(let completed, let total):
                progressRow(completed: completed, total: total)
            case .failed(let message):
                failureRow(message)
            case .idle:
                EmptyView()
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .task {
            targets = await model.translationCoordinator.supportedTargets()
            rebuildMenuTargets()
        }
        .accessibilityElement(children: .contain)
        .axLeaf("Strip.Translation")
    }

    @ViewBuilder
    private func progressRow(completed: Int?, total: Int?) -> some View {
        Image(systemName: "translate")
            .foregroundStyle(DS.Color.secondaryText)
            .accessibilityHidden(true)
        Text(progressLabel(completed: completed, total: total))
            .font(DS.Font.secondary)
            .monospacedDigit()
            .foregroundStyle(DS.Color.secondaryText)
        DSProgressBar(value: fraction(completed: completed, total: total))
            .frame(maxWidth: 160)
        Spacer()
        Button("Cancel") { model.cancelTranslation() }
            .axLeaf("Translation.Button.Cancel")
    }

    @ViewBuilder
    private func failureRow(_ message: String) -> some View {
        AIStatusNote(message: message, kind: .failure)
        Spacer()
        Button("Retry") { retry() }
            .disabled(model.translationCoordinator.activeTarget == nil)
            .axLeaf("Translation.Button.Retry")
        // A run that failed part way still wrote what it got; it has to be removable from here.
        if model.transcript?.translation != nil {
            Button("Remove translation") { Task { await model.removeTranslation() } }
                .axLeaf("Translation.Button.Remove")
        }
        Menu("Translate to…") {
            ForEach(menuTargets, id: \.code) { target in
                Button(target.name) { translate(to: target.code) }
                    .axLeaf("Translation.MenuItem.Target.\(target.code)")
            }
        }
        .fixedSize()
        .disabled(!model.canTranslateTranscript || menuTargets.isEmpty)
        .axLeaf("Translation.Menu.TranslateTo")
        Button { model.dismissTranslationFailure() } label: {
            Image(systemName: "xmark")
                .font(DS.Font.caption)
        }
        .buttonStyle(GlyphButtonStyle(side: 20))
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
        .axLeaf("Translation.Button.Dismiss")
    }

    private func rebuildMenuTargets() {
        menuTargets = TranslationTargets.named(from: targets, excluding: model.transcript?.language)
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

@MainActor
enum TranslationTargets {
    /// Every target but the transcript's own language, by name; the strip, the Details row and Transcript ▸ Translate To share it.
    static func named(from codes: [String], excluding language: String?) -> [(code: String, name: String)] {
        let source = language.flatMap { TranslationCoordinator.sourceLanguage(for: $0) }
        return codes
            .filter { $0 != source }
            .map { (code: $0, name: SupportedLanguages.displayName(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
