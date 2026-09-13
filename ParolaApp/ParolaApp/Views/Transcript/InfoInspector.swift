import SwiftUI
import ParolaCore

struct InfoInspector: View {
    struct Derived {
        var text = TranscriptTextStats()
        var speakers: [SpeakerStats] = []
        var confidenceAverage: Double?
        var lowConfidence: [TranscriptSegment] = []
        var speechRate: [SpeechRateBin] = []
    }

    @Environment(AppModel.self) private var model
    @State private var derived = Derived()

    private var entry: LibraryEntry? {
        guard let id = model.selectedEntryID else { return nil }
        return model.libraryEntry(id: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            InspectorSection(title: "Properties") {
                InfoRow(icon: "clock", label: "Audio duration", value: durationLabel, numeric: true)
                InfoRow(icon: "calendar", label: "Created", value: dateLabel(entry?.createdAt))
                if let updated = entry?.updatedAt {
                    InfoRow(icon: "calendar.badge.clock", label: "Updated", value: dateLabel(updated))
                }
            }

            InspectorSection(title: "Transcription Details") {
                InfoRow(icon: "globe", label: "Language", value: languageLabel)
                InfoRow(icon: "cube", label: "Model", value: modelLabel)
                if let engineLabel {
                    InfoRow(icon: "cpu", label: "Engine", value: engineLabel)
                }
                InfoRow(icon: "character", label: "Characters", value: "\(charCount)", numeric: true)
                InfoRow(icon: "text.word.spacing", label: "Words", value: "\(wordCount)", numeric: true)
                InfoRow(icon: "text.alignleft", label: "Sentences", value: "\(sentenceCount)", numeric: true)
                InfoRow(icon: "book", label: "Reading time", value: readingTimeLabel, numeric: true)
                if speakerCount > 0 {
                    InfoRow(icon: "person.2", label: "Speakers", value: "\(speakerCount)", numeric: true)
                }
                if fillerCount > 0 {
                    InfoRow(icon: "exclamationmark.bubble", label: "Filler words", value: "\(fillerCount)", numeric: true)
                }
            }

            if model.transcript != nil {
                LabelsSection()
                SpeakerStatsSection(stats: derived.speakers)
                ConfidenceSection(overall: derived.confidenceAverage, lows: derived.lowConfidence)
                ChaptersSection()
                ActionItemsSection()
                SpeechRateSection(bins: derived.speechRate)
                WordFrequencySection()
            }
        }
        .task(id: model.transcriptVersion) { await recomputeDerived() }
    }

    private func recomputeDerived() async {
        guard let transcript = model.transcript else {
            derived = Derived()
            return
        }
        let text = model.transcriptText
        guard transcript.segments.count > TranscriptDerive.synchronousCap else {
            derived = Self.derive(transcript: transcript, text: text)
            return
        }
        let computed = await Task.detached(priority: .userInitiated) {
            Self.derive(transcript: transcript, text: text)
        }.value
        guard !Task.isCancelled else { return }
        derived = computed
    }

    nonisolated static func derive(transcript: Transcript, text: String) -> Derived {
        Derived(
            text: TranscriptTextStats.compute(text: text),
            speakers: SpeakerStats.compute(for: transcript),
            confidenceAverage: SegmentConfidence.transcriptAverage(for: transcript),
            lowConfidence: SegmentConfidence.lowConfidence(segments: transcript.segments),
            speechRate: SpeechRateSeries.compute(segments: transcript.segments, binSeconds: 30)
        )
    }

    private var languageLabel: String {
        LanguageDisplay.name(for: model.transcript?.language) ?? String(localized: "Auto")
    }

    private var modelLabel: String? {
        guard let modelName = model.transcript?.modelName else { return nil }
        return AppModel.modelLabel(modelName)
    }

    private var engineLabel: String? {
        guard let modelName = model.transcript?.modelName,
              let variant = ModelCatalog.variant(id: modelName) else {
            return nil
        }
        return variant.engineID.displayName
    }

    private var durationLabel: String? {
        model.transcript?.durationSeconds.map { Timecode.format($0.rounded()) }
    }

    private func dateLabel(_ date: Date?) -> String? {
        date.map { AppFormat.dateAndTime($0) }
    }

    private var charCount: Int { derived.text.charCount }

    private var speakerCount: Int {
        model.transcriptSpeakers.count
    }

    private var fillerCount: Int { derived.text.fillerCount }

    private var readingTimeLabel: String? {
        let minutes = ReadingTime.minutes(forWordCount: wordCount)
        guard minutes > 0 else { return nil }
        return ReadingTime.label(forMinutes: minutes)
    }

    private var sentenceCount: Int { derived.text.sentenceCount }

    private var wordCount: Int { derived.text.wordCount }
}

struct InfoRow: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String?
    /// Counts, timecodes and sizes take the mono tier so the column of values lines up; names do not.
    var numeric: Bool = false

    var body: some View {
        // A fact the document does not carry is left out: an em dash reads as a placeholder nobody designed.
        if let value, !value.isEmpty {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: icon)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 16)
                Text(label)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Text(value)
                    .font(numeric ? DS.Font.mono : DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

