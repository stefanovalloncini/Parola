import SwiftUI
import ParolaCore

struct ExportOptionsSheet: View {
    let format: ExportFormat
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(
            icon: "square.and.arrow.up",
            titleVerbatim: String(localized: "Export as \(format.fileExtension.uppercased())"),
            onClose: { dismiss() },
            content: { contentBody },
            footer: { footerBody }
        )
        .hidesCloseButton()
    }

    private var contentBody: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            switch format {
            case .txt:
                optionRow("Timestamps", detail: "Prefix each line with its start time.") {
                    Toggle("", isOn: $model.txtExportTimestamps)
                        .axLeaf("ExportOptions.Toggle.Timestamps")
                }
            case .md:
                optionRow("Timestamps", detail: "Prefix each paragraph with its start time.") {
                    Toggle("", isOn: $model.markdownTimestamps)
                        .axLeaf("ExportOptions.Toggle.Timestamps")
                }
            case .html:
                optionRow("Theme", detail: "Color scheme of the exported page.") {
                    Picker("", selection: $model.htmlExportThemeRaw) {
                        ForEach(HtmlExportTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .frame(width: 140)
                    .axLeaf("ExportOptions.Picker.HtmlTheme")
                }
            case .srt, .vtt:
                optionRow("Caption length", detail: "Wraps long segments into shorter cues.") {
                    Picker("", selection: $model.subtitleCaptionLengthRaw) {
                        ForEach(CaptionLength.allCases) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }
                    .frame(width: 140)
                    .axLeaf("ExportOptions.Picker.CaptionLength")
                }
            default:
                EmptyView()
            }
        }
        .padding(DS.Spacing.regular)
    }

    private func optionRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Text(detail)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer()
            control()
                .labelsHidden()
        }
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Cancel") { dismiss() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)
                .axLeaf("ExportOptions.Button.Cancel")

            Spacer()

            Button("Export…") {
                dismiss()
                model.pendingExport = format
            }
            .sheetPrimaryAction()
            .keyboardShortcut(.defaultAction)
            .axLeaf("ExportOptions.Button.Export")
        }
    }
}
