import SwiftUI
import ParolaCore

struct SummaryPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            mainColumn
            Divider()
            optionsColumn(options: $model.summaryOptions, autostart: $model.autostartSummary)
                .frame(width: 260)
        }
        .background(DS.Color.surface)
        .task { model.refreshAIAvailability() }
        .axBranch("Summary")
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                header
                if let summary = model.transcript?.summary,
                   !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metadataStrip(summary: summary)
                }
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.regular)

            Divider().opacity(0.4)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        Text("Summary")
            .font(DS.Font.heading)
    }

    private func metadataStrip(summary: Summary) -> some View {
        let words = summary.text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = summary.text.count
        let modelName = model.transcript?.modelName ?? ""

        return HStack(spacing: 6) {
            metaLabel(Text("\(words) words"))
            dot
            metaLabel(Text("\(chars) chars"))
            if !modelName.isEmpty {
                dot
                metaLabel(Text(verbatim: modelName))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var dot: some View {
        Text(verbatim: "·")
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
    }

    private func metaLabel(_ text: Text) -> some View {
        text
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.secondaryText)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.summaryError {
            SummaryError(message: error)
        } else if let summary = model.transcript?.summary {
            SummaryBody(summary: summary)
        } else if model.transcript == nil {
            ContentUnavailableView(
                "No Transcript",
                systemImage: "doc.text",
                description: Text("Open a transcript to generate a summary.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let reason = model.aiUnavailableReason {
            ContentUnavailableView {
                Label("Summaries Need Apple Intelligence", systemImage: "sparkles")
            } description: {
                Text(verbatim: reason)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SummaryEmpty(isWorking: model.isSummarising) {
                model.summariseTranscript()
            }
        }
    }

    private func optionsColumn(options: Binding<SummaryOptions>, autostart: Binding<Bool>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                providerRow
                actionButtons
                Divider().opacity(0.4)
                optionToggles(options: options, autostart: autostart)
                languagePicker(options: options)
                customPromptEditor(options: options)
            }
            .padding(DS.Spacing.regular)
        }
    }

    private var providerRow: some View {
        HStack(spacing: DS.Spacing.snug) {
            Image(systemName: "sparkles")
                .foregroundStyle(DS.Color.secondaryText)
            Text(providerLabel)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(2)
        }
    }

    private var providerLabel: String {
        model.isAIAvailable ? String(localized: "Apple Intelligence") : (model.aiUnavailableReason ?? "")
    }

    private var actionButtons: some View {
        HStack(spacing: DS.Spacing.snug) {
            Button("Copy", action: copySummary)
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(model.transcript?.summary == nil)
                .axLeaf("Summary.Button.Copy")

            Button(action: { model.summariseTranscript() }) {
                HStack(spacing: 4) {
                    if model.isSummarising {
                        ProgressView().controlSize(.small)
                    }
                    Text(summarizeButtonTitle)
                }
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
            .disabled(model.transcript == nil || model.isSummarising || !model.isAIAvailable)
            .axLeaf("Summary.Button.Regenerate")

            Button("Clear") { model.clearSummary() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(model.transcript?.summary == nil)
                .axLeaf("Summary.Button.Clear")
        }
    }

    private var summarizeButtonTitle: String {
        model.transcript?.summary == nil ? String(localized: "Summarize") : String(localized: "Regenerate")
    }

    private func copySummary() {
        guard let summary = model.transcript?.summary else { return }
        var text = summary.text
        if !summary.actionItems.isEmpty {
            text += "\n\n" + String(localized: "Action items:") + "\n"
            text += summary.actionItems.map { "- \($0)" }.joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func optionToggles(options: Binding<SummaryOptions>, autostart: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            Toggle("Include timestamps", isOn: options.includeTimestamps)
                .axLeaf("Summary.Toggle.IncludeTimestamps")
            Toggle("Include speakers", isOn: options.includeSpeakers)
                .axLeaf("Summary.Toggle.IncludeSpeakers")
            Toggle("Summarize automatically", isOn: autostart)
                .axLeaf("Summary.Toggle.Autostart")
            Divider().opacity(0.4)
            Toggle("Organize into sections", isOn: options.sections)
                .axLeaf("Summary.Toggle.Sections")
            Toggle("Bullet points", isOn: options.bulletPoints)
                .axLeaf("Summary.Toggle.BulletPoints")
            Toggle("Action Items", isOn: options.actionItems)
                .axLeaf("Summary.Toggle.ActionItems")
            Toggle("Key points only", isOn: options.keyPointsOnly)
                .axLeaf("Summary.Toggle.KeyPointsOnly")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func languagePicker(options: Binding<SummaryOptions>) -> some View {
        Picker(selection: options.outputLanguage) {
            Text("Transcript language").tag(String?.none)
            ForEach(SupportedLanguages.codes, id: \.self) { code in
                Text(SupportedLanguages.displayName(for: code)).tag(String?.some(code))
            }
        } label: {
            Text("Output language")
        }
        .pickerStyle(.menu)
        .axLeaf("Summary.Picker.Language")
    }

    private func customPromptEditor(options: Binding<SummaryOptions>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            Text("Custom instructions")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            ZStack(alignment: .topLeading) {
                TextEditor(text: customPromptBinding(options))
                    .font(DS.Font.body)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Spacing.hair)
                    .background(DS.Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                    .axLeaf("Summary.TextEditor.CustomPrompt")
                if (options.wrappedValue.customPrompt ?? "").isEmpty {
                    Text("Custom summary instructions")
                        .foregroundStyle(DS.Color.secondaryText.opacity(0.6))
                        .padding(.horizontal, DS.Spacing.snug)
                        .padding(.vertical, DS.Spacing.tight)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func customPromptBinding(_ options: Binding<SummaryOptions>) -> Binding<String> {
        Binding(
            get: { options.wrappedValue.customPrompt ?? "" },
            set: { options.wrappedValue.customPrompt = $0.isEmpty ? nil : $0 }
        )
    }
}
