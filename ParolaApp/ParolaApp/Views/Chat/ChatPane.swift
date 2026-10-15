import SwiftUI
import ParolaCore

struct ChatSessionKey: Hashable {
    let entryID: String?
    let hasTranscript: Bool
}

/// One instance per pane, so the Edit menu's item isn't handed a new value on every pass.
@MainActor
@Observable
final class FocusChatComposerAction {
    private(set) var requests = 0
    func callAsFunction() { requests &+= 1 }
}

struct ChatPreset: Identifiable {
    let prompt: Prompt
    let slug: String
    var id: UUID { prompt.id }

    @MainActor static let builtIns = rows(for: [])

    @MainActor static func rows(for userPrompts: [Prompt]) -> [ChatPreset] {
        ChatPane.presets(userPrompts: userPrompts).map { ChatPreset(prompt: $0, slug: ChatPane.identifierSlug($0.name)) }
    }
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
    @State private var turnError: String?
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var isReplying: Bool = false
    @State private var displayedHistory: [ChatMessage] = []
    @State private var liveReply = LiveReply()
    @State private var focusAction = FocusChatComposerAction()
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @State private var senderFilter: ChatSenderFilter = .all
    @State private var sendTask: Task<Void, Never>?
    @State private var liveTurn: LiveTurn?
    @State private var keepingStopped: Task<Void, Never>?
    @State private var presetRows = ChatPreset.builtIns
    @State private var confirmingClear = false
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
        .onChange(of: model.chatSearchRequests) { _, _ in beginSearch() }
        .focusedSceneValue(\.focusChatComposer, focusAction)
        .onChange(of: focusAction.requests) { _, _ in composerFocused = true }
        .onChange(of: composerFocused) { _, focused in noteComposerFocus(focused) }
        .onDisappear { noteComposerFocus(false) }
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
                    ForEach(presetRows) { preset in
                        Button(preset.prompt.name) { sendPreset(preset.prompt.instructions) }
                            .buttonStyle(.plain)
                            .disabled(presetsDisabled)
                            .accessibilityIdentifier("chat.preset.\(preset.slug)")
                            .axLeaf("Chat.Button.Preset.\(preset.slug)")
                    }
                }
                Divider().opacity(0.4)
                Button("Manage Prompts…") { model.openSettings(route: .prompts) }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.accentInk)
                    .accessibilityIdentifier("chat.manage_prompts")
                    .axLeaf("Chat.Button.ManagePrompts")
            }
            .padding(DS.Spacing.regular)
        }
    }

    private var presetsDisabled: Bool {
        session == nil || isReplying
    }

    private func sendPreset(_ instructions: String) {
        guard !presetsDisabled else { return }
        send(text: instructions)
    }

    private func refreshUserPrompts() async {
        presetRows = ChatPreset.rows(for: await model.promptLibrary.userPrompts)
    }

    static let excludedBuiltInIDs: Set<UUID> = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, // Note
        UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, // Code comment
        UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, // Assistant
    ]

    static func presets(userPrompts: [Prompt]) -> [Prompt] {
        Prompt.builtIns.filter { !excludedBuiltInIDs.contains($0.id) } + userPrompts
    }

    static func identifierSlug(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Chat")
                .font(DS.Font.heading)
            Spacer()
            HStack(spacing: 0) {
                Button(action: toggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(isSearching ? DS.Color.accent : DS.Color.secondaryText)
                }
                .buttonStyle(GlyphButtonStyle())
                .help("Search chat (⌘F)")
                .accessibilityLabel(isSearching ? "Hide search" : "Search messages")
                .axLeaf("Header.Button.ToggleSearch")

                Button(role: .destructive) { confirmingClear = true } label: {
                    Image(systemName: "trash")
                        .font(DS.Font.bodyStrong)
                }
                .buttonStyle(GlyphButtonStyle())
                .foregroundStyle(DS.Color.secondaryText)
                .help("Clear conversation")
                .disabled(displayedHistory.isEmpty || isReplying)
                .accessibilityLabel("Clear conversation")
                .axLeaf("Header.Button.Reset")
                .confirmationDialog("Clear this conversation?", isPresented: $confirmingClear) {
                    Button("Clear Conversation", role: .destructive) { resetConversation() }
                        .axLeaf("Header.Button.ConfirmReset")
                } message: {
                    Text("The messages can't be brought back.")
                }
            }
            .padding(.vertical, -3)
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
                    .buttonStyle(GlyphButtonStyle())
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                    .axLeaf("Search.Button.Clear")
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
                live: liveReply,
                searchQuery: searchQuery,
                senderFilter: senderFilter,
                isSending: isSending,
                failure: turnError
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

            if isReplying {
                Button(action: stopReply) {
                    composerGlyph("stop.fill", dimmed: false)
                }
                .buttonStyle(.plain)
                .help("Stop the reply")
                .accessibilityLabel("Stop the reply")
                .axLeaf("Composer.Button.Stop")
            } else {
                Button(action: send) {
                    composerGlyph("paperplane.fill", dimmed: isSendDisabled)
                }
                .buttonStyle(.plain)
                .disabled(isSendDisabled)
                .modifier(ChatSendShortcut(composerFocused: composerFocused))
                .help("Send (⌘↩)")
                .axLeaf("Composer.Button.Send")
            }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.bottom, DS.Spacing.medium)
        .padding(.top, DS.Spacing.small)
    }

    private func composerGlyph(_ symbol: String, dimmed: Bool) -> some View {
        Image(systemName: symbol)
            .font(DS.Font.bodyStrong)
            .foregroundStyle(DS.Color.onAccent)
            .frame(width: 32, height: 32)
            .background(
                Circle().fill(dimmed ? DS.Color.accentFill.opacity(0.4) : DS.Color.accentFill)
            )
    }

    private func noteComposerFocus(_ focused: Bool) {
        if model.chatComposerHasFocus != focused { model.chatComposerHasFocus = focused }
    }

    private var isSendDisabled: Bool {
        Self.isSendDisabled(input: input, isReplying: isReplying)
    }

    /// A message sent while a reply streams would cut that reply off, so the draft waits until it ends.
    static func isSendDisabled(input: String, isReplying: Bool) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isReplying
    }

    private var sessionKey: ChatSessionKey {
        ChatSessionKey(entryID: model.selectedEntryID, hasTranscript: model.transcript != nil)
    }

    private func beginSearch() {
        if !isSearching {
            withAnimation(.easeOut(duration: 0.18)) { isSearching = true }
        }
        searchFocused = true
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
        liveTurn = nil
        liveReply.end()
        keepingStopped = nil
        isSending = false
        isReplying = false
        sessionError = nil
        turnError = nil
        session = nil
        displayedHistory = []
        guard let transcript = model.transcript else { return }
        let loaded = await Self.loadSession(key: sessionKey, currentKey: { sessionKey }) {
            try await model.makeChatSession(transcript: transcript, history: transcript.chatHistory ?? [], entryID: model.selectedEntryID)
        }
        switch loaded {
        case .ready(let built, let history)?:
            session = built
            displayedHistory = history
        case .failed(let message)?:
            sessionError = message
        case nil:
            return
        }
    }

    enum SessionLoad {
        case ready(TranscriptChatSession, history: [ChatMessage])
        case failed(String)
    }

    /// Nil when the pane moved to another entry while the session was built: installing it would answer, and record, into the wrong entry.
    static func loadSession(
        key: ChatSessionKey,
        currentKey: () -> ChatSessionKey,
        build: () async throws -> TranscriptChatSession
    ) async -> SessionLoad? {
        do {
            let built = try await build()
            guard !Task.isCancelled, key == currentKey() else { return nil }
            let history = await built.history
            guard !Task.isCancelled, key == currentKey() else { return nil }
            return .ready(built, history: history)
        } catch {
            guard !Task.isCancelled, key == currentKey() else { return nil }
            return .failed(FailureText.message(for: error))
        }
    }

    private func resetConversation() {
        guard let session else { return }
        sendTask?.cancel()
        sendTask = nil
        liveTurn = nil
        liveReply.end()
        isSending = false
        isReplying = false
        turnError = nil
        let entryID = model.selectedEntryID
        let keeping = keepingStopped
        Task {
            await keeping?.value
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
                input = ChatAttachment.attach(
                    input: input,
                    filename: url.lastPathComponent,
                    content: raw,
                    maxCharacters: ChatAttachment.maxCharacters(messageLimit: session?.messageCharacterLimit, input: input)
                )
            }
            composerFocused = true
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session != nil, !isReplying else { return }
        input = ""
        send(text: text)
    }

    private func stopReply() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        isReplying = false
        guard let live = liveTurn, let session else { return }
        liveTurn = nil
        let said = liveReply.said
        liveReply.end()
        switch Self.stoppedTurn(live, said: said) {
        case .keep(let reply):
            displayedHistory.append(reply)
            let entryID = model.selectedEntryID
            keepingStopped = Task {
                let kept = await session.keepStopped(question: live.question, reply: reply)
                model.recordChat(history: kept, for: entryID)
            }
        case .unanswered:
            giveBack(live.question)
        }
    }

    struct LiveTurn {
        let question: ChatMessage
        let replyID: UUID
    }

    enum StoppedTurn: Equatable {
        case keep(ChatMessage)
        case unanswered
    }

    static func takingBack(_ question: ChatMessage, from history: [ChatMessage], draft: String) -> (history: [ChatMessage], draft: String) {
        let blank = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (history.filter { $0.id != question.id }, blank ? question.text : draft)
    }

    private func giveBack(_ question: ChatMessage) {
        let taken = Self.takingBack(question, from: displayedHistory, draft: input)
        displayedHistory = taken.history
        input = taken.draft
    }

    /// A stopped reply stays with the words it had said; one stopped before its first word hands the question back.
    static func stoppedTurn(_ live: LiveTurn, said raw: String) -> StoppedTurn {
        let said = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? .unanswered : .keep(ChatMessage(id: live.replyID, role: .assistant, text: said))
    }

    /// Leaves the composer draft untouched — a preset send must not clobber what the user was typing.
    private func send(text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session, !isReplying else { return }
        isSending = true
        isReplying = true
        turnError = nil
        let entryID = model.selectedEntryID
        let question = ChatMessage(role: .user, text: text)
        let liveID = UUID()
        displayedHistory.append(question)
        liveTurn = LiveTurn(question: question, replyID: liveID)
        let keeping = keepingStopped
        sendTask = Task {
            defer {
                if !Task.isCancelled, entryID == model.selectedEntryID {
                    isSending = false
                    isReplying = false
                    liveTurn = nil
                    liveReply.end()
                }
            }
            // A reply stopped just before must be in the history this question is asked after.
            await keeping?.value
            var started = false
            do {
                for try await event in session.stream(text, id: question.id) {
                    guard !Task.isCancelled, entryID == model.selectedEntryID else { return }
                    switch event {
                    case .delta(let delta):
                        if !started {
                            started = true
                            isSending = false
                        }
                        liveReply.append(delta, replyID: liveID)
                    case .completed:
                        liveTurn = nil
                        let updated = await session.history
                        displayedHistory = updated
                        liveReply.end(ifHolding: liveID)
                        model.recordChat(history: updated, for: entryID)
                    }
                }
            } catch {
                guard !Task.isCancelled, entryID == model.selectedEntryID else { return }
                liveReply.end()
                giveBack(question)
                turnError = FailureText.message(for: error)
            }
        }
    }
}

/// ⌘⏎ sends, unless a take is running and the keyboard is elsewhere: then the Recording menu's Stop has it.
private struct ChatSendShortcut: ViewModifier {
    let composerFocused: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let stops = CommandReturn.stops(takeCanStop: TakeRemote.canEnd(model.recording), composerFocused: composerFocused)
        content.keyboardShortcut(stops ? nil : CommandReturn.shortcut)
    }
}
