import SwiftUI
import ParolaCore

struct EmptyDropZone: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.regular), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.large) {
                if !model.libraryEntries.isEmpty {
                    LibraryStatsCard(summary: LibrarySummary(entries: model.libraryEntries))
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Spacing.regular) {
                    ActionCard(
                        title: "Open File",
                        systemImage: "folder.fill.badge.plus",
                        action: { model.presentOpenPanel() }
                    )
                    ActionCard(
                        title: "Record Mic",
                        systemImage: "mic.fill",
                        action: { model.startRecording(source: .microphone) }
                    )
                    ActionCard(
                        title: "Record System Audio",
                        systemImage: "waveform.circle.fill",
                        action: { model.startRecording(source: .systemAudio) }
                    )
                    ActionCard(
                        title: "Live Captions",
                        systemImage: "captions.bubble.fill",
                        action: { model.toggleLiveCaptions() }
                    )
                    ActionCard(
                        title: "Dictation",
                        systemImage: "text.cursor",
                        action: { model.startDictationFromIntent() }
                    )
                    ActionCard(
                        title: "Manage Models",
                        systemImage: "cpu.fill",
                        action: { openSettings() }
                    )
                    ActionCard(
                        title: "YouTube URL",
                        systemImage: "play.rectangle.fill",
                        action: { model.youtubeSheetOpen = true }
                    )
                    ActionCard(
                        title: "Recently Deleted",
                        systemImage: "trash.fill",
                        isEnabled: !model.deletedEntries.isEmpty,
                        action: { model.showingTrash = true }
                    )
                }

                if model.libraryEntries.isEmpty {
                    VStack(spacing: DS.Spacing.regular) {
                        Image(systemName: "clock")
                            .font(.system(size: 48, weight: .regular))
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
}

private struct LibraryStatsCard: View {
    let summary: LibrarySummary

    var body: some View {
        HStack(spacing: 0) {
            stat(label: "Total", value: summary.total)
            divider
            stat(label: "Transcriptions", value: summary.transcriptions)
            divider
            stat(label: "Meetings", value: summary.meetings)
            divider
            stat(label: "Dictations", value: summary.dictations)
            divider
            stat(label: "Pinned", value: summary.pinned)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.Color.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private func stat(label: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Color.primaryText)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Color.secondaryText)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Color.separator.opacity(0.4))
            .frame(width: 1, height: 32)
    }
}

struct ActionCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.regular) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DS.Color.separator.opacity(isHovering ? 0.9 : 0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
