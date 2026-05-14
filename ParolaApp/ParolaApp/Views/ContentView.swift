import SwiftUI
import AVKit
import ParolaCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            Divider()

            content
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: model.pendingExport) { _, format in
            if let format {
                model.performExport(format)
                model.pendingExport = nil
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            ModelPickerView()
            LanguagePickerView()
            Toggle("Translate", isOn: $model.translate)
                .toggleStyle(.switch)
                .help("Translate to English instead of transcribing in the source language.")

            Spacer()

            Menu {
                Button("Microphone") { model.startRecording(source: .microphone) }
                Button("System audio") { model.startRecording(source: .systemAudio) }
            } label: {
                Label("Record", systemImage: "mic.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy)

            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open File", systemImage: "doc")
            }
            .disabled(isBusy)
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.transcribe(fileURL: url) }
        }
        return true
    }
}

// MARK: - Empty state

struct EmptyDropZone: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                Text("Drop an audio or video file here")
                    .font(.title2)
                Text("or use the toolbar to open a file or start recording.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Progress

struct ProgressPane: View {
    let title: String
    let progress: Double?
    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recording

struct RecordingPane: View {
    let source: AppModel.RecordSource
    @EnvironmentObject var model: AppModel
    @State private var elapsed: Double = 0
    @State private var startedAt: Date = Date()

    private var isStreaming: Bool { source == .microphone && model.useStreaming }
    private var stopButtonLabel: String { isStreaming ? "Finish" : "Stop and Transcribe" }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(model.liveVoiceActive ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: model.liveVoiceActive)
                VStack(alignment: .leading) {
                    Text("Recording from \(source.label)")
                        .font(.headline)
                    Text(String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(stopButtonLabel) {
                    model.stopRecordingAndTranscribe()
                }
                .controlSize(.large)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal)
            .padding(.top)

            if isStreaming {
                Divider()
                LiveTranscriptView()
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }
}

struct LiveTranscriptView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.liveSegments) { seg in
                        Text(seg.text.trimmingCharacters(in: .whitespaces))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(seg.id)
                    }
                    if !model.livePartialText.isEmpty {
                        Text(model.livePartialText)
                            .foregroundStyle(.secondary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("__partial")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .onChange(of: model.liveSegments.count) { _, _ in
                proxy.scrollTo("__partial", anchor: .bottom)
            }
            .onChange(of: model.livePartialText) { _, _ in
                proxy.scrollTo("__partial", anchor: .bottom)
            }
        }
    }
}

// MARK: - Error

struct ErrorPane: View {
    let message: String
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Button("Try again") { model.phase = .idle }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
