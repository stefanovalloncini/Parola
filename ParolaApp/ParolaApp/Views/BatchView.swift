import SwiftUI
import ParolaCore

struct BatchView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("batch.exportPaneVisible", store: DefaultsStore.current) private var exportPaneVisible: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
        HStack(spacing: DS.Spacing.regular) {
            Button {
                model.route = .transcript
            } label: {
                Image(systemName: "chevron.left")
                    .font(DS.Font.bodyEmphasized)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Back")
            .accessibilityLabel("Back")
            .axLeaf("Header.Button.Back")

            Text("Batch")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.primaryText)

            Spacer()

            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    let isOn = model.batchExportFormats.contains(format)
                    Button {
                        if isOn {
                            model.removeBatchExportFormat(format)
                        } else {
                            model.addBatchExportFormat(format)
                        }
                    } label: {
                        if isOn {
                            Label(format.fileExtension.uppercased(), systemImage: "checkmark")
                        } else {
                            Text(format.fileExtension.uppercased())
                        }
                    }
                    .axLeaf("Header.MenuItem.Format.\(format.fileExtension)")
                }
            } label: {
                Label("Add Format", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
            .help("Choose which formats to write next to each transcribed file.")
            .accessibilityIdentifier("batch.addFormat")
            .axLeaf("Header.Menu.AddFormat")

            Button {
                exportPaneVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(exportPaneVisible ? DS.Color.accent : DS.Color.secondaryText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(exportPaneVisible ? "Hide export options" : "Show export options")
            .accessibilityLabel(exportPaneVisible ? "Hide export options" : "Show export options")
            .axLeaf("Header.Button.ToggleExportPane")
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }

    private var queuePane: some View {
        ZStack {
            if model.batchJobs.isEmpty {
                BatchEmptyState()
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
