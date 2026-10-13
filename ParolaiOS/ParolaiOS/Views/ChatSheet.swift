import SwiftUI
import ParolaCore

struct ChatSheet: View {
    enum SenderFilter: String, CaseIterable, Identifiable {
        case all, you, assistant
        var id: Self { self }
        var label: String {
            switch self {
            case .all: return "All"
            case .you: return "You"
            case .assistant: return "Assistant"
            }
        }
        func includes(_ role: ChatMessage.Role) -> Bool {
            switch self {
            case .all: return true
            case .you: return role == .user
            case .assistant: return role == .assistant
            }
        }
    }

    let entry: LibraryEntry
    let transcript: Transcript
    var onSave: ((Transcript) -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: TranscriptChatSession?
    @State private var sessionError: String?
    @State private var turnError: String?
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var displayedHistory: [ChatMessage] = []
    @State private var query: String = ""
    @State private var senderFilter: SenderFilter = .all

    private var filteredHistory: [ChatMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayedHistory.filter { msg in
            guard senderFilter.includes(msg.role) else { return false }
            guard !trimmed.isEmpty else { return true }
            return msg.text.localizedCaseInsensitiveContains(trimmed)
        }
    }

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
                        senderFilterBar
                        messages
                        Divider()
                        composer
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search messages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await rebuildSession() }
    }

    private var senderFilterBar: some View {
        Picker("Sender", selection: $senderFilter) {
            ForEach(SenderFilter.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 8)
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
                    } else if filteredHistory.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(filteredHistory) { msg in
                        ChatBubble(message: msg).id(msg.id)
                    }
                    if isSending {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    } else if let turnError {
                        Label {
                            Text(verbatim: turnError)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .accessibilityLabel(Text("Send"))
            .disabled(isSendDisabled)
        }
        .padding()
    }

    private var isSendDisabled: Bool {
        Self.isSendDisabled(input: input, isSending: isSending)
    }

    static func isSendDisabled(input: String, isSending: Bool) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending
    }

    private func rebuildSession() async {
        sessionError = nil
        do {
            let s = try await TranscriptChat.makeSession(
                transcript: transcript,
                history: transcript.chatHistory ?? [],
                provider: .onDevice,
                digest: keptDigest()
            )
            guard !Task.isCancelled else { return }
            let history = await s.history
            guard !Task.isCancelled else { return }
            session = s
            displayedHistory = history
        } catch {
            guard !Task.isCancelled else { return }
            sessionError = FailureText.message(for: error)
        }
    }

    /// The summary a long chat is condensed around, written once and kept as the entry's summary.
    private func keptDigest() -> @Sendable () async throws -> Summary {
        let transcript = transcript
        let library = model.library
        let entryID = entry.id
        let refresh = onSave
        return { @MainActor in
            let written = try await SummaryService(budget: .onDevice).summarise(transcript)
            let saved = await Self.keep(digest: written, for: entryID, in: transcript, library: library)
            refresh?(saved)
            return saved.summary ?? written
        }
    }

    /// Saves a chat's digest as the entry's summary, leaving the chapters the entry already had.
    static func keep(digest written: Summary, for entryID: LibraryEntry.ID, in transcript: Transcript, library: LibraryStore) async -> Transcript {
        let chapters = transcript.chapters?.isEmpty == false ? transcript.chapters : written.chapters
        var kept = written
        kept.chapters = chapters ?? []
        try? await library.setSummary(kept, chapters: chapters, for: entryID)
        var saved = transcript
        saved.summary = kept
        saved.chapters = chapters
        return saved
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, !isSending else { return }
        input = ""
        isSending = true
        turnError = nil
        Task {
            do {
                _ = try await session.ask(text)
                let updated = await session.history
                displayedHistory = updated
                var saved = transcript
                saved.chatHistory = updated
                do {
                    try await model.library.setChatHistory(updated, for: entry.id)
                    // The detail view holds a pre-chat snapshot; without this refresh, its
                    // next save (reopened chat, speaker rename) erases this history on disk.
                    onSave?(saved)
                } catch {
                    model.lastError = FailureText.message(for: error)
                }
                isSending = false
            } catch {
                turnError = FailureText.message(for: error)
                isSending = false
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            bubble
            if message.role == .assistant { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role == .user ? "You" : "Assistant"): \(Self.displayText(message.text).isEmpty ? "No response" : message.text)")
    }

    private var bubble: some View {
        let shown = Self.displayText(message.text)
        return Group {
            if shown.isEmpty {
                Text("No response")
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(shown)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
