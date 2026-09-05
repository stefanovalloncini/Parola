import SwiftUI
import ParolaCore

struct EmptyDropZone: View {
    /// A failure shows as a card above the intake surface, which stays usable.
    var errorMessage: String?

    @Environment(AppModel.self) private var model
    @State private var paneHeight: CGFloat = 0
    @State private var recentRowSpace: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var recentRowHeight: CGFloat = 49

    var body: some View {
        ScrollView {
            page
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.large)
                // Fills the window when the page fits, scrolls when it doesn't.
                .frame(maxWidth: .infinity, minHeight: paneHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            IntakeDropWell()
                .axLeaf("Empty.Button.OpenFile")

            let actions = startActions
            if !actions.isEmpty {
                LazyVGrid(columns: columns(for: actions.count), alignment: .leading, spacing: DS.Spacing.regular) {
                    ForEach(actions) { action in
                        ActionCard(
                            title: action.title,
                            subtitle: action.subtitle,
                            systemImage: action.systemImage,
                            action: action.run
                        )
                        .axLeaf(action.id)
                    }
                }
            }

            if model.features.isEnabled(.liveCaptions) || model.features.isEnabled(.dictation) {
                HStack(spacing: DS.Spacing.small) {
                    if model.features.isEnabled(.liveCaptions) {
                        ModeButton(
                            title: "Live Captions",
                            systemImage: "captions.bubble.fill",
                            action: { model.toggleLiveCaptions() }
                        )
                        .disabled(model.liveCaptionsUnavailableReason != nil)
                        .help(model.liveCaptionsUnavailableReason ?? "")
                        .axLeaf("Empty.Button.LiveCaptions")
                    }
                    if model.features.isEnabled(.dictation) {
                        ModeButton(
                            title: "Dictation",
                            systemImage: "text.cursor",
                            action: { model.startDictationFromIntent() }
                        )
                        .axLeaf("Empty.Button.Dictation")
                    }
                }
            }

            if model.libraryEntries.isEmpty {
                emptyLibraryState
            } else {
                recentSection
            }
        }
    }

    private struct StartAction: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
        let systemImage: String
        let run: () -> Void
    }

    private var startActions: [StartAction] {
        var actions: [StartAction] = []
        if model.features.isEnabled(.micRecording) {
            actions.append(StartAction(
                id: "Empty.Button.RecordMic",
                title: "Record Microphone",
                subtitle: "Capture from the mic",
                systemImage: "mic.fill",
                run: { model.startRecording(source: .microphone) }
            ))
        }
        if model.features.isEnabled(.meetings) {
            actions.append(StartAction(
                id: "Empty.Button.RecordSystemAudio",
                title: "Record System Audio",
                subtitle: "Capture what your Mac plays",
                systemImage: "waveform.circle.fill",
                run: { model.startRecording(source: .systemAudio) }
            ))
        }
        if model.features.isEnabled(.youtube) {
            actions.append(StartAction(
                id: "Empty.Button.YouTube",
                title: "YouTube URL",
                subtitle: "Paste a link to transcribe",
                systemImage: "play.rectangle.fill",
                run: { model.youtubeSheetOpen = true }
            ))
        }
        return actions
    }

    /// The cap keeps a wide window from stretching three cards into slabs.
    private func columns(for count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(maximum: 420), spacing: DS.Spacing.regular),
            count: max(1, min(count, 4))
        )
    }

    private var emptyLibraryState: some View {
        EmptyStateView(
            systemImage: "text.alignleft",
            title: "No Transcriptions Yet",
            message: "Your transcriptions show up here."
        ) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open Audio…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary))
            .axLeaf("Home.Empty.OpenAudio")
            if model.features.isEnabled(.micRecording) {
                Button {
                    model.startRecording(source: .microphone)
                } label: {
                    Label("Record", systemImage: "mic.fill")
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary))
                .axLeaf("Home.Empty.Record")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var recentSection: some View {
        let recents = RecentEntries
            .most(of: model.libraryEntries, limit: RecentEntries.rowsThatFit(inHeight: recentRowSpace, rowHeight: recentRowHeight))
            .map { LibraryRowDisplay(entry: $0, sizeBytes: model.libraryBundleSizes[$0.id]) }
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Text("Recent")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer(minLength: 0)
                ViewAllButton(count: model.libraryEntries.count) {
                    model.libraryFilter = nil
                    model.libraryBrowsingAll = true
                    model.route = .transcript
                }
            }
            // Color.clear takes the leftover height, so the row count follows the space the
            // window has rather than feeding back into it.
            Color.clear
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(Array(recents.enumerated()), id: \.element.id) { index, display in
                            RecentEntryRow(display: display)
                            if index < recents.count - 1 {
                                Divider()
                                    .padding(.leading, DS.Spacing.regular)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                            .fill(DS.Color.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                            .strokeBorder(DS.Color.separator.opacity(0.5), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
                }
                .clipped()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { recentRowSpace = $0 }
        }
    }
}

private struct ViewAllButton: View {
    let count: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("View all (\(count))")
                    .underline(isHovering)
                Image(systemName: "chevron.right")
                    .font(DS.Font.caption2Emphasized)
            }
            .font(DS.Font.subheadlineMedium)
            .foregroundStyle(DS.Color.accentText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .axLeaf("Empty.Button.ViewAll")
    }
}

/// The resting half of the split drop zone: the window says a drop is welcome before a drag ever starts.
private struct IntakeDropWell: View {
    @Environment(AppModel.self) private var model
    @State private var isHovering = false
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 26

    var body: some View {
        Button {
            model.presentOpenPanel()
        } label: {
            HStack(spacing: DS.Spacing.regular) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                    Text("Drop audio or video")
                        .font(DS.Font.heading)
                        .foregroundStyle(DS.Color.primaryText)
                    Text("or click to choose files")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                Spacer(minLength: DS.Spacing.regular)
                // A shape, not just the accent: under the Mono accent the dashed well alone reads as disabled.
                Label("Choose Files…", systemImage: "folder")
                    .font(DS.Font.subheadlineMedium)
                    .foregroundStyle(DS.Color.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(DS.Palette.pillFill))
                    .overlay(Capsule(style: .continuous).strokeBorder(DS.Color.separator, lineWidth: 0.5))
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.regular)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.Color.surfaceElevated.opacity(isHovering ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .strokeBorder(
                        DS.Color.accent.opacity(isHovering ? 0.9 : 0.45),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help("Drop audio or video")
    }
}

private struct RecentEntryRow: View {
    @Environment(AppModel.self) private var model
    let display: LibraryRowDisplay
    @State private var isHovering = false

    var body: some View {
        Button {
            model.loadEntry(display.id)
        } label: {
            LibraryRow(display: display, style: .home)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.regular)
                .padding(.vertical, DS.Spacing.tight)
                .background(DS.Palette.surfaceHover.opacity(isHovering ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .axLeaf("Empty.Recent.\(display.id)")
    }
}

private struct ModeButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(DS.Color.accent)
                Text(title)
                    .font(DS.Font.subheadlineMedium)
                    .foregroundStyle(DS.Color.primaryText)
            }
            .pillStyle()
            .opacity(isHovering ? 1 : 0.88)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(title)
    }
}

struct ActionCard: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let systemImage: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 26

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                    .frame(height: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DS.Color.primaryText)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.regular)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .strokeBorder(DS.Color.separator.opacity(isHovering ? 0.9 : 0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            guard isEnabled else { return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(title)
    }

    private var cardBackground: some View {
        DS.Color.surfaceElevated
            .overlay(SwiftUI.Color.white.opacity(isHovering ? 0.04 : 0))
    }
}
