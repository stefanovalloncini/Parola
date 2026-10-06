import SwiftUI
import ParolaCore

struct InfoInspector: View {
    struct Derived {
        var text = TranscriptTextStats()
        /// The `transcriptTextVersion` that `text` counts, so an edit that leaves the text alone reuses it.
        var textVersion: Int?
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
        // Built once per pass: the three menu rows below all read it.
        let variants = model.transcribeAgainModels
        return VStack(alignment: .leading, spacing: DS.Spacing.large) {
            InspectorSection(title: "Properties") {
                InfoRow(icon: "clock", label: "Audio duration", value: durationLabel, numeric: true)
                InfoRow(icon: "calendar", label: "Created", value: dateLabel(entry?.createdAt))
                if let updated = entry?.updatedAt {
                    InfoRow(icon: "calendar.badge.clock", label: "Updated", value: dateLabel(updated))
                }
                if let aiTitle = entry?.aiTitle {
                    InfoRow(icon: "sparkles", label: "AI title", value: aiTitle, wraps: true)
                }
                if let summary = entry?.shortSummary {
                    InfoRow(icon: "text.quote", label: "AI summary", value: summary, wraps: true)
                }
                if model.features.isEnabled(.ai), model.transcript != nil {
                    Button("Regenerate title and summary") { model.regenerateCardMetadata() }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary))
                        .axLeaf("Info.Button.RegenerateCardMetadata")
                }
            }

            InspectorSection(title: "Transcription Details") {
                languageRow(variants: variants)
                if let modelName = model.transcript?.modelName {
                    modelRow(current: modelName, variants: variants)
                }
                if let engineLabel {
                    InfoRow(icon: "cpu", label: "Engine", value: engineLabel)
                }
                InfoRow(icon: "character", label: "Characters", value: AppFormat.integer(charCount), numeric: true)
                InfoRow(icon: "text.word.spacing", label: "Words", value: AppFormat.integer(wordCount), numeric: true)
                InfoRow(icon: "text.alignleft", label: "Sentences", value: AppFormat.integer(sentenceCount), numeric: true)
                InfoRow(icon: "book", label: "Reading time", value: readingTimeLabel, numeric: true)
                InfoRow(icon: "stopwatch", label: "Transcribed in", value: transcribedInLabel, numeric: true, wraps: true)
                if speakerCount > 0 {
                    InfoRow(icon: "person.2", label: "Speakers", value: AppFormat.integer(speakerCount), numeric: true)
                }
                if fillerCount > 0 {
                    InfoRow(icon: "exclamationmark.bubble", label: "Filler words", value: AppFormat.integer(fillerCount), numeric: true)
                }
                Button("Transcribe Again") { model.askToTranscribeAgain() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary))
                    .disabled(!model.canTranscribeAgain)
                    .help(model.retranscribeUnavailableReason ?? String(localized: "Runs the same model and language again, with your current Settings"))
                    .axLeaf("Info.Button.TranscribeAgain")
            }

            if model.transcript != nil {
                LabelsSection()
                SpeakerStatsSection(stats: derived.speakers)
                ConfidenceSection(overall: derived.confidenceAverage, lows: derived.lowConfidence)
                ChaptersSection()
                ActionItemsSection()
                SpeechRateSection(bins: derived.speechRate)
                WordFrequencySection(entries: derived.text.topWords)
            }
        }
        .task(id: model.transcriptVersion) { await recomputeDerived() }
    }

    private func languageRow(variants: [ModelVariant]) -> some View {
        InfoMenuRow(
            icon: "globe",
            label: "Language",
            value: languageLabel,
            help: model.retranscribeUnavailableReason,
            isEnabled: menusAreOpen,
            leaf: "Info.Menu.Language"
        ) {
            TranscribeAgainLanguageChoices(model: model, variants: variants)
        }
    }

    private func modelRow(current: String, variants: [ModelVariant]) -> some View {
        InfoMenuRow(
            icon: "cube",
            label: "Model",
            value: AppModel.modelLabel(current),
            help: model.retranscribeUnavailableReason,
            isEnabled: menusAreOpen,
            leaf: "Info.Menu.Model"
        ) {
            TranscribeAgainModelChoices(model: model, variants: variants)
        }
    }

    private var menusAreOpen: Bool {
        model.canRetranscribeSelectedEntry && model.retranscribeRequest == nil
    }

    private func recomputeDerived() async {
        guard let transcript = model.transcript else {
            derived = Derived()
            return
        }
        let textVersion = model.transcriptTextVersion
        let knownText = derived.textVersion == textVersion ? derived.text : nil
        let work = Task.detached(priority: .userInitiated) {
            try Self.derive(transcript: transcript, textVersion: textVersion, knownText: knownText)
        }
        let computed = try? await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        guard let computed, !Task.isCancelled else { return }
        derived = computed
    }

    /// `knownText` is the text count of an unchanged text: only timing, speakers and confidence need a fresh pass.
    nonisolated static func derive(transcript: Transcript, textVersion: Int?, knownText: TranscriptTextStats?) throws -> Derived {
        let text: TranscriptTextStats
        if let knownText, knownText.segmentWordCounts.count == transcript.segments.count {
            text = knownText
        } else {
            text = try TranscriptTextStats.compute(
                segments: transcript.segments,
                stopWords: WordFrequency.stopWords(for: transcript.language),
                topWordLimit: WordFrequencySection.limit
            )
        }
        try Task.checkCancellation()
        return Derived(
            text: text,
            textVersion: textVersion,
            speakers: SpeakerStats.compute(for: transcript),
            confidenceAverage: SegmentConfidence.transcriptAverage(for: transcript),
            lowConfidence: SegmentConfidence.lowConfidence(segments: transcript.segments),
            speechRate: SpeechRateSeries.compute(segments: transcript.segments, wordCounts: text.segmentWordCounts, binSeconds: 30)
        )
    }

    private var languageLabel: String {
        LanguageDisplay.name(for: model.transcript?.language) ?? String(localized: "Auto")
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

    /// Nil for everything that never ran through a file transcription, and for entries made before it was measured.
    private var transcribedInLabel: String? {
        guard let seconds = model.transcript?.transcriptionSeconds ?? entry?.transcriptionSeconds else { return nil }
        return StatisticsCopy.transcribedIn(
            seconds: seconds,
            audioSeconds: model.transcript?.durationSeconds ?? entry?.durationSeconds
        )
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

/// An InfoRow whose value is a menu: picking another one runs the entry's audio again.
struct InfoMenuRow<Content: View>: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String
    let help: String?
    let isEnabled: Bool
    let leaf: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: icon)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 16)
            Text(label)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            Menu(value) { content }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .tint(DS.Color.accentInk)
                .disabled(!isEnabled)
                .help(help ?? "")
                .axLeaf(leaf)
        }
    }
}

struct InfoRow: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String?
    /// Counts, timecodes and sizes take the mono tier so the column of values lines up; names do not.
    var numeric: Bool = false
    /// For the one value that carries two facts: the inspector column is too narrow to truncate it honestly.
    var wraps: Bool = false

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
                    .lineLimit(wraps ? 2 : 1)
                    .multilineTextAlignment(.trailing)
                    .truncationMode(wraps ? .tail : .middle)
                    .fixedSize(horizontal: false, vertical: wraps)
            }
        }
    }
}

