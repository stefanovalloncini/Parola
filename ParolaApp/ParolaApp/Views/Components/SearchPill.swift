import SwiftUI

struct SearchPill: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var prompt: String?
    var identifier: String

    init(text: Binding<String>, placeholder: LocalizedStringKey = "Search", prompt: String? = nil, identifier: String = "search.field") {
        self._text = text
        self.placeholder = placeholder
        self.prompt = prompt
        self.identifier = identifier
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.regular))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text, prompt: prompt.map(Text.init))
                .textFieldStyle(.plain)
                .font(.subheadline)
                .accessibilityIdentifier(identifier)
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
                .accessibilityLabel("Clear")
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
