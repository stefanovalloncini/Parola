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
        .sheet(item: $model.promptOutput) { output in
            PromptOutputSheet(output: output)
        }
        .sheet(isPresented: $model.showingSpeakersSheet) {
            if let transcript = model.transcript {
                SpeakersSheet(transcript: transcript)
            }
        }
        .alert(
            "\(model.meetingDetectedApp ?? "") just launched",
            isPresented: Binding(
                get: { model.meetingDetectedApp != nil },
                set: { if !$0 { model.dismissMeetingPrompt() } }
            )
        ) {
            Button("Record this meeting") { model.startMeetingRecording() }
            Button("Not now", role: .cancel) { model.dismissMeetingPrompt() }
        } message: {
            Text("Start a system-audio recording? The result lands in your library as a Meeting.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .parolaOpenEntry)) { note in
            if let id = note.userInfo?["id"] as? String {
                model.selectedEntryID = id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parolaStartDictation)) { _ in
            model.startDictationFromIntent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parolaStopDictation)) { _ in
            model.stopDictationFromIntent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parolaStartRecording)) { _ in
            model.startRecording(source: .microphone)
        }
        .onReceive(NotificationCenter.default.publisher(for: .parolaSummarizeLast)) { _ in
            model.summarizeLatestEntry()
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ModelPickerView()
            LanguagePickerView()
                .disabled(selectedModelIsEnglishOnly)
                .help(selectedModelIsEnglishOnly ? "This model is English-only." : "")
            if selectedModelSupportsTranslate {
                Toggle(isOn: $model.translate) {
                    HStack(spacing: 4) {
                        Image(systemName: "character.bubble")
                        Text("Translate")
                    }
                }
                .toggleStyle(.button)
                .help("Translate to English instead of transcribing in the source language.")
            }
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

            PromptsMenu()
                .disabled(model.transcript == nil || model.isRunningPrompt)

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open File", systemImage: "doc.badge.plus")
            }
            .disabled(isBusy)
            .help("Open an audio or video file.")
        }
    }

    private var selectedModelCapabilities: EngineCapabilities {
        ModelCatalog.staticCapabilities(forID: model.selectedModel) ?? .whisperKitDefaults
    }
    private var selectedModelIsEnglishOnly: Bool {
        selectedModelCapabilities.supportedLanguages.isEnglishOnly
    }
    private var selectedModelSupportsTranslate: Bool {
        selectedModelCapabilities.supportsTranslate
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
    private var stateLabel: String { model.liveVoiceActive ? "Listening" : "Standing by" }
    private var stopTitle: String { isStreaming ? "Finish" : "Stop" }

    @ViewBuilder
    private var card: some View {
        RecordingCard(
            stateLabel: stateLabel,
            source: source,
            startedAt: startedAt,
            isVoiceActive: model.liveVoiceActive,
            stopTitle: stopTitle,
            onStop: { model.stopRecordingAndTranscribe() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if isStreaming {
                card
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.top, DS.Spacing.large)
                    .padding(.bottom, DS.Spacing.medium)
                Divider()
                LiveTranscriptView()
            } else {
                card.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startedAt = Date() }
    }
}

private struct RecordingCard: View {
    let stateLabel: String
    let source: AppModel.RecordSource
    let startedAt: Date
    let isVoiceActive: Bool
    let stopTitle: String
    let onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: DS.Spacing.large) {
            ZStack {
                Circle()
                    .fill(DS.Color.accent.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "mic.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                    .scaleEffect(pulse ? 1.05 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulse
                    )
            }

            VStack(spacing: DS.Spacing.small) {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(DS.Font.timer)
                        .foregroundStyle(DS.Color.primaryText)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(isVoiceActive ? DS.Color.accent : DS.Color.secondaryText.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(stateLabel)
                        .font(DS.Font.heading)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                Text(source.label)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText.opacity(0.7))
            }

            Button(action: onStop) {
                Text(stopTitle)
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 36)
                    .background(
                        Capsule().fill(Color.red.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return)
        }
        .padding(32)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.6), lineWidth: 1)
        )
        .onAppear { pulse = true }
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
