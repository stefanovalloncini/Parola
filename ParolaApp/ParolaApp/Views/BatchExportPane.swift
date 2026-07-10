import SwiftUI
import ParolaCore

struct BatchExportPanel: View {
    @Environment(AppModel.self) private var model

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
    @Environment(AppModel.self) private var model
    let format: ExportFormat
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DS.Spacing.small) {
                    Image(systemName: "chevron.right")
                        .font(DS.Font.subheadlineBold)
                        .foregroundStyle(DS.Color.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(LocalizedStringKey(formatLabel))
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundStyle(DS.Color.primaryText)
                    BatchFormatChip(extension: format.fileExtension)
                    Spacer()
                    Button {
                        model.removeBatchExportFormat(format)
                    } label: {
                        Image(systemName: "xmark")
                            .font(DS.Font.caption2Emphasized)
                            .foregroundStyle(DS.Color.secondaryText)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this format")
                    .accessibilityLabel("Remove \(format.fileExtension.uppercased())")
                    .accessibilityIdentifier("batch.format.\(format.fileExtension).delete")
                    .axLeaf("Export.Button.Remove.\(format.fileExtension)")
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
                            .accessibilityIdentifier("batch.format.\(format.fileExtension).toggle")
                            .axLeaf("Export.Toggle.WriteToSourceFolder.\(format.fileExtension)")
                    }
                    if format == .txt || format == .md || format == .html {
                        BatchSettingRow(
                            title: "Include timestamps",
                            description: "Writes start times alongside each segment."
                        ) {
                            Toggle("", isOn: includeTimestamps)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(DS.Color.accent)
                                .axLeaf("Export.Toggle.IncludeTimestamps.\(format.fileExtension)")
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

    private var formatLabel: String { format.displayName }

    private var writeToSourceFolder: Binding<Bool> {
        optionBinding(\.writeToSourceFolder)
    }

    private var includeTimestamps: Binding<Bool> {
        optionBinding(\.includeTimestamps)
    }

    private func optionBinding(_ keyPath: WritableKeyPath<BatchExportFormatOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.options(for: format)[keyPath: keyPath] },
            set: { newValue in
                var opts = model.options(for: format)
                opts[keyPath: keyPath] = newValue
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
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    @ViewBuilder var control: Control

    init(title: LocalizedStringKey, description: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

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
            control
        }
    }
}
