import SwiftUI
import UniformTypeIdentifiers
import ParolaCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "waveform") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.accentColor)
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var pickingFile = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Parola")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { pickingFile = true } label: { Image(systemName: "doc") }
                    }
                }
                .fileImporter(
                    isPresented: $pickingFile,
                    allowedContentTypes: [.audio, .movie],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        model.openFile(at: url)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .ready:
            steadyState
        case .downloadingModel(let name, let progress):
            ProgressPane(title: "Downloading \(name)", progress: progress)
        case .loadingModel(let name):
            ProgressPane(title: "Loading \(name)…", progress: nil)
        case .transcribing(let file):
            ProgressPane(title: "Transcribing \(file.lastPathComponent)…", progress: nil)
        case .recording:
            LiveRecordingView()
        case .failed(let message):
            ErrorView(message: message)
        }
    }

    @ViewBuilder
    private var steadyState: some View {
        if let transcript = model.transcript {
            TranscriptListView(transcript: transcript)
        } else {
            EmptyHomeView(pickFile: { pickingFile = true })
        }
    }
}

private struct EmptyHomeView: View {
    @EnvironmentObject var model: AppModel
    let pickFile: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Transcribe on-device")
                .font(.title2.weight(.semibold))
            Text("Pick an audio or video file, or tap the microphone to record.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            HStack(spacing: 16) {
                Button(action: pickFile) {
                    Label("Open File", systemImage: "doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button { model.toggleRecording() } label: {
                    Label("Record", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }
}

private struct ProgressPane: View {
    let title: String
    let progress: Double?
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(title).font(.headline)
            if let progress {
                ProgressView(value: progress).frame(width: 240)
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LiveRecordingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                Text("Recording")
                    .font(.headline)
                Spacer()
                Button("Finish") { model.toggleRecording() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.liveSegments) { seg in
                            Text(seg.text.trimmingCharacters(in: .whitespaces))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(seg.id)
                        }
                        if !model.livePartialText.isEmpty {
                            Text(model.livePartialText)
                                .foregroundStyle(.secondary.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("__partial")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.liveSegments.count) { _, _ in
                    proxy.scrollTo("__partial", anchor: .bottom)
                }
            }
        }
    }
}

private struct TranscriptListView: View {
    let transcript: Transcript
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(transcript.segments) { segment in
            VStack(alignment: .leading, spacing: 4) {
                Text(timestamp(segment.start))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(segment.text.trimmingCharacters(in: .whitespaces))
                    .font(.body)
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
        .navigationTitle("Transcript")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: transcript.text)
            }
        }
    }

    private func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let m = (total % 3600) / 60
        let sec = total % 60
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

private struct ErrorView: View {
    @EnvironmentObject var model: AppModel
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Try again") { model.phase = .idle }
                .buttonStyle(.bordered)
        }
    }
}
