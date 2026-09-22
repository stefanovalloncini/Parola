import SwiftUI
import ParolaCore

struct ChatSessionKey: Hashable {
    let entryID: String?
    let hasTranscript: Bool
}

struct FocusChatComposerAction {
    let focus: @MainActor () -> Void
    @MainActor func callAsFunction() { focus() }
}

private struct FocusChatComposerKey: FocusedValueKey {
    typealias Value = FocusChatComposerAction
}

extension FocusedValues {
    var focusChatComposer: FocusChatComposerAction? {
        get { self[FocusChatComposerKey.self] }
        set { self[FocusChatComposerKey.self] = newValue }
    }
}

struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chat.searchExpanded", store: DefaultsStore.current) private var isSearchingPersisted: Bool = false
    @State private var session: TranscriptChatSession?
    @State private var sessionError: String?
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var displayedHistory: [ChatMessage] = []
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @State private var senderFilter: ChatSenderFilter = .all
    @State private var sendTask: Task<Void, Never>?
    @State private var userPrompts: [Prompt] = []
    @FocusState private var composerFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            Divider()
            presetsColumn
                .frame(width: 240)
        }
        .background(DS.Color.surface)
        .task(id: sessionKey) { await rebuildSession() }
        .task { await refreshUserPrompts() }
        .onAppear { isSearching = isSearchingPersisted }
        .onChange(of: isSearching) { _, value in isSearchingPersisted = value }
        .focusedSceneValue(\.focusChatComposer, FocusChatComposerAction { composerFocused = true })
        .axBranch("Chat")
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if isSearching {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var presetsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                Text("Prompts")
                    .font(DS.Font.heading)
                VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                    ForEach(Self.presets(userPrompts: userPrompts)) { prompt in
                        Button(prompt.name) { sendPreset(prompt.instructions) }
                            .buttonStyle(.plain)
                            .disabled(presetsDisabled)
                            .accessibilityIdentifier("chat.preset.\(Self.identifierSlug(prompt.name))")
                            .axLeaf("Chat.Button.Preset.\(Self.identifierSlug(prompt.name))")
                    }
                }
                Divider().opacity(0.4)
                Button("Manage prompts") { model.openSettings(route: .prompts) }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityIdentifier("chat.manage_prompts")
                    .axLeaf("Chat.Button.ManagePrompts")
            }
            .padding(DS.Spacing.regular)
        }
    }

    private var presetsDisabled: Bool {
        session == nil || isSending
    }

    private func sendPreset(_ instructions: String) {
        guard !presetsDisabled else { return }
        send(text: instructions)
    }

    private func refreshUserPrompts() async {
        userPrompts = await model.promptLibrary.userPrompts
    }

    static let excludedBuiltInIDs: Set<UUID> = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, // Note
        UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, // Code comment
        UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, // Assistant
    ]

    static func presets(userPrompts: [Prompt]) -> [Prompt] {
        Prompt.builtIns.filter { !excludedBuiltInIDs.contains($0.id) } + userPrompts
    }

    private static func identifierSlug(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private var header: some View {
        HStack {
            Text("Chat")
                .font(DS.Font.heading)
            Spacer()
            Button(action: toggleSearch) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(isSearching ? DS.Color.accent : DS.Color.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Search chat (⌘F)")
            .keyboardShortcut("f", modifiers: [.command])
            .accessibilityLabel(isSearching ? "Hide search" : "Search messages")
            .axLeaf("Header.Button.ToggleSearch")

            Button(role: .destructive, action: resetConversation) {
                Image(systemName: "arrow.counterclockwise")
                    .font(DS.Font.bodyStrong)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Color.secondaryText)
            .help("Clear conversation")
            .disabled(displayedHistory.isEmpty || isSending)
            .accessibilityLabel("Clear conversation")
            .axLeaf("Header.Button.Reset")
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.regular)
    }

    private var searchBar: some View {
        HStack(spacing: DS.Spacing.small) {
            BarPill {
                Image(systemName: "magnifyingglass")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                TextField("Filter messages", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .axLeaf("Search.TextField.Query")
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.Font.secondary)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }

            ChatSenderChip(selection: $senderFilter)

            Button(action: toggleSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close search")
            .accessibilityLabel("Close search")
            .axLeaf("Search.Button.Close")
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
            ChatMessageList(
                history: displayedHistory,
                searchQuery: searchQuery,
                senderFilter: senderFilter,
                isSending: isSending
            )
            composer
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.small) {
            TextField("Ask about this transcript…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .axLeaf("Composer.TextField.Input")
                .padding(.horizontal, DS.Spacing.regular)
                .padding(.vertical, DS.Spacing.small)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Color.surfaceElevated)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DS.Color.separator.opacity(0.6), lineWidth: 0.5)
                )
                .onSubmit(send)
                .dropDestination(for: URL.self) { urls, _ in
                    attachFiles(urls)
                    return !urls.isEmpty
                } isTargeted: { targeted in
                    model.dragOverComposer = targeted
                }

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(DS.Font.bodyStrong)
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
            .axLeaf("Composer.Button.Send")
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.bottom, DS.Spacing.medium)
        .padding(.top, DS.Spacing.small)
    }

    private var isSendDisabled: Bool {
        Self.isSendDisabled(input: input, isSending: isSending)
    }

    static func isSendDisabled(input: String, isSending: Bool) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending
    }

    /// Updates the in-flight assistant bubble by id; positional indexing crashed when the
    /// history was cleared mid-stream.
    static func updatedHistory(_ history: [ChatMessage], liveID: UUID, text: String) -> [ChatMessage] {
        var history = history
        let live = ChatMessage(id: liveID, role: .assistant, text: text)
        if let index = history.lastIndex(where: { $0.id == liveID }) {
            history[index] = live
        } else {
            history.append(live)
        }
        return history
    }

    private var sessionKey: ChatSessionKey {
        ChatSessionKey(entryID: model.selectedEntryID, hasTranscript: model.transcript != nil)
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

    private func rebuildSession() async {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        sessionError = nil
        session = nil
        displayedHistory = []
        guard let transcript = model.transcript else { return }
        do {
            let s = try await model.makeChatSession(
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
        // Clearing while a reply streams: the next delta would index into the emptied history.
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        let entryID = model.selectedEntryID
        Task {
            await session.clearHistory()
            let updated = await session.history
            guard entryID == model.selectedEntryID else { return }
            displayedHistory = updated
            model.recordChat(history: updated, for: entryID)
        }
    }

    private func attachFiles(_ urls: [URL]) {
        let readable = urls.filter { ChatAttachment.isReadableTextFile($0) }
        guard !readable.isEmpty else { return }
        Task {
            for url in readable {
                let raw = try? await AppModel.offMainIO { () -> String in
                    let needsScope = url.startAccessingSecurityScopedResource()
                    defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                    return try String(contentsOf: url, encoding: .utf8)
                }
                guard let raw else { continue }
                input = ChatAttachment.attach(input: input, filename: url.lastPathComponent, content: raw)
            }
            composerFocused = true
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session != nil, !isSending else { return }
        input = ""
        send(text: text)
    }

    /// Leaves the composer draft untouched — a preset send must not clobber what the user was typing.
    private func send(text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, !isSending else { return }
        isSending = true
        let entryID = model.selectedEntryID
        sendTask?.cancel()
        displayedHistory.append(ChatMessage(role: .user, text: text))
        sendTask = Task {
            defer {
                if !Task.isCancelled, entryID == model.selectedEntryID {
                    isSending = false
                }
            }
            let liveID = UUID()
            var collected = ""
            var started = false
            do {
                for try await event in session.stream(text) {
                    guard !Task.isCancelled, entryID == model.selectedEntryID else { return }
                    switch event {
                    case .delta(let delta):
                        collected += delta
                        if !started {
                            started = true
                            isSending = false
                        }
                        displayedHistory = Self.updatedHistory(displayedHistory, liveID: liveID, text: collected)
                    case .completed:
                        let updated = await session.history
                        displayedHistory = updated
                        model.recordChat(history: updated, for: entryID)
                    }
                }
            } catch {
                guard !Task.isCancelled, entryID == model.selectedEntryID else { return }
                sessionError = error.localizedDescription
            }
        }
    }
}
