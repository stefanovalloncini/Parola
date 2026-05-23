import SwiftUI
import ParolaCore

struct InfoInspector: View {
    @EnvironmentObject var model: AppModel

    private var entry: LibraryEntry? {
        guard let id = model.selectedEntryID else { return nil }
        return model.libraryEntry(id: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            InfoSection(title: "Properties") {
                InfoRow(icon: "clock", label: "Audio Duration", value: durationLabel)
                InfoRow(icon: "calendar", label: "Created", value: dateLabel(entry?.createdAt))
                if let updated = entry?.updatedAt {
                    InfoRow(icon: "calendar.badge.clock", label: "Updated", value: dateLabel(updated))
                }
            }

            InfoSection(title: "Transcription Details") {
                InfoRow(icon: "globe", label: "Language", value: languageLabel)
                InfoRow(icon: "cube", label: "Model", value: model.transcript?.modelName ?? "—")
                InfoRow(icon: "cpu", label: "Engine", value: engineLabel)
                InfoRow(icon: "character", label: "Characters", value: "\(charCount)")
                InfoRow(icon: "text.word.spacing", label: "Words", value: "\(wordCount)")
                InfoRow(icon: "text.alignleft", label: "Sentences", value: "\(sentenceCount)")
                InfoRow(icon: "book", label: "Reading time", value: readingTimeLabel)
                if speakerCount > 0 {
                    InfoRow(icon: "person.2", label: "Speakers", value: "\(speakerCount)")
                }
                if fillerCount > 0 {
                    InfoRow(icon: "exclamationmark.bubble", label: "Filler words", value: "\(fillerCount)")
                }
            }

            if model.transcript != nil {
                LabelsSection()
                SpeakerStatsSection()
                ConfidenceSection()
                ChaptersSection()
                ActionItemsSection()
                SpeechRateSection()
                WordFrequencySection()
            }
        }
    }

    private var languageLabel: String {
        guard let code = model.transcript?.language, !code.isEmpty else { return String(localized: "Auto") }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private var engineLabel: String {
        guard let modelName = model.transcript?.modelName,
              let variant = ModelCatalog.variant(id: modelName) else {
            return "—"
        }
        return variant.engineID.displayName
    }

    private var durationLabel: String {
        guard let d = model.transcript?.durationSeconds else { return "—" }
        return Duration.seconds(d).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var charCount: Int {
        model.transcript?.text.count ?? 0
    }

    private var speakerCount: Int {
        model.transcriptSpeakers.count
    }

    private var fillerCount: Int {
        guard let text = model.transcript?.text else { return 0 }
        return FillerWordCounter.count(in: text)
    }

    private var readingTimeLabel: String {
        ReadingTime.label(forMinutes: ReadingTime.minutes(forWordCount: wordCount))
    }

    private var sentenceCount: Int {
        guard let text = model.transcript?.text else { return 0 }
        return SentenceCounter.count(text)
    }

    private var wordCount: Int {
        guard let text = model.transcript?.text else { return 0 }
        return text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

struct InfoSection<Content: View>: View {
    private let titleText: Text
    private let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.titleText = Text(title)
        self.content = content()
    }

    init(titleVerbatim: String, @ViewBuilder content: () -> Content) {
        self.titleText = Text(titleVerbatim)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            titleText
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: icon)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 16)
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(DS.Font.body)
    }
}

