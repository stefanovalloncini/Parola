import SwiftUI
import ParolaCore

struct EmptyDropZone: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                IntakeDropWell()
                    .axLeaf("Empty.Button.OpenFile")

                let actions = startActions
                if !actions.isEmpty {
                    LazyVGrid(columns: columns(for: actions.count), alignment: .leading, spacing: DS.Spacing.regular) {
                        ForEach(actions) { action in
                            ActionCard(
                                title: action.title,
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

                if !model.libraryEntries.isEmpty {
                    recentSection
                }

                if model.libraryEntries.isEmpty {
                    EmptyStateView(systemImage: "clock", title: "No Transcriptions Yet")
                        .frame(maxWidth: .infinity)
                        .padding(.top, DS.Spacing.medium)
                }
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct StartAction: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let systemImage: String
        let run: () -> Void
    }

    private var startActions: [StartAction] {
        var actions: [StartAction] = []
        if model.features.isEnabled(.micRecording) {
            actions.append(StartAction(
                id: "Empty.Button.RecordMic",
                title: "Record Microphone",
                systemImage: "mic.fill",
                run: { model.startRecording(source: .microphone) }
            ))
        }
        if model.features.isEnabled(.meetings) {
            actions.append(StartAction(
                id: "Empty.Button.RecordSystemAudio",
                title: "Record System Audio",
                systemImage: "waveform.circle.fill",
                run: { model.startRecording(source: .systemAudio) }
            ))
        }
        if model.features.isEnabled(.youtube) {
            actions.append(StartAction(
                id: "Empty.Button.YouTube",
                title: "YouTube URL",
                systemImage: "play.rectangle.fill",
                run: { model.youtubeSheetOpen = true }
            ))
        }
        return actions
    }

    private func columns(for count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.regular), count: max(1, min(count, 4)))
    }

    @ViewBuilder
    private var recentSection: some View {
        let recents = RecentEntries.most(of: model.libraryEntries)
            .map { LibraryRowDisplay(entry: $0, sizeBytes: model.libraryBundleSizes[$0.id]) }
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Text("Recent")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer(minLength: 0)
                Button("View all (\(model.libraryEntries.count))") {
                    model.libraryFilter = nil
                    model.libraryBrowsingAll = true
                    model.route = .transcript
                }
                .buttonStyle(.plain)
                .font(DS.Font.subheadlineMedium)
                .foregroundStyle(DS.Color.accent)
                .axLeaf("Empty.Button.ViewAll")
            }
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
    }
}

/// The resting half of the split drop zone: the window says a drop is welcome before a drag
/// ever starts, and shows the model and language it would commit to.
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
                IntakeStateChips()
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
    let systemImage: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 26

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                    .frame(height: 28, alignment: .leading)
                Spacer(minLength: 0)
                Text(title)
                    .font(DS.Font.body)
                    .fontWeight(.medium)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.regular)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
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
