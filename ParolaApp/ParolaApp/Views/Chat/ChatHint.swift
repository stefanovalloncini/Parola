import SwiftUI

struct ChatHint: View {
    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DS.Color.secondaryText)
            Text("Ask anything about this transcript.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ChatUnavailable: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Chat unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChatEmpty: View {
    var body: some View {
        ContentUnavailableView {
            Label("No transcript", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Open a transcript to start chatting.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
