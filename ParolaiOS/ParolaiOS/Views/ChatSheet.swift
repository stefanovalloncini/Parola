import SwiftUI
import ParolaCore

struct ChatSheet: View {
    let entry: LibraryEntry
    let transcript: Transcript
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var session: TranscriptChatSession?
    @State private var sessionError: String?
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var displayedHistory: [ChatMessage] = []

    var body: some View {
        NavigationStack {
            Group {
                if let error = sessionError {
                    ContentUnavailableView(
                        "Chat unavailable",
                        systemImage: "exclamationmark.bubble",
                        description: Text(error)
                    )
                } else if session == nil {
                    ProgressView()
                } else {
                    VStack(spacing: 0) {
                        messages
                        Divider()
                        composer
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await rebuildSession() }
    }

    @ViewBuilder
    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if displayedHistory.isEmpty {
                        Text("Ask anything about the transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(displayedHistory) { msg in
                        ChatBubble(message: msg).id(msg.id)
                    }
                    if isSending {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding()
            }
            .onChange(of: displayedHistory.count) { _, _ in
                if let last = displayedHistory.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this transcript…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
        }
        .padding()
    }

    private func rebuildSession() async {
        sessionError = nil
        do {
            let s = try TranscriptChat.makeSession(
                transcript: transcript,
                history: transcript.chatHistory ?? []
            )
            session = s
            displayedHistory = await s.history
        } catch {
            sessionError = error.localizedDescription
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, !isSending else { return }
        input = ""
        isSending = true
        Task {
            do {
                _ = try await session.ask(text)
                let updated = await session.history
                displayedHistory = updated
                var saved = transcript
                saved.chatHistory = updated
                try? await model.library.updateTranscript(saved, for: entry.id)
                isSending = false
            } catch {
                sessionError = error.localizedDescription
                isSending = false
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
