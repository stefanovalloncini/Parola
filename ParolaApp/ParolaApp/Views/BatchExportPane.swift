import SwiftUI
import ParolaCore

struct BatchExportPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                Text("Export Formats")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                    .padding(.top, DS.Spacing.regular)

                if model.batchExportFormats.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.small) {
                        Text("No formats selected.")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.secondaryText)
                        Text("Use Add Format above to pick the files Parola writes next to each transcribed audio or video.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    .padding(DS.Spacing.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                            .fill(DS.Color.surface)
                    )
                } else {
                    ForEach(model.batchExportFormats, id: \.self) { format in
                        BatchFormatCard(format: format)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.bottom, DS.Spacing.large)
        }
    }
}

struct BatchFormatCard: View {
    @EnvironmentObject var model: AppModel
    let format: ExportFormat
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DS.Spacing.small) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.Color.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(formatLabel)
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundStyle(DS.Color.primaryText)
                    BatchFormatChip(extension: format.fileExtension)
                    Spacer()
                    Button {
                        model.removeBatchExportFormat(format)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Color.secondaryText)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this format")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Spacing.small) {
                    Divider()
                        .padding(.vertical, DS.Spacing.tight)
                    BatchSettingRow(
                        title: "Export to folder of audio file",
                        description: "Saves the \(format.fileExtension.uppercased()) next to each transcribed file."
                    ) {
                        Toggle("", isOn: writeToSourceFolder)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(DS.Color.accent)
                    }
                    if format == .md || format == .html {
                        BatchSettingRow(
                            title: "Include timestamps",
                            description: "Writes start times alongside each segment."
                        ) {
                            Toggle("", isOn: includeTimestamps)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(DS.Color.accent)
                        }
                    }
                }
                .padding(.top, DS.Spacing.small)
            }
        }
        .padding(DS.Spacing.regular)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surface)
        )
    }

    private var formatLabel: String {
        switch format {
        case .txt: return "Transcript"
        case .srt: return "SubRip Subtitles"
        case .vtt: return "WebVTT Subtitles"
        case .json: return "JSON"
        case .md: return "Markdown"
        case .html: return "HTML"
        case .csv: return "CSV"
        case .docx: return "Word Document"
        case .pdf: return "PDF"
        }
    }

    private var writeToSourceFolder: Binding<Bool> {
        Binding(
            get: { model.options(for: format).writeToSourceFolder },
            set: { newValue in
                var opts = model.options(for: format)
                opts.writeToSourceFolder = newValue
                model.setOptions(opts, for: format)
            }
        )
    }

    private var includeTimestamps: Binding<Bool> {
        Binding(
            get: { model.options(for: format).includeTimestamps },
            set: { newValue in
                var opts = model.options(for: format)
                opts.includeTimestamps = newValue
                model.setOptions(opts, for: format)
            }
        )
    }
}

struct BatchFormatChip: View {
    let `extension`: String

    var body: some View {
        Text(".\(`extension`)")
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(DS.Color.separator.opacity(0.4))
            )
    }
}

struct BatchSettingRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Text(description)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Spacing.small)
            control()
        }
    }
}
