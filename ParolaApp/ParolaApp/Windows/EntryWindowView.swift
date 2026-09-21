import AppKit
import SwiftUI
import ParolaCore

/// A library transcript in a window of its own: read-only, with its own player and its own search.
struct EntryWindowView: View {
    let entryID: LibraryEntry.ID?

    @Environment(AppModel.self) private var model
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
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(DS.Palette.canvas)
        .task(id: entryID) {
            guard let entryID else { return }
            session = model.entryWindowSession(for: entryID)
        }
        .onDisappear {
            hintTask?.cancel()
            guard let entryID else { return }
            model.releaseEntryWindow(entryID)
        }
    }

    @ViewBuilder
    private func loaded(entryID: LibraryEntry.ID, session: EntryWindowSession) -> some View {
        VStack(spacing: 0) {
            EntryViewerHeader(session: session)
            Divider()
            if session.searchIsOpen {
                EntryViewerSearchBar(session: session)
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
                Text("Edit in the main window.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DS.Spacing.small)
                    .transition(.opacity)
                    .axLeaf("Label.EditHint")
            }
            if session.player != nil {
                Divider()
                EntryViewerPlaybackBar(session: session)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsEditHint)
        .navigationTitle(session.title)
        .background(WindowCloseReporter { model.releaseEntryWindow(entryID) })
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
        } else if session.transcript?.segments.isEmpty ?? true {
            EntryViewerNotice(icon: "text.alignleft", message: "This transcript has no text.")
        } else {
            EntryViewerTranscript(session: session, onEditAttempt: flashEditHint)
        }
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

/// Reports the window's close. SwiftUI's `onDisappear` can trail a window teardown, and the
/// session's player has to stop with the window that owns it.
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
