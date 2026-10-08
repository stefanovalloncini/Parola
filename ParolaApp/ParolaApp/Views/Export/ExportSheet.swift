import SwiftUI
import ParolaCore

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    var body: some View {
        SheetFrame(
            title: "Export",
            onClose: { model.closeExportSheet() },
            content: { contentBody },
            footer: { footerBody }
        )
        .sheetSize(width: 760, minHeight: 460, maxHeight: 620)
        .footerHasCancel()
        .onDisappear { copiedReset?.cancel() }
        .alert("Save as Preset", isPresented: $namingPreset) {
            TextField("Preset name", text: $presetName)
                .axLeaf("Export.TextField.PresetName")
            Button("Save") {
                model.saveExportSheetSpecAsPreset(name: presetName)
                presetName = ""
            }
            .axLeaf("Export.Button.SavePresetConfirm")
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("The preset keeps this style, format and options.")
        }
    }

    private var spec: ExportSpec { model.exportSheetSpec }

    private var contentBody: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                    styleSection
                    formatSection
                    optionsSection
                    savePresetButton
                }
                .padding(DS.Spacing.regular)
            }
            .frame(width: 360)

            Divider()

            Group {
                if let transcript = model.transcript {
                    ExportPreview(spec: spec, transcript: transcript)
                } else {
                    InlineEmptyText("No transcript loaded")
                }
            }
            .padding(DS.Spacing.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            sectionTitle("Style")
            LeadingFlow(spacing: DS.Spacing.tight) {
                ForEach(ExportStyle.allCases) { style in
                    Button(LocalizedStringKey(style.displayName)) {
                        model.setExportSpec(spec.changing(style: style))
                    }
                    .buttonStyle(DSPillButtonStyle(kind: spec.style == style ? .primary : .secondary, size: .compact))
                    .accessibilityAddTraits(spec.style == style ? .isSelected : [])
                    .axLeaf("Export.Button.Style.\(style.rawValue)")
                }
            }
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            sectionTitle("Format")
            LeadingFlow(spacing: DS.Spacing.tight) {
                ForEach(spec.style.formats, id: \.self) { format in
                    Button(LocalizedStringKey(format.displayName)) {
                        model.setExportSpec(spec.changing(format: format))
                    }
                    .buttonStyle(DSPillButtonStyle(kind: spec.format == format ? .primary : .secondary, size: .compact))
                    .accessibilityAddTraits(spec.format == format ? .isSelected : [])
                    .axLeaf("Export.Button.Format.\(format.fileExtension)")
                }
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            sectionTitle("Options")
            if model.hasTranslation { contentRow }
            ForEach(spec.format.optionFields) { field in
                optionRow(field)
            }
        }
    }

    /// Only worth a row when the transcript has a translation to choose from.
    private var contentRow: some View {
        pickerRow("Language", detail: "Write the original, the translation, or both.", leaf: "Content") {
            Picker("", selection: contentBinding) {
                ForEach(ExportContent.allCases) { content in
                    Text(LocalizedStringKey(content.displayName)).tag(content)
                }
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ field: ExportOptionField) -> some View {
        switch field {
        case .timestamps:
            toggleRow("Timestamps", detail: "Prefix each line with its start time.", leaf: "Timestamps") {
                spec.options.timestamps
            } set: { options, isOn in
                options.timestamps = isOn
            }
        case .endTimestamps:
            toggleRow("End times", detail: "Show the end of each segment too.", leaf: "EndTimestamps") {
                spec.options.endTimestamps
            } set: { options, isOn in
                options.endTimestamps = isOn
            }
            .disabled(!spec.options.timestamps)
            .padding(.leading, DS.Spacing.large)
        case .milliseconds:
            toggleRow("Milliseconds", detail: "Write times down to the millisecond.", leaf: "Milliseconds") {
                spec.options.milliseconds
            } set: { options, isOn in
                options.milliseconds = isOn
            }
            .disabled(!spec.options.timestamps)
            .padding(.leading, DS.Spacing.large)
        case .speakers:
            toggleRow("Speakers", detail: "Label each line with who is speaking.", leaf: "Speakers") {
                spec.options.speakers
            } set: { options, isOn in
                options.speakers = isOn
            }
        case .captionLength:
            pickerRow("Caption length", detail: "Wraps long segments into shorter cues.", leaf: "CaptionLength") {
                Picker("", selection: captionLengthBinding) {
                    ForEach(CaptionLength.allCases) { length in
                        Text(LocalizedStringKey(length.displayName)).tag(length)
                    }
                }
            }
        case .htmlTheme:
            pickerRow("Theme", detail: "Color scheme of the exported page.", leaf: "HtmlTheme") {
                Picker("", selection: htmlThemeBinding) {
                    ForEach(HtmlExportTheme.allCases) { theme in
                        Text(LocalizedStringKey(theme.displayName)).tag(theme)
                    }
                }
            }
        case .grouping:
            pickerRow("Grouping", detail: "Merge a speaker's consecutive segments into one.", leaf: "Grouping") {
                Picker("", selection: groupingBinding) {
                    ForEach(ExportGrouping.allCases) { grouping in
                        Text(LocalizedStringKey(grouping.displayName)).tag(grouping)
                    }
                }
            }
        }
    }

    private var savePresetButton: some View {
        Button("Save as Preset…") {
            presetName = ""
            namingPreset = true
        }
        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
        .axLeaf("Export.Button.SavePreset")
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Button(action: copyToClipboard) {
                ZStack {
                    Text("Copy to Clipboard").hidden()
                    Text(copied ? "Copied" : "Copy to Clipboard")
                }
            }
            .sheetSecondaryAction()
            .disabled(!model.hasTranscript)
            .axLeaf("Export.Button.Copy")

            Spacer()

            Button("Close") { model.closeExportSheet() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("Export.Button.Close")

            Button("Export…") { model.exportFromSheet() }
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasTranscript)
                .axLeaf("Export.Button.Export")
        }
    }

    private func copyToClipboard() {
        Task {
            if await model.copyExportToPasteboard(pasteboard: .general)?.value == true { showCopied() }
        }
    }

    private func showCopied() {
        copied = true
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(DS.Font.bodyStrong)
            .foregroundStyle(DS.Color.secondaryText)
    }

    private func toggleRow(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        leaf: String,
        get: @escaping @MainActor @Sendable () -> Bool,
        set: @escaping @MainActor @Sendable (inout ExportOptions, Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: get, set: { isOn in
            var options = spec.options
            set(&options, isOn)
            model.setExportSpec(ExportSpec(style: spec.style, format: spec.format, options: options))
        })) {
            ExportOptionLabel(title: title, detail: detail)
        }
        .toggleStyle(.checkbox)
        .axLeaf("Export.Toggle.\(leaf)")
    }

    private func pickerRow(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        leaf: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        labelledRow(title, detail: detail) {
            control()
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .axLeaf("Export.Picker.\(leaf)")
        }
    }

    private func labelledRow(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer(minLength: DS.Spacing.small)
                control()
            }
            Text(detail)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var captionLengthBinding: Binding<CaptionLength> {
        optionBinding(\.captionLength)
    }

    private var htmlThemeBinding: Binding<HtmlExportTheme> {
        optionBinding(\.htmlTheme)
    }

    private var contentBinding: Binding<ExportContent> {
        optionBinding(\.content)
    }

    private var groupingBinding: Binding<ExportGrouping> {
        optionBinding(\.grouping)
    }

    private func optionBinding<Value>(_ keyPath: WritableKeyPath<ExportOptions, Value>) -> Binding<Value> {
        Binding(
            get: { spec.options[keyPath: keyPath] },
            set: { newValue in
                var options = spec.options
                options[keyPath: keyPath] = newValue
                model.setExportSpec(ExportSpec(style: spec.style, format: spec.format, options: options))
            }
        )
    }
}

/// An option's name and what it does; it dims with its control when the option can't apply.
private struct ExportOptionLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.primaryText)
            Text(detail)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}
