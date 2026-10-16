import AppKit
import SwiftUI
import ParolaCore

/// A library transcript in a window of its own: read-only, with its own player and its own search.
struct EntryWindowView: View {
    let entryID: LibraryEntry.ID?

    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session: EntryWindowSession?
    @State private var showsEditHint = false
    @State private var hintTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let entryID, let session {
                loaded(entryID: entryID, session: session)
            } else {
                EntryViewerNotice(
                    icon: "doc.text.magnifyingglass",
                    message: "This transcript is no longer in your library."
                )
                .id(model.themeRevision)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(DS.Palette.canvas)
        // onAppear, not task: it is synchronous, so it always pairs with the onDisappear that
        // releases the session. A window opened and closed in the same tick left one registered.
        .onAppear { adoptSession() }
        .onChange(of: entryID) { _, _ in adoptSession() }
        // initial: a window opens already key, and the commands have to know that before focus moves again.
        .onChange(of: controlActiveState, initial: true) { _, state in
            guard let entryID else { return }
            model.entryWindowKeyChanged(entryID, isKey: state == .key)
        }
        .onChange(of: model.libraryVersion) { _, _ in session?.reloadIfEntryChanged() }
        .onDisappear {
            hintTask?.cancel()
            guard let session else { return }
            model.releaseEntryWindow(session)
        }
    }

    /// The chrome is rebuilt for a theme change; the transcript column repaints in place so it keeps its scroll.
    private func loaded(entryID: LibraryEntry.ID, session: EntryWindowSession) -> some View {
        VStack(spacing: 0) {
            EntryViewerHeader(session: session)
                .id(model.themeRevision)
            Divider()
            if session.searchIsOpen {
                EntryViewerSearchBar(session: session)
                    .id(model.themeRevision)
                Divider()
            }
            HStack(spacing: 0) {
                transcriptColumn(session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if session.showsInfo {
                    Divider()
                    EntryViewerInfo(session: session)
                        .frame(width: MainWindowLayout.inspectorWidth)
                }
            }
            if showsEditHint {
                Divider()
                HStack(spacing: DS.Spacing.small) {
                    Text("Edit in the main window.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .axLeaf("Label.EditHint")
                    Button("Open in Main Window") { model.openInMainWindow(entryID) }
                        .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                        .axLeaf("Button.EditHintOpenInMainWindow")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DS.Spacing.small)
                .onHover { inside in if inside { hintTask?.cancel() } else { flashEditHint() } }
                .transition(.opacity)
            }
            if session.player != nil {
                Divider()
                EntryViewerPlaybackBar(session: session)
                    .id(model.themeRevision)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsEditHint)
        .navigationTitle(session.title)
        .background(WindowCloseReporter { model.releaseEntryWindow(session) })
        .sheet(item: Binding(
            get: { model.readAloud.voicePrompt.flatMap { $0.origin == .entryWindow(entryID) ? $0 : nil } },
            set: { if $0 == nil { model.dismissVoicePrompt() } }
        )) { prompt in
            ReadAloudVoiceSheet(prompt: prompt)
        }
        .axBranch("EntryWindow.\(entryID)")
    }

    @ViewBuilder
    private func transcriptColumn(_ session: EntryWindowSession) -> some View {
        if session.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.loadFailed {
            EntryViewerNotice(
                icon: "exclamationmark.triangle",
                message: "This transcript is no longer in your library."
            )
            .id(model.themeRevision)
        } else if session.transcript?.segments.isEmpty ?? true {
            EntryViewerNotice(icon: "text.alignleft", message: "This transcript has no text.")
                .id(model.themeRevision)
        } else {
            EntryViewerTranscript(session: session, onEditAttempt: flashEditHint)
        }
    }

    private func adoptSession() {
        guard let entryID else {
            session = nil
            return
        }
        guard session?.entryID != entryID else { return }
        if let session { model.releaseEntryWindow(session) }
        session = model.entryWindowSession(for: entryID)
    }

    private func flashEditHint() {
        showsEditHint = true
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showsEditHint = false
        }
    }
}

struct EntryViewerNotice: View {
    let icon: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: icon)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.secondaryText)
            Text(message)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.large)
    }
}

/// Reports the window's close: SwiftUI's `onDisappear` can trail a window teardown, and the player has to stop with it.
struct WindowCloseReporter: NSViewRepresentable {
    let onClose: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> NSView {
        CloseReportingView(onClose: onClose)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CloseReportingView: NSView {
        private let onClose: @MainActor @Sendable () -> Void
        private var observer: (any NSObjectProtocol)?

        init(onClose: @escaping @MainActor @Sendable () -> Void) {
            self.onClose = onClose
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [onClose] _ in
                Task { @MainActor in onClose() }
            }
        }
    }
}
