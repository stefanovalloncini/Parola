import SwiftUI
import ParolaCore

/// The one home for chapters. With no AI chapters it lists the outline the speaker turns give.
struct OverviewChapters: View {
    @Environment(AppModel.self) private var model
    @State private var showsWholeOutline = false

    static let outlineLimit = 8

    /// Left out only when there is nothing to list and no AI run has left anything yet: Summarize writes the chapters too.
    static func shows(_ model: AppModel) -> Bool {
        if !model.smartChapters.isEmpty || model.isExtractingChapters || model.chaptersError != nil { return true }
        if outline(for: model).count >= 2 { return true }
        return model.features.isEnabled(.ai) && OverviewActionItems.hasAIResults(model)
    }

    static func outline(for model: AppModel) -> [TranscriptOutline.Entry] {
        guard let transcript = model.transcript else { return [] }
        return TranscriptOutline.entries(for: transcript, chapters: [])
    }

    var body: some View {
        OverviewSection(title: title, menu: menu) {
            if model.isExtractingChapters {
                OverviewProgressRow(text: "Generating chapters…", leaf: "Chapters.Button.Stop") {
                    model.stopAIRun(.chapters)
                }
            } else if !model.smartChapters.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                    ForEach(model.smartChapters) { chapter in
                        ChapterRow(start: chapter.start, title: chapter.title) { model.seekTo(chapter: chapter) }
                    }
                }
            } else {
                outlineRows
            }
        } actions: {
            ChapterActions()
        }
    }

    private var menu: SectionMenu? {
        model.smartChapters.isEmpty ? nil : SectionMenu(label: "Chapter Options", leaf: "Inspector.Menu.Chapters")
    }

    private var title: Text {
        if model.smartChapters.isEmpty {
            return Self.outline(for: model).count >= 2 ? Text("Outline") : Text("Chapters")
        }
        return Text("Chapters · \(model.smartChapters.count)")
    }

    @ViewBuilder
    private var outlineRows: some View {
        let outline = Self.outline(for: model)
        if outline.count >= 2 {
            let shown = showsWholeOutline ? outline : Array(outline.prefix(Self.outlineLimit))
            VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                ForEach(shown) { entry in
                    ChapterRow(start: entry.start, title: entry.title, speaker: entry.speaker) {
                        model.seekTo(seconds: entry.start)
                    }
                }
            }
            if outline.count > Self.outlineLimit {
                Button(showsWholeOutline ? "Show Less" : "Show All") { showsWholeOutline.toggle() }
                    .buttonStyle(.plain)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.accentInk)
                    .axLeaf("Chapters.Button.ShowAll")
            }
        }
        if model.features.isEnabled(.ai) {
            Button("Generate Chapters") { model.extractSmartChapters() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(!model.isAIAvailable(for: .summary))
                .axLeaf("Chapters.Button.Generate")
            if !model.isAIAvailable(for: .summary), let reason = model.aiUnavailableReason {
                AIStatusNote(message: reason)
            } else if let error = model.chaptersError {
                AIStatusNote(message: error, kind: .failure)
            }
        }
    }
}

/// The Chapters ⋯ menu: run them again, or drop them.
struct ChapterActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.features.isEnabled(.ai) {
            Button("Regenerate") { model.extractSmartChapters() }
                .disabled(!model.isAIAvailable(for: .summary))
                .axLeaf("Chapters.Button.Regenerate")
        }
        Button("Clear") { model.clearSmartChapters() }
            .axLeaf("Chapters.Button.Clear")
    }
}

private struct ChapterRow: View {
    let start: Double
    let title: String
    var speaker: String?
    let onJump: () -> Void

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: onJump) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(Timecode.format(start))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .multilineTextAlignment(.leading)
                    if let speaker, let name = SegmentCard.speakerLabel(for: speaker) {
                        Text(name)
                            .font(DS.Font.caption)
                            .foregroundStyle(model.speakerColor(for: speaker))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Spacing.hair)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(hovering ? DS.Palette.surfaceHover : .clear)
                .padding(.horizontal, -DS.Spacing.tight)
        )
        .help("Jump to \(Timecode.format(start))")
        .axLeaf("Chapters.Button.Jump")
    }
}
