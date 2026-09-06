import SwiftUI
import ParolaCore

enum BatchProgress {
    /// Nothing queued or running means the batch is settled, and a frozen "3 of 3" would only add noise.
    static func counts(for jobs: [BatchJob]) -> (finished: Int, total: Int)? {
        guard jobs.contains(where: { $0.status == .pending || $0.status == .transcribing }) else { return nil }
        return (jobs.count { $0.status == .done }, jobs.count)
    }

    static func label(for jobs: [BatchJob]) -> String? {
        guard let counts = counts(for: jobs) else { return nil }
        return String(localized: "\(counts.finished) of \(counts.total)")
    }

    static func filesLabel(for jobs: [BatchJob], locale: Locale = AppFormat.locale) -> String? {
        guard !jobs.isEmpty else { return nil }
        if jobs.count == 1 { return String(localized: "1 file", locale: locale) }
        return String(localized: "\(jobs.count) files", locale: locale)
    }
}

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
        PageHeader(
            title: "Batch",
            count: BatchProgress.filesLabel(for: model.batchJobs),
            leading: {
                if let progress = BatchProgress.label(for: model.batchJobs) {
                    Text(progress)
                        .font(DS.Font.calloutMono)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.secondaryText)
                        .axLeaf("Header.Text.Progress")
                }
            },
            trailing: {
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
        )
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
