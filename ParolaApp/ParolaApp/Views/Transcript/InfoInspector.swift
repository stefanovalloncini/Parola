import SwiftUI
import ParolaCore

struct InfoInspector: View {
    @EnvironmentObject var model: AppModel

    private var entry: LibraryEntry? {
        guard let id = model.selectedEntryID else { return nil }
        return model.libraryEntries.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            InfoSection(title: "Properties") {
                InfoRow(icon: "clock", label: "Audio Duration", value: durationLabel)
                InfoRow(icon: "calendar", label: "Created", value: dateLabel(entry?.createdAt))
                if let updated = entry?.updatedAt {
                    InfoRow(icon: "calendar.badge.clock", label: "Updated", value: dateLabel(updated))
                }
            }

            InfoSection(title: "Transcription Details") {
                InfoRow(icon: "globe", label: "Language", value: languageLabel)
                InfoRow(icon: "cube", label: "Model", value: model.transcript?.modelName ?? "—")
                InfoRow(icon: "cpu", label: "Engine", value: engineLabel)
                InfoRow(icon: "character", label: "Characters", value: "\(charCount)")
                InfoRow(icon: "text.word.spacing", label: "Words", value: "\(wordCount)")
            }

            if model.transcript != nil {
                ConfidenceSection()
                ChaptersSection()
                ActionItemsSection()
            }
        }
    }

    private var languageLabel: String {
        guard let code = model.transcript?.language, !code.isEmpty else { return "Auto" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private var engineLabel: String {
        guard let modelName = model.transcript?.modelName,
              let variant = ModelCatalog.variant(id: modelName) else {
            return "—"
        }
        return variant.engineID.displayName
    }

    private var durationLabel: String {
        guard let d = model.transcript?.durationSeconds else { return "—" }
        return Duration.seconds(d).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var charCount: Int {
        model.transcript?.text.count ?? 0
    }

    private var wordCount: Int {
        guard let text = model.transcript?.text else { return 0 }
        return text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: icon)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 16)
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(DS.Font.body)
    }
}

