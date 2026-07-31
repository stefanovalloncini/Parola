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
                .font(DS.Font.subheadline)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text, prompt: prompt.map(Text.init))
                .textFieldStyle(.plain)
                .font(DS.Font.subheadline)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Font.subheadline)
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
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(DS.Palette.subtleFill)
        )
    }
}
