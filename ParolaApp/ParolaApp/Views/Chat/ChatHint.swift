import SwiftUI

struct ChatHint: View {
    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 28

    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: iconSize, weight: .light))
                .foregroundStyle(DS.Color.secondaryText)
            Text("Ask anything about this transcript.")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ChatUnavailable: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Chat Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            Text(message)
        } actions: {
            OpenAISettingsButton(leaf: "Chat.Button.OpenAISettings")
                .buttonStyle(DSPillButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A turn that got no answer, shown under the conversation instead of in place of it.
struct ChatTurnFailure: View {
    let message: String

    var body: some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Color.warningText)
        }
        .font(DS.Font.secondary)
        .foregroundStyle(DS.Color.secondaryText)
        .padding(.vertical, DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .axLeaf("Chat.Label.TurnFailure")
    }
}

struct ChatEmpty: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Transcript", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Open a transcript to start chatting.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
