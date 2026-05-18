import SwiftUI
import ParolaCore

struct RecentlyDeletedRow: View {
    let entry: LibraryEntry
    let preview: String?
    var isSelected: Bool = false
    let onRestore: () -> Void
    let onPurge: () -> Void
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.regular) {
            categoryBadge

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.system(.headline, design: .default, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.small)
                    if let deletedAt = entry.deletedAt {
                        Text(deletedAt, format: .dateTime.hour().minute())
                            .font(DS.Font.captionMono)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(previewText)
                    .font(.system(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Spacing.regular)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(rowStroke, lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovered || isSelected { hoverActions }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovered = $0 }
        .contextMenu {
            Button { onRestore() } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { onPurge() } label: {
                Label("Delete permanently", systemImage: "trash")
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }

    var previewText: String {
        if let preview, !preview.isEmpty { return preview }
        if preview == nil { return String(localized: "Loading preview…") }
        return String(localized: "No transcript text.")
    }

    private var rowFill: Color {
        if isSelected { return DS.Color.accent.opacity(0.12) }
        return DS.Color.surfaceElevated.opacity(hovered ? 1.0 : 0.7)
    }

    private var rowStroke: Color {
        if isSelected { return DS.Color.accent.opacity(0.55) }
        return DS.Color.separator.opacity(0.5)
    }

    var categoryBadge: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(categoryTint.opacity(0.18))
            .overlay(
                Image(systemName: categoryIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(categoryTint)
            )
            .frame(width: 32, height: 32)
    }

    var hoverActions: some View {
        HStack(spacing: 4) {
            RecentlyDeletedCardIconButton(systemName: "arrow.uturn.backward", help: "Restore", action: onRestore)
            RecentlyDeletedCardIconButton(systemName: "trash", help: "Delete permanently", tint: DS.Color.danger, action: onPurge)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Color.separator.opacity(0.5), lineWidth: 0.5)
        )
        .padding(DS.Spacing.small)
    }

    var categoryIcon: String {
        switch entry.category {
        case .transcription: return "waveform"
        case .meeting: return "video.fill"
        case .dictation: return "text.bubble.fill"
        }
    }

    var categoryTint: Color {
        switch entry.category {
        case .transcription: return Color(red: 0.20, green: 0.62, blue: 0.62)
        case .meeting: return Color(red: 0.34, green: 0.62, blue: 0.36)
        case .dictation: return Color(red: 0.82, green: 0.50, blue: 0.18)
        }
    }
}

struct RecentlyDeletedCardIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(hovered ? 1.0 : 0.75))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovered ? DS.Color.surface : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
