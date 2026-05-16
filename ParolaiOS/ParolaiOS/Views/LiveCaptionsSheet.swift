import AVFoundation
import SwiftUI
import ParolaCore

struct LiveCaptionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var state = LiveCaptionsState()
    @State private var session: StreamingTranscriptionSession?
    @State private var consumer: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                if let error = state.error {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else if state.displayedText.isEmpty {
                    Image(systemName: "waveform")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text("Listening…")
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

    private func start() async {
        guard session == nil else { return }
        configureAudioSession()
        state.reset()
        state.isActive = true

        let s = StreamingTranscriptionSession()
        session = s
        let options = TranscriptionOptions(
            model: model.settings.modelName,
            language: model.settings.language,
            task: .transcribe
        )
        consumer = Task { [weak session = s] in
            do {
                guard let session else { return }
                let events = try await session.start(options: options, downloadProgress: { _ in })
                for await event in events {
                    await MainActor.run {
                        state.apply(event)
                    }
                }
            } catch {
                await MainActor.run {
                    state.error = error.localizedDescription
                    state.isActive = false
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
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: [])
        try? audioSession.setActive(true)
    }
}
