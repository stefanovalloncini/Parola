import SwiftUI
import ParolaCore

struct NewTranscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    @State private var pickingFile = false
    @State private var becameBusy = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.coordinator.phase {
                case .idle:
                    actions
                case .recording:
                    LiveRecordingPane()
                case .failed:
                    VStack(spacing: 12) {
                        StatusBanner(phase: model.coordinator.phase)
                        Button("newtranscription.retry") { model.coordinator.reset() }
                    }
                default:
                    VStack(spacing: 12) {
                        StatusBanner(phase: model.coordinator.phase)
                        ProgressView()
                    }
                }
            }
            .padding(.vertical)
            .navigationTitle(Text("newtranscription.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        model.coordinator.cancelRecording()
                        model.coordinator.reset()
                        dismiss()
                    }
                }
            }
            .onChange(of: model.coordinator.phase) { _, phase in
                switch phase {
                case .idle:
                    if becameBusy { dismiss() }
                case .failed:
                    break
                default:
                    becameBusy = true
                }
            }
            .fileImporter(
                isPresented: $pickingFile,
                allowedContentTypes: [.audio, .movie],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.coordinator.startFileTranscription(at: url)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 16) {
            Button {
                pickingFile = true
            } label: {
                Label("newtranscription.pickfile", systemImage: "doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                model.coordinator.startRecording()
            } label: {
                Label("newtranscription.record", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.horizontal)
    }
}

private struct LiveRecordingPane: View {
    @EnvironmentObject var model: AppModel

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        if !model.coordinator.livePartialText.isEmpty {
            proxy.scrollTo("__partial", anchor: .bottom)
        } else if let last = model.coordinator.liveSegments.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("newtranscription.recording").font(.headline)
                Spacer()
                Button("newtranscription.finish") { model.coordinator.stopRecording() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.coordinator.liveSegments) { seg in
                            Text(seg.text.trimmingCharacters(in: .whitespaces))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(seg.id)
                        }
                        if !model.coordinator.livePartialText.isEmpty {
                            Text(model.coordinator.livePartialText)
                                .foregroundStyle(.secondary.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("__partial")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.coordinator.liveSegments.count) { _, _ in
                    scrollToTail(proxy)
                }
                .onChange(of: model.coordinator.livePartialText) { _, _ in
                    scrollToTail(proxy)
                }
            }
        }
    }
}
