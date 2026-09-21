import SwiftUI
import ParolaCore

struct SummaryOptionsColumn: View {
    @Environment(AppModel.self) private var model
    let options: Binding<SummaryOptions>
    let autostart: Binding<Bool>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                providerRow
                actionButtons
                Divider().opacity(0.4)
                optionToggles
                languagePicker
                customPromptEditor
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

    private var optionToggles: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            toggleRow("Include timestamps", isOn: options.includeTimestamps, axLeafID: "Summary.Toggle.IncludeTimestamps")
            toggleRow("Include speakers", isOn: options.includeSpeakers, axLeafID: "Summary.Toggle.IncludeSpeakers")
            toggleRow("Summarize automatically", isOn: autostart, axLeafID: "Summary.Toggle.Autostart")
            Divider().opacity(0.4)
            toggleRow("Organize into sections", isOn: options.sections, axLeafID: "Summary.Toggle.Sections")
            toggleRow("Bullet points", isOn: options.bulletPoints, axLeafID: "Summary.Toggle.BulletPoints")
            toggleRow("Action items", isOn: options.actionItems, axLeafID: "Summary.Toggle.ActionItems")
            toggleRow("Key points only", isOn: options.keyPointsOnly, axLeafID: "Summary.Toggle.KeyPointsOnly")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The label fills the row so every switch lands at the same trailing edge, instead of hugging its own label.
    private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>, axLeafID: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .axLeaf(axLeafID)
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            Text("Output language")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            Picker(selection: options.outputLanguage) {
                Text("Transcript language").tag(String?.none)
                ForEach(SupportedLanguages.codes, id: \.self) { code in
                    Text(SupportedLanguages.displayName(for: code)).tag(String?.some(code))
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .axLeaf("Summary.Picker.Language")
        }
    }

    private var customPromptEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.hair) {
            Text("Custom instructions")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            ZStack(alignment: .topLeading) {
                TextEditor(text: customPromptBinding)
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

    private var customPromptBinding: Binding<String> {
        Binding(
            get: { options.wrappedValue.customPrompt ?? "" },
            set: { options.wrappedValue.customPrompt = $0.isEmpty ? nil : $0 }
        )
    }
}
