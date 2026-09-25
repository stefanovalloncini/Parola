import SwiftUI
import ParolaCore

struct OutlinePopover: View {
    @Environment(AppModel.self) private var model
    let onJump: (Double) -> Void

    private var entries: [TranscriptOutline.Entry] {
        guard let transcript = model.transcript else { return [] }
        return TranscriptOutline.entries(for: transcript, chapters: model.smartChapters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            OutlineRow(entry: entry) { onJump(entry.start) }
                        }
                    }
                    .padding(.vertical, DS.Spacing.tight)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(minWidth: 280, idealWidth: 320)
        .closesOnEscape()
    }

    private var header: some View {
        HStack {
            Text("Outline")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            if model.smartChapters.isEmpty {
                Button("Generate Chapters") { model.extractSmartChapters() }
                    .controlSize(.small)
                    .disabled(model.isExtractingChapters || !model.isAIAvailable(for: .summary))
                    .help(model.isAIAvailable(for: .summary) ? "" : (model.aiUnavailableReason ?? ""))
                    .axLeaf("Outline.Button.GenerateChapters")
            }
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.secondaryText)
            Text("No outline available")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.large)
    }
}

private struct OutlineRow: View {
    let entry: TranscriptOutline.Entry
    let onJump: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onJump) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Timecode.format(entry.start))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.accentText)
                    .frame(width: 50, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.primaryText)
                        .multilineTextAlignment(.leading)
                    if let rawSpeaker = entry.speaker, let speaker = SegmentCard.speakerLabel(for: rawSpeaker) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(DS.speakerColor(for: rawSpeaker))
                                .frame(width: 5, height: 5)
                            Text(speaker)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.secondaryText)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.snug)
            .rowChrome(selected: false, hovered: hovering, selection: .native)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .axLeaf("Outline.Button.Jump")
    }
}
