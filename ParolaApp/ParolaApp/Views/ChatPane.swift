import SwiftUI
import ParolaCore

struct ChatPane: View {
    @EnvironmentObject var model: AppModel
    @State private var session: TranscriptChatSession?
    @State private var sessionError: String?
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var displayedHistory: [ChatMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            if let error = sessionError {
                ContentUnavailableView(
                    "Chat unavailable",
                    systemImage: "exclamationmark.bubble",
                    description: Text(error)
                )
            } else if session == nil {
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Open a transcript to start chatting.")
                )
            } else {
                messages
                Divider()
                composer
            }
        }
        .task(id: model.transcript) { await rebuildSession() }
    }

    @ViewBuilder
    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.regular) {
                    if displayedHistory.isEmpty {
                        Text("Ask anything about the transcript.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, DS.Spacing.large)
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
                .padding(DS.Spacing.regular)
            }
            .onChange(of: displayedHistory.count) { _, _ in
                if let last = displayedHistory.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.small) {
            TextField("Ask about this transcript…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DS.Color.accent)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(DS.Spacing.regular)
    }

    private func rebuildSession() async {
        sessionError = nil
        session = nil
        displayedHistory = []
        guard let transcript = model.transcript else { return }
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
                model.recordChat(history: updated)
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
                .background(message.role == .user ? DS.Color.accent.opacity(0.18) : DS.Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
