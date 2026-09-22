import SwiftUI
import ParolaCore

struct SummaryChapterRow: View {
    let chapter: Chapter
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.seekTo(chapter: chapter)
        } label: {
            HStack(spacing: DS.Spacing.regular) {
                Text(Timecode.format(chapter.start))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 64, alignment: .leading)
                Text(chapter.title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer()
                Image(systemName: "play.fill")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .rowChrome(selected: false, hovered: hovering, selection: .native)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
