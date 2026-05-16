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
                .modifier(HideToolbarTitleIfAvailable())
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
    @State private var showingTrash = false
    @Environment(\.openSettings) private var openSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.regular), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Spacing.regular) {
                    ActionCard(
                        title: "Open File",
                        systemImage: "folder.fill.badge.plus",
                        action: { model.presentOpenPanel() }
                    )
                    ActionCard(
                        title: "Record Mic",
                        systemImage: "mic.fill",
                        action: { model.startRecording(source: .microphone) }
                    )
                    ActionCard(
                        title: "Record System Audio",
                        systemImage: "waveform.circle.fill",
                        action: { model.startRecording(source: .systemAudio) }
                    )
                    ActionCard(
                        title: "Live Captions",
                        systemImage: "captions.bubble.fill",
                        action: { model.toggleLiveCaptions() }
                    )
                    ActionCard(
                        title: "Dictation",
                        systemImage: "text.cursor",
                        action: { model.startDictationFromIntent() }
                    )
                    ActionCard(
                        title: "Manage Models",
                        systemImage: "cpu.fill",
                        action: { openSettings() }
                    )
                    ActionCard(
                        title: "YouTube URL",
                        systemImage: "play.rectangle.fill",
                        action: { model.youtubeSheetOpen = true }
                    )
                    ActionCard(
                        title: "Recently Deleted",
                        systemImage: "trash.fill",
                        isEnabled: !model.deletedEntries.isEmpty,
                        action: { showingTrash = true }
                    )
                }

                if model.libraryEntries.isEmpty {
                    VStack(spacing: DS.Spacing.regular) {
                        Image(systemName: "clock")
                            .font(.system(size: 48, weight: .regular))
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.55))
                        Text("No Transcriptions Yet")
                            .font(DS.Font.heading)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.xlarge)
                }
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingTrash) { MacRecentlyDeletedView() }
    }
}

struct ActionCard: View {
    let title: String
    let systemImage: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                    .frame(height: 28, alignment: .leading)
                Spacer(minLength: 0)
                Text(title)
                    .font(DS.Font.body)
                    .fontWeight(.medium)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.regular)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DS.Color.separator.opacity(isHovering ? 0.9 : 0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            guard isEnabled else { return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(title)
    }

    private var cardBackground: some View {
        DS.Color.surfaceElevated
            .overlay(SwiftUI.Color.white.opacity(isHovering ? 0.04 : 0))
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

private struct HideToolbarTitleIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
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
