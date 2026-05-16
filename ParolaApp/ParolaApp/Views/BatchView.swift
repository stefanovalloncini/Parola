import SwiftUI
import UniformTypeIdentifiers
import ParolaCore

struct BatchView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropping: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                queuePane
                    .frame(minWidth: 360, idealWidth: 560)
                exportPane
                    .frame(minWidth: 280, idealWidth: 380)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.regular) {
            Button {
                model.route = .transcript
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Back")

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
                }
            } label: {
                Label("Add Format", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .tint(DS.Color.accent)
            .controlSize(.regular)
            .help("Choose which formats to write next to each transcribed file.")
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.regular)
    }

    private var queuePane: some View {
        ZStack {
            if model.batchJobs.isEmpty {
                BatchEmptyState(isDropping: isDropping)
            } else {
                BatchJobList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.surface)
        .overlay {
            if isDropping {
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .strokeBorder(DS.Color.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    .padding(DS.Spacing.medium)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addBatchFiles(urls.filter(Self.isMediaURL))
            return true
        } isTargeted: { hovering in
            isDropping = hovering
        }
    }

    private var exportPane: some View {
        BatchExportPanel()
            .background(DS.Color.surfaceElevated)
    }

    static func isMediaURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}
