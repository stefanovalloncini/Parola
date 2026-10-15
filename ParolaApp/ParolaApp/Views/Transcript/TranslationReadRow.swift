import SwiftUI
import ParolaCore

/// Where a finished translation can be read out: the language it is in, and a button that starts, pauses or resumes its reading.
struct TranslationReadRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let target = model.transcript?.translation?.targetLanguage {
            let status = ReadAloudButtonStatus.resolve(
                state: model.readAloud.state,
                readsThis: model.readAloud.reads(
                    entryID: model.selectedEntryID ?? AppModel.unsavedReadingID, source: .translation(language: target)
                ),
                blocked: model.readingBlockedReason,
                hasContent: true
            )
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: "translate")
                    .foregroundStyle(DS.Color.secondaryText)
                    .accessibilityHidden(true)
                Text("Translated to \(LanguageDisplay.name(for: target) ?? target)")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Button {
                    perform(status.action)
                } label: {
                    Label(LocalizedStringKey(status.titleKey), systemImage: status.symbol)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(GlyphButtonStyle(side: 22))
                .disabled(!status.isEnabled)
                .help(status.blockedMessage.map { Text($0) } ?? Text(LocalizedStringKey(status.titleKey)))
                .axLeaf("Translation.Button.ReadAloud")
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .accessibilityElement(children: .contain)
            .axLeaf("Row.Translation")
        }
    }

    private func perform(_ action: ReadAloudButtonStatus.Action) {
        switch action {
        case .start: Task { await model.readAloud(ReadAloudRequest(kind: .translation)) }
        case .pause: Task { await model.pauseReading() }
        case .resume: Task { await model.resumeReading() }
        case .retry: Task { await model.retryReading() }
        case .none: break
        }
    }
}
