import SwiftUI
import ParolaCore

struct ChatPane: View {
    @EnvironmentObject var model: AppModel
    @State private var session: TranscriptChatSession?
    @State private var sessionError: String?
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var displayedHistory: [ChatMessage] = []
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @State private var senderFilter: ChatSenderFilter = .all
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if isSearching {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .background(DS.Color.surface)
        .task(id: model.transcript) { await rebuildSession() }
    }

    private var header: some View {
        HStack {
            Text("Chat")
                .font(DS.Font.heading)
            Spacer()
            Button(action: toggleSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSearching ? DS.Color.accent : DS.Color.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Search chat (⌘F)")
            .keyboardShortcut("f", modifiers: [.command])

            Button(role: .destructive, action: resetConversation) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Color.secondaryText)
            .help("Clear conversation")
            .disabled(displayedHistory.isEmpty || isSending)
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.regular)
    }

    private var searchBar: some View {
        HStack(spacing: DS.Spacing.small) {
            ChatSearchPill {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                TextField("Filter messages", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }

            ChatSenderChip(selection: $senderFilter)

            Button(action: toggleSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close search")
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
        .background(DS.Color.surface)
    }

    @ViewBuilder
    private var content: some View {
        if let error = sessionError {
            ChatUnavailable(message: error)
        } else if session == nil {
            ChatEmpty()
        } else {
            messages
            composer
        }
    }

    private var filteredHistory: [ChatMessage] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayedHistory.filter { msg in
            guard senderFilter.matches(msg.role) else { return false }
            if trimmed.isEmpty { return true }
            return msg.text.range(of: trimmed, options: .caseInsensitive) != nil
        }
    }

    private var hasActiveFilter: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || senderFilter != .all
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let visible = filteredHistory
                    if displayedHistory.isEmpty {
                        ChatHint()
                            .padding(.top, DS.Spacing.xlarge)
                    } else if hasActiveFilter && visible.isEmpty {
                        ContentUnavailableView.search(text: searchQuery)
                            .padding(.top, DS.Spacing.xlarge)
                    }
                    ForEach(visible) { msg in
                        ChatBubble(message: msg).id(msg.id)
                    }
                    if isSending {
                        ThinkingIndicator()
                            .id("thinking")
                    }
                }
                .padding(.horizontal, DS.Spacing.medium)
                .padding(.vertical, DS.Spacing.regular)
            }
            .onChange(of: displayedHistory.count) { _, _ in
                scrollToEnd(proxy: proxy)
            }
            .onChange(of: isSending) { _, sending in
                if sending { scrollToEnd(proxy: proxy) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.small) {
            TextField("Ask about this transcript…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.horizontal, DS.Spacing.regular)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Color.surfaceElevated)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DS.Color.separator.opacity(0.6), lineWidth: 0.5)
                )
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(isSendDisabled ? DS.Color.accent.opacity(0.4) : DS.Color.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isSendDisabled)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send (⌘↩)")
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.bottom, DS.Spacing.medium)
        .padding(.top, DS.Spacing.small)
    }

    private var isSendDisabled: Bool {
        input.trimmingCharacters(in: .whitespaces).isEmpty || isSending
    }

    private func toggleSearch() {
        withAnimation(.easeOut(duration: 0.18)) {
            isSearching.toggle()
        }
        if isSearching {
            searchFocused = true
        } else {
            searchQuery = ""
            senderFilter = .all
            searchFocused = false
        }
    }

    private func scrollToEnd(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isSending {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = displayedHistory.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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

    private func resetConversation() {
        guard let session else { return }
        Task {
            await session.clearHistory()
            let updated = await session.history
            displayedHistory = updated
            model.recordChat(history: updated)
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

private enum ChatSenderFilter: CaseIterable, Hashable {
    case all, user, assistant

    var label: String {
        switch self {
        case .all: return "All"
        case .user: return "User"
        case .assistant: return "Assistant"
        }
    }

    func matches(_ role: ChatMessage.Role) -> Bool {
        switch self {
        case .all: return true
        case .user: return role == .user
        case .assistant: return role == .assistant
        }
    }
}

private struct ChatSearchPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Color.surfaceElevated.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
    }
}

private struct ChatSenderChip: View {
    @Binding var selection: ChatSenderFilter

    var body: some View {
        Menu {
            ForEach(ChatSenderFilter.allCases, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(selection.label)
                    .font(DS.Font.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(selection == .all ? Color.primary.opacity(0.85) : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selection == .all ? DS.Color.surfaceElevated.opacity(0.85) : DS.Color.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DS.Color.separator.opacity(0.4), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by sender")
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 40)
                bubble
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DS.Color.accent)
                    )
                    .foregroundStyle(.white)
            } else {
                bubble
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DS.Color.surfaceElevated)
                    )
                    .foregroundStyle(DS.Color.primaryText)
                Spacer(minLength: 40)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role == .user ? "You" : "Assistant"): \(message.text)")
    }

    private var bubble: some View {
        Text(message.text)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 480, alignment: .leading)
    }
}

private struct ChatHint: View {
    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DS.Color.secondaryText)
            Text("Ask anything about this transcript.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ThinkingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(DS.Color.secondaryText)
                        .frame(width: 6, height: 6)
                        .opacity(dotOpacity(time: t, index: i))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private func dotOpacity(time: TimeInterval, index: Int) -> Double {
        let cycle = 1.2
        let phase = (time / cycle).truncatingRemainder(dividingBy: 1)
        let offset = Double(index) * 0.15
        let local = (phase - offset + 1).truncatingRemainder(dividingBy: 1)
        let wave = sin(local * .pi)
        return 0.3 + max(0, wave) * 0.7
    }
}

private struct ChatUnavailable: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Chat unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatEmpty: View {
    var body: some View {
        ContentUnavailableView {
            Label("No transcript", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Open a transcript to start chatting.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
