import SwiftUI
import ParolaCore

struct EntryViewerInfo: View {
    let session: EntryWindowSession
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                InspectorSection(title: "Properties") {
                    InfoRow(icon: "clock", label: "Audio duration", value: durationLabel, numeric: true)
                    InfoRow(icon: "calendar", label: "Created", value: dateLabel(session.entry?.createdAt))
                    if let updated = session.entry?.updatedAt {
                        InfoRow(icon: "calendar.badge.clock", label: "Updated", value: dateLabel(updated))
                    }
                    if let aiTitle = session.entry?.aiTitle {
                        InfoRow(icon: "sparkles", label: "AI title", value: aiTitle, wraps: true)
                    }
                    if let summary = session.entry?.shortSummary {
                        InfoRow(icon: "text.quote", label: "AI summary", value: summary, wraps: true)
                    }
                }

                InspectorSection(title: "Transcription Details") {
                    InfoRow(icon: "globe", label: "Language", value: languageLabel)
                    InfoRow(icon: "cube", label: "Model", value: modelLabel)
                    InfoRow(
                        icon: "text.word.spacing",
                        label: "Words",
                        value: AppFormat.integer(session.wordCount),
                        numeric: true
                    )
                    InfoRow(
                        icon: "text.alignleft",
                        label: "Segments",
                        value: AppFormat.integer(session.transcript?.segments.count ?? 0),
                        numeric: true
                    )
                    if !session.speakers.isEmpty {
                        InfoRow(
                            icon: "person.2",
                            label: "Speakers",
                            value: AppFormat.integer(session.speakers.count),
                            numeric: true
                        )
                    }
                    if !session.favorites.isEmpty {
                        InfoRow(
                            icon: "star",
                            label: "Favorites",
                            value: AppFormat.integer(session.favorites.count),
                            numeric: true
                        )
                    }
                    if let translation = translationLabel {
                        InfoRow(icon: "character.book.closed", label: "Translated to", value: translation)
                    }
                }

                VStack(alignment: .leading, spacing: DS.Spacing.small) {
                    Text("Edit in the main window.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                    Button("Open in Main Window") { model.openInMainWindow(session.entryID) }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Button.OpenInMainWindow")
                }
            }
            .padding(DS.Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(model.themeRevision)
        }
        .inspectorPanel()
        .axLeaf("Panel.Info")
    }

    private var durationLabel: String? {
        session.durationSeconds > 0 ? Timecode.format(session.durationSeconds.rounded()) : nil
    }

    private var languageLabel: String {
        LanguageDisplay.name(for: session.transcript?.language) ?? String(localized: "Auto")
    }

    private var modelLabel: String? {
        session.transcript.map { AppModel.modelLabel($0.modelName) }
    }

    private var translationLabel: String? {
        LanguageDisplay.name(for: session.translationLanguage)
    }

    private func dateLabel(_ date: Date?) -> String? {
        date.map { AppFormat.dateAndTime($0) }
    }
}
