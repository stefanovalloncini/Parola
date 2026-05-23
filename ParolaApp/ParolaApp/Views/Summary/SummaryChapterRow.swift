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
                Text(timestamp(chapter.start))
                    .font(DS.Font.captionMono)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 64, alignment: .leading)
                Text(chapter.title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Color.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? DS.Color.accent.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
    }

    private func timestamp(_ s: Double) -> String {
        Duration.seconds(s).formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}
