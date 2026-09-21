import SwiftUI
import ParolaCore

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @State private var namingPreset = false
    @State private var presetName = ""

    var body: some View {
        SheetFrame(
            icon: "square.and.arrow.up",
            title: "Export",
            onClose: { model.closeExportSheet() },
            content: { contentBody },
            footer: { footerBody }
        )
        .sheetSize(width: 760, minHeight: 460, maxHeight: 620)
        .hidesCloseButton()
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
        case .milliseconds:
            toggleRow("Milliseconds", detail: "Write times down to the millisecond.", leaf: "Milliseconds") {
                spec.options.milliseconds
            } set: { options, isOn in
                options.milliseconds = isOn
            }
            .disabled(!spec.options.timestamps)
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
            Button("Close") { model.closeExportSheet() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("Export.Button.Close")

            Spacer()

            Button("Copy to Clipboard") { model.copyExportToPasteboard() }
                .sheetSecondaryAction()
                .disabled(!model.hasTranscript)
                .axLeaf("Export.Button.Copy")

            Button("Export…") { model.exportFromSheet() }
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasTranscript)
                .axLeaf("Export.Button.Export")
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
        get: @escaping () -> Bool,
        set: @escaping (inout ExportOptions, Bool) -> Void
    ) -> some View {
        labelledRow(title, detail: detail) {
            Toggle("", isOn: Binding(get: get, set: { isOn in
                var options = spec.options
                set(&options, isOn)
                model.setExportSpec(ExportSpec(style: spec.style, format: spec.format, options: options))
            }))
            .labelsHidden()
            .axLeaf("Export.Toggle.\(leaf)")
        }
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
                .frame(width: 180, alignment: .trailing)
                .axLeaf("Export.Picker.\(leaf)")
        }
    }

    private func labelledRow(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Text(detail)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Spacing.small)
            control()
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
