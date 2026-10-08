import SwiftUI
import ParolaCore

/// The line under a transcript's name: when, how long, how many voices, which language.
enum TranscriptMeta {
    static func line(createdAt: Date?, seconds: Double?, speakers: Int, language: String?, bundle: Bundle = .main) -> String {
        var parts: [String] = []
        if let createdAt {
            parts.append(AppFormat.dateAndTime(createdAt))
        }
        if let seconds, seconds > 0 {
            parts.append(AppFormat.duration(seconds: seconds, bundle: bundle))
        }
        if speakers > 1 {
            parts.append(String(localized: "\(speakers) speakers", bundle: bundle))
        }
        if let name = LanguageDisplay.name(for: language) {
            parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    static func line(_ model: AppModel) -> String {
        line(
            createdAt: model.selectedEntryID.flatMap { model.libraryEntry(id: $0) }?.createdAt,
            seconds: model.transcript?.durationSeconds,
            speakers: model.transcriptSpeakers.count,
            language: model.transcript?.language
        )
    }
}

/// The transcript's name at the top of its text, scrolling away with it, as a note's title does in Notes.
struct TranscriptTitleHeading: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let meta = TranscriptMeta.line(model)
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            Text(verbatim: model.transcriptHeaderTitle)
                .font(DS.Font.display)
                .tracking(DS.Tracking.display)
                .foregroundStyle(DS.Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !meta.isEmpty {
                Text(verbatim: meta)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DS.Spacing.medium)
        .contextMenu {
            Button("Rename…") { model.renameRequests &+= 1 }
                .disabled(!model.canRenameOpenTranscript)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: "Rename…") { model.renameRequests &+= 1 }
        .axLeaf("Transcript.Heading.Title")
    }
}

/// What Transcript ▸ Jump to Time… and Rename… open: the popover hangs from the top of the reading column.
struct TranscriptMenuPopovers: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var jumpOpen = false
    @State private var jumpDraft = ""
    @FocusState private var jumpFocused: Bool
    @State private var renaming = false
    @State private var renameDraft = ""

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                anchor.popover(isPresented: $jumpOpen, arrowEdge: .bottom) {
                    jumpPopover
                }
            }
            .onChange(of: model.jumpToTimeRequests) { _, _ in jumpOpen = true }
            .onChange(of: model.renameRequests) { _, _ in beginRename() }
            .alert("Rename entry", isPresented: $renaming) {
                TextField("Title", text: $renameDraft)
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("alert.rename.cancel")
                Button("Rename") { model.renameOpenTranscript(to: renameDraft) }
                    .accessibilityIdentifier("alert.rename.confirm")
            }
    }

    private var anchor: some View {
        Color.clear.frame(width: 1, height: 1)
    }

    private func beginRename() {
        guard model.canRenameOpenTranscript else { return }
        renameDraft = model.transcriptHeaderTitle
        renaming = true
    }

    private var jumpPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jump to time").font(DS.Font.caption).foregroundStyle(DS.Color.secondaryText)
            HStack(spacing: 6) {
                TextField("mm:ss", text: $jumpDraft)
                    .textFieldStyle(.plain)
                    .focused($jumpFocused)
                    .fieldChrome(focused: jumpFocused)
                    .frame(width: 100)
                    .onSubmit { commitJump() }
                    .onAppear { jumpFocused = true }
                    .axLeaf("JumpToTime.TextField.Time")
                Button("Go", action: commitJump)
                    .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                    .disabled(Timecode.parse(jumpDraft) == nil)
                    .axLeaf("JumpToTime.Button.Go")
            }
        }
        .padding(DS.Spacing.regular)
    }

    private func commitJump() {
        guard let seconds = Timecode.parse(jumpDraft) else { return }
        model.seekTo(seconds: seconds)
        jumpDraft = ""
        jumpOpen = false
    }
}
