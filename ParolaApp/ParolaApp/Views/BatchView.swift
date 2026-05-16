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
        BatchExportPane()
            .background(DS.Color.surfaceElevated)
    }

    static func isMediaURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}

private enum MediaKind {
    case audio
    case video

    init(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            self = .audio
            return
        }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            self = .video
        } else {
            self = .audio
        }
    }
}

private struct BatchEmptyState: View {
    @EnvironmentObject var model: AppModel
    let isDropping: Bool

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(DS.Color.secondaryText.opacity(0.55))
                .padding(.bottom, DS.Spacing.small)

            Text("Batch Mode.")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .foregroundStyle(DS.Color.primaryText)

            Text("Transcribe and export multiple files at once.\nSelect files to transcribe or drag them onto the app to continue.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.presentBatchOpenPanel()
            } label: {
                Text("Open Files")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.small)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Color.accent)
            .controlSize(.large)
            .padding(.top, DS.Spacing.small)
        }
        .frame(maxWidth: 460)
        .padding(DS.Spacing.large)
        .opacity(isDropping ? 0.4 : 1)
    }
}

private struct BatchJobList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.batchJobs.count) file\(model.batchJobs.count == 1 ? "" : "s")")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Button("Clear") { model.clearBatch() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.batchJobs.allSatisfy { $0.status == .transcribing })
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.top, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)

            ScrollView {
                LazyVStack(spacing: DS.Spacing.small) {
                    ForEach(model.batchJobs) { job in
                        BatchJobRow(job: job)
                            .onTapGesture { model.selectBatchJob(job.id) }
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.bottom, DS.Spacing.large)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    model.presentBatchOpenPanel()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.bottom, DS.Spacing.regular)
        }
    }
}

private struct BatchJobRow: View {
    @EnvironmentObject var model: AppModel
    let job: BatchJob

    private var kind: MediaKind { MediaKind(url: job.url) }

    private var iconBackground: Color {
        switch kind {
        case .video: return Color(red: 0.30, green: 0.62, blue: 0.42)
        case .audio: return Color(red: 0.24, green: 0.62, blue: 0.66)
        }
    }

    private var iconSymbol: String {
        switch kind {
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        }
    }

    private var statusText: String {
        switch job.status {
        case .pending: return "Queued"
        case .transcribing:
            return job.progress > 0
                ? "Transcribing \(Int(job.progress * 100))%"
                : "Transcribing…"
        case .done: return "Complete"
        case .failed: return job.error ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending: return DS.Color.secondaryText
        case .transcribing: return DS.Color.accent
        case .done: return Color(red: 0.36, green: 0.66, blue: 0.46)
        case .failed: return DS.Color.danger
        case .cancelled: return DS.Color.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            iconSquare
            VStack(alignment: .leading, spacing: 6) {
                Text(job.url.lastPathComponent)
                    .font(DS.Font.body.weight(.medium))
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                progressBar
                Text(statusText)
                    .font(DS.Font.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: DS.Spacing.small)
            cancelButton
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                        .strokeBorder(
                            model.selectedBatchJobID == job.id ? DS.Color.accent.opacity(0.5) : DS.Color.separator.opacity(0.4),
                            lineWidth: model.selectedBatchJobID == job.id ? 1.5 : 0.5
                        )
                )
        }
        .contentShape(Rectangle())
    }

    private var iconSquare: some View {
        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            .fill(iconBackground)
            .frame(width: 32, height: 32)
            .overlay {
                Image(systemName: iconSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch job.status {
        case .pending:
            EmptyView()
        case .transcribing:
            if job.progress > 0 {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(height: 3)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(height: 3)
            }
        case .done:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(statusColor)
                .frame(height: 3)
        case .failed:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(DS.Color.danger)
                .frame(height: 3)
        case .cancelled:
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(DS.Color.secondaryText)
                .frame(height: 3)
        }
    }

    private var cancelButton: some View {
        Button {
            model.cancelBatchJob(job.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(DS.Color.separator.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .help(job.status == .transcribing ? "Cancel" : "Remove")
    }
}

private struct BatchExportPane: View {
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

private struct BatchFormatCard: View {
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
                    FormatChip(extension: format.fileExtension)
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
                        Toggle("", isOn: $model.batchExportToSourceFolder)
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
                            Toggle("", isOn: $model.batchExportIncludeTimestamps)
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
}

private struct FormatChip: View {
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

private struct BatchSettingRow<Control: View>: View {
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
