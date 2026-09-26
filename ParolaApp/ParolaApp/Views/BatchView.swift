import SwiftUI
import ParolaCore

struct BatchView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("batch.exportPaneVisible", store: DefaultsStore.current) private var exportPaneVisible: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let checking = model.batchCheckingNotice {
                checkingNotice(checking)
                Divider()
            }
            if let notice = model.batchDuplicateNotice {
                duplicateNotice(notice)
                Divider()
            }
            // Not an HSplitView: it lays out at its panes' combined ideal width and clips both window edges.
            HStack(spacing: 0) {
                queuePane
                    .frame(minWidth: MainWindowLayout.batchQueueMinWidth, maxWidth: .infinity)
                if exportPaneVisible {
                    Divider()
                    exportPane
                        .frame(width: MainWindowLayout.batchExportPaneWidth)
                }
            }
        }
        .axBranch("Batch")
    }

    private var header: some View {
        let caption = BatchProgress.headerLabel(for: model.batchJobs)
        return PageHeader(
            title: "Batch",
            subtitle: caption?.text,
            subtitleAxID: caption?.isProgress == true ? "Header.Text.Progress" : nil,
            trailing: {
                Menu {
                    ForEach(model.exportPresets) { preset in
                        let isOn = model.batchExportPresetIDs.contains(preset.id)
                        Button {
                            model.toggleBatchExportPreset(preset.id)
                        } label: {
                            if isOn {
                                Label {
                                    ExportPresetChecks.label(preset)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                ExportPresetChecks.label(preset)
                            }
                        }
                        .axLeaf("Header.MenuItem.Preset.\(ExportPresetChecks.slug(preset))")
                    }
                } label: {
                    Label("Add Preset", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.button)
                .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                .help("Choose which presets Parola writes next to each transcribed file.")
                .accessibilityIdentifier("batch.addFormat")
                .axLeaf("Header.Menu.AddPreset")

                Button {
                    exportPaneVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(exportPaneVisible ? DS.Color.accent : DS.Color.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(exportPaneVisible ? "Hide export options" : "Show export options")
                .accessibilityLabel(exportPaneVisible ? "Hide export options" : "Show export options")
                .axLeaf("Header.Button.ToggleExportPane")
            }
        )
    }

    private func checkingNotice(_ text: String) -> some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.subtleFill)
        .axLeaf("Batch.Text.CheckingFiles")
    }

    private func duplicateNotice(_ text: String) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(DS.Color.secondaryText)
            Text(text)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.subtleFill)
        .axLeaf("Batch.Text.DuplicatesSkipped")
    }

    private var queuePane: some View {
        ZStack {
            if model.batchJobs.isEmpty {
                // The notice above says what is happening; an empty state would invite a second drop.
                if model.batchFilesBeingChecked == 0 { BatchEmptyState() }
            } else {
                BatchJobList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface)
    }

    private var exportPane: some View {
        BatchExportPanel()
            .background(DS.Color.surfaceElevated)
    }
}
