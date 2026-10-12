import SwiftUI
import ParolaCore

/// What the inspector counts from the open transcript, off the main actor; Details and Insights both read it.
struct TranscriptFacts {
    var text = TranscriptTextStats()
    /// The `transcriptTextVersion` that `text` counts, so an edit that leaves the text alone reuses it.
    var textVersion: Int?
    var speakers: [SpeakerStats] = []
    var confidenceAverage: Double?
    var lowConfidence: [TranscriptSegment] = []
    var lowConfidenceAverages: [TranscriptSegment.ID: Double] = [:]
    var speechRate: [SpeechRateBin] = []

    /// Mirrors what each Insights section draws, so an empty disclosure never shows.
    var hasInsights: Bool {
        !speakers.isEmpty || confidenceAverage != nil || speechRate.count >= 2 || !text.topWords.isEmpty
    }

    /// `knownText` is the text count of an unchanged text: only timing, speakers and confidence need a fresh pass.
    nonisolated static func derive(transcript: Transcript, textVersion: Int?, knownText: TranscriptTextStats?) throws -> TranscriptFacts {
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
        let lows = SegmentConfidence.lowConfidence(segments: transcript.segments)
        return TranscriptFacts(
            text: text,
            textVersion: textVersion,
            speakers: SpeakerStats.compute(for: transcript),
            confidenceAverage: SegmentConfidence.transcriptAverage(for: transcript),
            lowConfidence: lows,
            lowConfidenceAverages: Dictionary(
                lows.compactMap { segment in SegmentConfidence.average(for: segment).map { (segment.id, $0) } },
                uniquingKeysWith: { first, _ in first }
            ),
            speechRate: SpeechRateSeries.compute(segments: transcript.segments, wordCounts: text.segmentWordCounts, binSeconds: 30)
        )
    }
}

/// The reference rows, as one list: the entry's properties, how it was transcribed, and the actions that redo either.
struct TranscriptDetails: View {
    let facts: TranscriptFacts

    @Environment(AppModel.self) private var model

    private var entry: LibraryEntry? {
        guard let id = model.selectedEntryID else { return nil }
        return model.libraryEntry(id: id)
    }

    var body: some View {
        // Built once per pass: the two menu rows below both read it.
        let variants = model.transcribeAgainModels
        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
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
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Info.Button.RegenerateCardMetadata")
            }

            Divider()
                .padding(.vertical, DS.Spacing.tight)

            languageRow(variants: variants)
            if let modelName = model.transcript?.modelName {
                modelRow(current: modelName, variants: variants)
            }
            InfoRow(icon: "character", label: "Characters", value: AppFormat.integer(facts.text.charCount), numeric: true)
            InfoRow(icon: "text.word.spacing", label: "Words", value: AppFormat.integer(facts.text.wordCount), numeric: true)
            InfoRow(icon: "text.alignleft", label: "Sentences", value: AppFormat.integer(facts.text.sentenceCount), numeric: true)
            InfoRow(icon: "book", label: "Reading time", value: readingTimeLabel, numeric: true)
            InfoRow(icon: "stopwatch", label: "Transcribed in", value: transcribedInLabel, numeric: true, wraps: true)
            if speakerCount > 0 {
                InfoRow(icon: "person.2", label: "Speakers", value: AppFormat.integer(speakerCount), numeric: true)
            }
            if facts.text.fillerCount > 0 {
                InfoRow(icon: "exclamationmark.bubble", label: "Filler words", value: AppFormat.integer(facts.text.fillerCount), numeric: true)
            }
            if !model.favoriteSegmentIDs.isEmpty {
                InfoRow(icon: "star", label: "Favorites", value: AppFormat.integer(model.favoriteSegmentIDs.count), numeric: true)
            }
            if let translation = model.transcript?.translation {
                translationRow(translation)
            }
            Button("Transcribe Again") { model.askToTranscribeAgain() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(!model.canTranscribeAgain)
                .help(model.retranscribeUnavailableReason ?? String(localized: "Runs the same model and language again, with your current Settings"))
                .axLeaf("Info.Button.TranscribeAgain")
        }
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

    /// The language it was translated to; the menu translates it again or drops it, as Transcript ▸ Translate To does.
    private func translationRow(_ translation: TranscriptTranslation) -> some View {
        InfoMenuRow(
            icon: "character.book.closed",
            label: "Translated to",
            value: LanguageDisplay.name(for: translation.targetLanguage) ?? translation.targetLanguage,
            help: nil,
            isEnabled: model.canTranslateTranscript,
            leaf: "Info.Menu.Translation"
        ) {
            ForEach(TranslationTargets.offered(by: model), id: \.code) { target in
                Button(target.name) { Task { await model.translateTranscript(to: target.code) } }
            }
            Divider()
            Button("Remove Translation") { Task { await model.removeTranslation() } }
        }
    }

    private var menusAreOpen: Bool {
        model.canRetranscribeSelectedEntry && model.retranscribeRequest == nil
    }

    private var languageLabel: String {
        LanguageDisplay.name(for: model.transcript?.language) ?? String(localized: "Auto")
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

    private var speakerCount: Int {
        model.transcriptSpeakers.count
    }

    private var readingTimeLabel: String? {
        let minutes = ReadingTime.minutes(forWordCount: facts.text.wordCount)
        guard minutes > 0 else { return nil }
        return ReadingTime.label(forMinutes: minutes)
    }
}

/// What the numbers say about the talk: who spoke how much, how sure the model was, how fast, which words.
struct TranscriptInsights: View {
    let facts: TranscriptFacts

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            SpeakerStatsSection(stats: facts.speakers)
            ConfidenceSection(overall: facts.confidenceAverage, lows: facts.lowConfidence, averages: facts.lowConfidenceAverages)
            SpeechRateSection(bins: facts.speechRate)
            WordFrequencySection(entries: facts.text.topWords)
        }
    }
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

