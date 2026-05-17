import SwiftUI

struct SearchPill: View {
    @Binding var text: String
    var placeholder: String
    var prompt: String?

    init(text: Binding<String>, placeholder: String = "Search", prompt: String? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.prompt = prompt
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.regular))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text, prompt: prompt.map(Text.init))
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
