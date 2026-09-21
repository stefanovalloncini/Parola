import SwiftUI
import ParolaCore

struct BatchExportPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                Text("Export Presets")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                    .padding(.top, DS.Spacing.regular)

                if model.batchExportPresets.isEmpty {
                    VStack(spacing: DS.Spacing.small) {
                        InlineEmptyText("No presets selected")
                        Text("Use Add Preset above to pick the files Parola writes next to each transcribed audio or video.")
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, DS.Spacing.regular)
                    .padding(.bottom, DS.Spacing.regular)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                            .fill(DS.Color.surface)
                    )
                } else {
                    ForEach(model.batchExportPresets) { preset in
                        BatchPresetCard(preset: preset)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.bottom, DS.Spacing.large)
        }
    }
}

struct BatchPresetCard: View {
    @Environment(AppModel.self) private var model
    let preset: ExportPreset

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Text(LocalizedStringKey(preset.name))
                .font(DS.Font.body.weight(.semibold))
                .foregroundStyle(DS.Color.primaryText)
            BatchFormatChip(extension: preset.spec.format.fileExtension)
            Spacer()
            Button {
                model.toggleBatchExportPreset(preset.id)
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Remove this preset")
            .accessibilityLabel("Remove \(preset.name)")
            .accessibilityIdentifier("batch.preset.\(preset.spec.format.fileExtension).delete")
            .axLeaf("Export.Button.Remove.\(ExportPresetChecks.slug(preset))")
        }
        .padding(DS.Spacing.regular)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surface)
        )
    }
}

struct BatchFormatChip: View {
    let `extension`: String

    var body: some View {
        Text(".\(`extension`)")
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, DS.Spacing.snug)
            .padding(.vertical, DS.Spacing.hair)
            .background(
                Capsule().fill(DS.Color.separator.opacity(0.4))
            )
    }
}
