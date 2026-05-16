import SwiftUI
import AVKit
import ParolaCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingTrash = false

    var body: some View {
        NavigationSplitView {
            MacLibrarySidebar()
        } detail: {
            content
                .dropDestination(for: URL.self) { urls, _ in
                    handleDroppedURLs(urls)
                    return !urls.isEmpty
                }
                .onChange(of: model.pendingExport) { _, format in
                    if let format {
                        model.performExport(format)
                        model.pendingExport = nil
                    }
                }
                .toolbar { toolbarItems }
        }
        .sheet(isPresented: $model.youtubeSheetOpen) { YouTubeURLSheet() }
        .sheet(isPresented: $showingTrash) { MacRecentlyDeletedView() }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ModelPickerView()
            LanguagePickerView()
            Toggle(isOn: $model.translate) {
                HStack(spacing: 4) {
                    Image(systemName: "character.bubble")
                    Text("Translate")
                }
            }
            .toggleStyle(.button)
            .help("Translate to English instead of transcribing in the source language.")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.deletedEntries.isEmpty {
                Button { showingTrash = true } label: {
                    Label("Recently Deleted", systemImage: "trash")
                }
                .help("Show Recently Deleted")
            }
            Button {
                model.youtubeSheetOpen = true
            } label: {
                Label("YouTube URL", systemImage: "play.rectangle.on.rectangle")
            }
            .disabled(isBusy)
            .help("Transcribe from a YouTube URL.")

            Menu {
                Button("Microphone") { model.startRecording(source: .microphone) }
                Button("System audio") { model.startRecording(source: .systemAudio) }
            } label: {
                Label("Record", systemImage: "mic.fill")
            }
            .disabled(isBusy)
            .help("Record from the microphone or system audio.")

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open File", systemImage: "doc.badge.plus")
            }
            .disabled(isBusy)
            .help("Open an audio or video file.")
        }
    }

    private var isBusy: Bool {
        switch model.phase {
        case .idle, .ready, .failed: return false
        default: return true
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        if !model.batchJobs.isEmpty {
            HSplitView {
                BatchSidebar()
                    .frame(minWidth: 240, idealWidth: 280)
                if model.transcript != nil {
                    TranscriptPane()
                } else {
                    ProgressPane(title: "Transcribing batch…", progress: nil)
                }
            }
        } else {
            switch model.phase {
            case .idle:
                EmptyDropZone()
            case .downloadingModel(let name, let progress):
                ProgressPane(title: "Downloading \(name)", progress: progress)
            case .loadingModel(let name):
                ProgressPane(title: "Loading \(name)…", progress: nil)
            case .transcribing(let file):
                ProgressPane(title: "Transcribing \(file.lastPathComponent)…", progress: nil)
            case .recording(let source):
                RecordingPane(source: source)
            case .ready:
                TranscriptPane()
            case .failed(let message):
                ErrorPane(message: message)
            }
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            model.transcribe(fileURL: urls[0])
        } else {
            model.startBatch(urls: urls)
        }
    }
}

// MARK: - Empty state

struct EmptyDropZone: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Drop an audio or video file", systemImage: "waveform")
        } description: {
            Text("Pick a source to start transcribing on-device.")
        } actions: {
            HStack(spacing: DS.Spacing.small) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Choose File…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()

                Menu {
                    Button("Microphone") { model.startRecording(source: .microphone) }
                    Button("System audio") { model.startRecording(source: .systemAudio) }
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .menuStyle(.borderedButton)
                .controlSize(.large)
                .fixedSize()

                Button {
                    model.youtubeSheetOpen = true
                } label: {
                    Label("YouTube URL", systemImage: "play.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .fixedSize()
            }
        }
    }
}

// MARK: - Progress

struct ProgressPane: View {
    let title: String
    let progress: Double?
    var body: some View {
        VStack(spacing: DS.Spacing.regular) {
            Text(title)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(width: 280)
                Text("\(Int(progress * 100))%")
                    .font(DS.Font.captionMono)
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(DS.Color.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recording

struct RecordingPane: View {
    let source: AppModel.RecordSource
    @EnvironmentObject var model: AppModel
    @State private var startedAt: Date = Date()

    private var isStreaming: Bool { source == .microphone && model.useStreaming }
    private var stopButtonLabel: String { isStreaming ? "Finish" : "Stop and Transcribe" }

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            HStack(spacing: DS.Spacing.regular) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(model.liveVoiceActive ? DS.Color.accent : DS.Color.secondaryText)
                    .symbolEffect(.pulse, isActive: model.liveVoiceActive)
                VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                    Text("Recording from \(source.label)")
                        .font(DS.Font.heading)
                    ElapsedTimer(startedAt: startedAt)
                }
                Spacer()
                Button(stopButtonLabel) {
                    model.stopRecordingAndTranscribe()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(DS.Color.accent)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.top, DS.Spacing.large)

            if isStreaming {
                Divider()
                LiveTranscriptView()
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startedAt = Date() }
    }
}

private struct ElapsedTimer: View {
    let startedAt: Date
    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startedAt))
            Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                .font(DS.Font.timer)
                .foregroundStyle(DS.Color.secondaryText)
                .monospacedDigit()
        }
    }
}

struct LiveTranscriptView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    ForEach(model.liveSegments) { seg in
                        Text(seg.text.trimmingCharacters(in: .whitespaces))
                            .font(DS.Font.transcript)
                            .foregroundStyle(DS.Color.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(seg.id)
                    }
                    if !model.livePartialText.isEmpty {
                        Text(model.livePartialText)
                            .font(DS.Font.transcript)
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("__partial")
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.bottom, DS.Spacing.large)
            }
            .onChange(of: model.liveSegments.count) { _, _ in
                scrollToTail(proxy)
            }
            .onChange(of: model.livePartialText) { _, _ in
                scrollToTail(proxy)
            }
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        if !model.livePartialText.isEmpty {
            proxy.scrollTo("__partial", anchor: .bottom)
        } else if let last = model.liveSegments.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

// MARK: - Error

struct ErrorPane: View {
    let message: String
    @EnvironmentObject var model: AppModel
    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { model.dismissError() }
                .buttonStyle(.bordered)
        }
    }
}
