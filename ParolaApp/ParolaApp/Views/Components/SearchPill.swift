import SwiftUI

struct SearchPill: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var prompt: String?
    var clearsOnEscape: Bool
    var identifier: String
    var clearButtonIdentifier: String

    init(
        text: Binding<String>,
        placeholder: LocalizedStringKey = "Search",
        prompt: String? = nil,
        clearsOnEscape: Bool = false,
        identifier: String = "search.field",
        clearButtonIdentifier: String = "search.field.clear"
    ) {
        self._text = text
        self.placeholder = placeholder
        self.prompt = prompt
        self.clearsOnEscape = clearsOnEscape
        self.identifier = identifier
        self.clearButtonIdentifier = clearButtonIdentifier
    }

    /// Esc has to keep reaching the sheet or window unless a screen asked for it and has text.
    enum EscapeOutcome: Equatable {
        case clear
        case ignore
    }

    static func escapeOutcome(clearsOnEscape: Bool, isEmpty: Bool) -> EscapeOutcome {
        clearsOnEscape && !isEmpty ? .clear : .ignore
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            TextField(placeholder, text: $text, prompt: prompt.map(Text.init))
                .textFieldStyle(.plain)
                .font(DS.Font.secondary)
                .accessibilityIdentifier(identifier)
                .onKeyPress(.escape) {
                    guard Self.escapeOutcome(clearsOnEscape: clearsOnEscape, isEmpty: text.isEmpty) == .clear
                    else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(clearButtonIdentifier)
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
