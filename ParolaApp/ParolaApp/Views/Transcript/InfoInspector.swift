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

    /// A pick waiting on the "Transcribe again?" alert.
    private struct PendingRetranscribe: Equatable {
        let modelName: String
        let language: String?
        let choiceLabel: String
        /// Set when the run has to fall back off the entry's own model, so the alert can name it.
        let substituteModelLabel: String?
    }

    @Environment(AppModel.self) private var model
    @State private var derived = Derived()
    @State private var pendingRetranscribe: PendingRetranscribe?

    private var entry: LibraryEntry? {
        guard let id = model.selectedEntryID else { return nil }
        return model.libraryEntry(id: id)
    }

    var body: some View {
        // Built once per pass: the three menu rows below all read it.
        let variants = installedVariants
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
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { pendingRetranscribe != nil },
                set: { if !$0 { pendingRetranscribe = nil } }
            ),
            presenting: pendingRetranscribe
        ) { pending in
            Button("Cancel", role: .cancel) { pendingRetranscribe = nil }
                .axLeaf("Info.Button.RetranscribeCancel")
            Button("Transcribe Again") {
                model.retranscribeCurrentEntry(model: pending.modelName, language: pending.language)
                pendingRetranscribe = nil
            }
            .axLeaf("Info.Button.RetranscribeConfirm")
        } message: { pending in
            Text(verbatim: alertMessage(for: pending))
        }
    }

    private func alertMessage(for pending: PendingRetranscribe) -> String {
        let replaced = String(localized: "The current transcript, its favorites, notes, summary and translation will be replaced.")
        guard let substitute = pending.substituteModelLabel else { return replaced }
        let fallback = String(localized: "This transcript's own model isn't available, so Parola will run \(substitute).")
        return replaced + "\n\n" + fallback
    }

    private var alertTitle: String {
        guard let pending = pendingRetranscribe else { return "" }
        return String(localized: "Transcribe again with \(pending.choiceLabel)?")
    }

    private func languageRow(variants: [ModelVariant]) -> some View {
        let scope = runScope(variants: variants)
        return InfoMenuRow(
            icon: "globe",
            label: "Language",
            value: languageLabel,
            help: model.retranscribeUnavailableReason,
            isEnabled: menusAreOpen,
            leaf: "Info.Menu.Language"
        ) {
            menuChoice(LanguagePickerPopover.autoLabel, isCurrent: currentLanguageCode == nil, isAllowed: true) {
                ask(language: nil, label: LanguagePickerPopover.autoLabel)
            }
            Divider()
            ForEach(SupportedLanguages.codes, id: \.self) { code in
                let name = SupportedLanguages.displayName(for: code)
                menuChoice(name, isCurrent: code == currentLanguageCode, isAllowed: scope.allows(code)) {
                    ask(language: code, label: name)
                }
            }
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
            ForEach(variants, id: \.id) { variant in
                menuChoice(
                    "\(variant.displayName) — \(variant.engineID.displayName)",
                    isCurrent: variant.id == current,
                    isAllowed: true
                ) {
                    ask(model: variant.id, label: variant.displayName)
                }
            }
        }
    }

    /// A menu row that marks the value the entry already carries and shuts the ones it can't run.
    private func menuChoice(
        _ title: String,
        isCurrent: Bool,
        isAllowed: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isCurrent }, set: { _ in action() })) {
            Text(verbatim: title)
        }
        .disabled(!isAllowed)
    }

    private var menusAreOpen: Bool {
        model.canRetranscribeSelectedEntry && model.retranscribeRequest == nil
    }

    private var installedVariants: [ModelVariant] {
        AppModel.selectableModels(model.availableModels)
            .filter(\.isInstalled)
            .compactMap { ModelCatalog.variant(id: $0.name) }
    }

    /// Auto and "no language recorded" are the same answer, and the menu offers it once.
    private var currentLanguageCode: String? {
        let code = model.transcript?.language ?? ""
        return code.isEmpty ? nil : code
    }

    /// The model a language pick runs: the entry's own, or the selected one when that one is gone.
    private func runModel(variants: [ModelVariant]) -> String {
        let current = model.transcript?.modelName ?? ""
        return variants.contains { $0.id == current } ? current : model.selectedModel
    }

    /// What that model can transcribe, so the menu can shut the codes it would refuse.
    private func runScope(variants: [ModelVariant]) -> ParolaCore.SupportedLanguages {
        ModelCatalog.staticCapabilities(forID: runModel(variants: variants))?.supportedLanguages ?? .all
    }

    /// Picking the value the entry already carries asks nothing: there is no re-run to confirm.
    private func ask(model modelName: String, label: String) {
        guard modelName != model.transcript?.modelName else { return }
        pendingRetranscribe = PendingRetranscribe(
            modelName: modelName,
            language: currentLanguageCode,
            choiceLabel: label,
            substituteModelLabel: nil
        )
    }

    private func ask(language code: String?, label: String) {
        guard code != currentLanguageCode else { return }
        let runs = runModel(variants: installedVariants)
        let substitute = runs == model.transcript?.modelName ? nil : AppModel.modelLabel(runs)
        pendingRetranscribe = PendingRetranscribe(
            modelName: runs,
            language: code,
            choiceLabel: label,
            substituteModelLabel: substitute
        )
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

