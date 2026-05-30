import AVFoundation
import SwiftUI
import ParolaCore

struct LiveCaptionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = LiveCaptionsState()
    @State private var session: StreamingTranscriptionSession?
    @State private var consumer: Task<Void, Never>?
    @State private var translate: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                if let error = state.error {
                    LiveCaptionsErrorCard(rawMessage: error) {
                        state.error = nil
                        Task { await start() }
                    }
                } else if state.displayedText.isEmpty {
                    Image(systemName: state.isLoading ? "arrow.down.circle" : "waveform")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(state.isLoading ? "Loading model…" : "Listening…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    Text(state.displayedText)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                Toggle("Translate to English", isOn: $translate)
                    .padding()
                    .background(.thinMaterial)
                    .onChange(of: translate) { _, _ in
                        restartIfNeeded()
                    }
            }
            .navigationTitle("Live Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await start() }
        .onDisappear { stop() }
    }

    private func restartIfNeeded() {
        guard state.isActive else { return }
        stop()
        Task { await start() }
    }

    private func start() async {
        guard session == nil else { return }
        configureAudioSession()
        state.reset()
        state.isActive = true
        state.isLoading = true

        let s = StreamingTranscriptionSession()
        session = s
        let options = TranscriptionOptions(
            model: model.settings.modelName,
            language: model.settings.language,
            task: translate ? .translate : .transcribe
        )
        consumer = Task { [weak session = s] in
            do {
                guard let session else { return }
                let events = try await session.start(options: options, downloadProgress: { _ in })
                await MainActor.run { state.isLoading = false }
                for await event in events {
                    await MainActor.run {
                        state.apply(event)
                    }
                }
            } catch {
                await MainActor.run {
                    state.error = error.localizedDescription
                    state.isActive = false
                    state.isLoading = false
                }
            }
        }
    }

    private func stop() {
        consumer?.cancel()
        consumer = nil
        if let s = session {
            Task { await s.stop() }
        }
        session = nil
        state.isActive = false
        state.isLoading = false
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: [])
        try? audioSession.setActive(true)
    }
}

private struct LiveCaptionsErrorCard: View {
    let rawMessage: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: humanError.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            VStack(spacing: 6) {
                Text(humanError.title)
                    .font(.headline)
                Text(humanError.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            Button(action: onRetry) {
                Text("Try again")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.orange.opacity(0.18))
                    )
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private var humanError: (title: String, subtitle: String, symbol: String) {
        let lower = rawMessage.lowercased()
        if lower.contains("compile") || lower.contains("mlmodelc") || lower.contains("unable to load model") {
            return ("Speech model not ready",
                    "The model is still downloading or hasn't finished compiling. Try again in a moment, or pick a smaller model in Settings.",
                    "arrow.down.circle")
        }
        if lower.contains("permission") || lower.contains("denied") || lower.contains("microphone") {
            return ("Microphone access needed",
                    "Live captions need microphone access. Open Settings and turn it on for Parola.",
                    "mic.slash")
        }
        if lower.contains("cancel") {
            return ("Captions stopped",
                    "The session ended before any audio was processed.",
                    "stop.circle")
        }
        if lower.contains("network") || lower.contains("offline") {
            return ("No connection",
                    "Some translation paths need a network connection. Try again once you're back online.",
                    "wifi.slash")
        }
        return ("Captions unavailable",
                "Something went wrong starting live captions. Try again in a moment.",
                "exclamationmark.triangle")
    }
}
