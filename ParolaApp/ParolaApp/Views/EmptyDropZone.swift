import SwiftUI
import ParolaCore

struct EmptyDropZone: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var emptyIconSize: CGFloat = 48

    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.regular), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Spacing.regular) {
                    ActionCard(
                        title: "Open or Drop File",
                        systemImage: "folder.fill.badge.plus",
                        action: { model.presentOpenPanel() }
                    )
                    .axLeaf("Empty.Button.OpenFile")
                    ActionCard(
                        title: "Record Microphone",
                        systemImage: "mic.fill",
                        action: { model.startRecording(source: .microphone) }
                    )
                    .axLeaf("Empty.Button.RecordMic")
                    ActionCard(
                        title: "Record System Audio",
                        systemImage: "waveform.circle.fill",
                        action: { model.startRecording(source: .systemAudio) }
                    )
                    .axLeaf("Empty.Button.RecordSystemAudio")
                    ActionCard(
                        title: "YouTube URL",
                        systemImage: "play.rectangle.fill",
                        action: { model.youtubeSheetOpen = true }
                    )
                    .axLeaf("Empty.Button.YouTube")
                }

                HStack(spacing: DS.Spacing.small) {
                    ModeButton(
                        title: "Live Captions",
                        systemImage: "captions.bubble.fill",
                        action: { model.toggleLiveCaptions() }
                    )
                    .disabled(model.liveCaptionsUnavailableReason != nil)
                    .help(model.liveCaptionsUnavailableReason ?? "")
                    .axLeaf("Empty.Button.LiveCaptions")
                    ModeButton(
                        title: "Dictation",
                        systemImage: "text.cursor",
                        action: { model.startDictationFromIntent() }
                    )
                    .axLeaf("Empty.Button.Dictation")
                }

                if !model.libraryEntries.isEmpty {
                    recentSection
                }

                if model.libraryEntries.isEmpty {
                    VStack(spacing: DS.Spacing.regular) {
                        Image(systemName: "clock")
                            .font(.system(size: emptyIconSize, weight: .regular))
                            .foregroundStyle(DS.Color.secondaryText.opacity(0.55))
                        Text("No Transcriptions Yet")
                            .font(DS.Font.heading)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.xlarge)
                }
            }
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var recentSection: some View {
        let recents = RecentEntries.most(of: model.libraryEntries)
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
                ForEach(Array(recents.enumerated()), id: \.element.id) { index, entry in
                    RecentEntryRow(entry: entry)
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

private struct RecentEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: LibraryEntry
    @State private var isHovering = false

    var body: some View {
        Button {
            model.loadEntry(entry.id)
        } label: {
            LibraryRow(entry: entry, sizeBytes: model.libraryBundleSizes[entry.id], style: .home)
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
        .axLeaf("Empty.Recent.\(entry.id)")
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
                    .lineLimit(2)
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
