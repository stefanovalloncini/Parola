import SwiftUI
import ParolaCore

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 40)
                bubble
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                            .fill(DS.Color.accentFill)
                    )
                    .foregroundStyle(DS.Color.onAccent)
            } else {
                bubble
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                            .fill(DS.Color.surfaceElevated)
                    )
                    .foregroundStyle(DS.Color.primaryText)
                Spacer(minLength: 40)
            }
        }
        .padding(.vertical, DS.Spacing.hair)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role == .user ? "You" : "Assistant"): \(Self.displayText(message.text).isEmpty ? "No response" : message.text)")
    }

    private var bubble: some View {
        let shown = Self.displayText(message.text)
        return Group {
            if shown.isEmpty {
                Text("No response")
                    .italic()
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                Text(shown)
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .frame(maxWidth: 480, alignment: .leading)
    }

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
