import SwiftUI
import ParolaCore

struct BatchView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("batch.exportPaneVisible", store: DefaultsStore.current) private var exportPaneVisible: Bool = true
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            BatchImportNotices()
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
        .toolbarSearch(text: $searchText, for: .batch)
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
                    BatchExportMenuItems(model: model)
                } label: {
                    HStack(spacing: DS.Spacing.tight) {
                        Text("Export As")
                        Image(systemName: "chevron.down")
                            .font(DS.Font.caption)
                            .accessibilityHidden(true)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .menuIndicator(.hidden)
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

    private var queuePane: some View {
        ZStack {
            if model.batchJobs.isEmpty {
                // The notice above says what is happening; an empty state would invite a second drop.
                if model.batchFilesBeingChecked == 0 { BatchEmptyState() }
            } else {
                BatchJobList(searchText: $searchText)
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

/// One switch per preset: the menu turns them off as well as on, so each carries its tick.
struct BatchExportMenuItems: View {
    let model: AppModel

    var body: some View {
        ForEach(model.exportPresets) { preset in
            Toggle(isOn: Binding(
                get: { model.batchExportPresetIDs.contains(preset.id) },
                set: { _ in model.toggleBatchExportPreset(preset.id) }
            )) {
                ExportPresetChecks.label(preset)
            }
            .axLeaf("Header.MenuItem.Preset.\(ExportPresetChecks.slug(preset))")
        }
    }
}
