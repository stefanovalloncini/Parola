import SwiftUI
import ParolaCore

/// A take that landed on its own Stage, and the entry it became.
struct TakeSavedNotice: Equatable, Identifiable {
    let id = UUID()
    let entryID: LibraryEntry.ID
    let category: EntryCategory

    /// Long enough to reach for Summarize or Copy; the pointer resting on the toast holds it longer.
    static let lifetime: Duration = .seconds(5)
}

/// "Saved to Meetings" under the transcript a take just became, with Summarize and Copy; it goes a few seconds after its window shows it.
struct TakeSavedToast: View {
    @Environment(AppModel.self) private var model
    let notice: TakeSavedNotice

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.regular) {
            Image(systemName: "checkmark.circle.fill")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Palette.success)
                .accessibilityHidden(true)
            Text(verbatim: Self.message(category: notice.category))
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.small)
            if Self.offersSummary(model) {
                Button("Summarize") { model.summarizeSavedTake(notice.entryID) }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("TakeSaved.Button.Summarize")
            }
            Button("Copy") {
                Task { await model.copySavedTake(notice.entryID) }
            }
            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
            .help("Copy Transcript")
            .axLeaf("TakeSaved.Button.Copy")
            Button {
                model.dismissTakeSaved()
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .buttonStyle(GlyphButtonStyle(side: 20))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .axLeaf("TakeSaved.Button.Dismiss")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(DS.Palette.success.opacity(0.35), lineWidth: 1)
        )
        .padding(DS.Spacing.regular)
        .background(WindowShownReader { if $0 { model.takeSavedCameOnScreen() } }.id(notice.id))
        .onHover { model.holdTakeSaved($0) }
        .onDisappear { model.holdTakeSaved(false) }
        .axBranch("TakeSavedToast")
    }

    /// The library page the take went to, named as the sidebar names it.
    nonisolated static func message(category: EntryCategory, bundle: Bundle = .main) -> String {
        switch category {
        case .transcription: String(localized: "Saved to Transcriptions", bundle: bundle)
        case .meeting: String(localized: "Saved to Meetings", bundle: bundle)
        case .dictation: String(localized: "Saved to Dictations", bundle: bundle)
        }
    }

    /// Hidden while nothing can write a summary: the feature is off, or the model the summary runs on isn't ready.
    static func offersSummary(_ model: AppModel) -> Bool {
        model.features.isEnabled(.ai) && model.isAIAvailable(for: .summary)
    }
}
