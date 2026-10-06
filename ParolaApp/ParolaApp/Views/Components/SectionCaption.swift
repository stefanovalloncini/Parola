import SwiftUI

/// The one uppercase caption that heads a group of rows; `tint` is for the few that carry their own colour.
struct SectionCaption: View {
    private let text: Text
    private let tint: Color?

    init(_ title: LocalizedStringKey, tint: Color? = nil) {
        self.text = Text(title)
        self.tint = tint
    }

    init(_ text: Text, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        text
            .font(DS.Font.caption)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(tint ?? DS.Color.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}
