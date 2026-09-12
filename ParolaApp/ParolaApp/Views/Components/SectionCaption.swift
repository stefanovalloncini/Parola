import SwiftUI

/// The one uppercase caption that heads a group of rows: sidebar sections, inspector sections,
/// list section headers. `tint` is for the few captions that carry their own colour — a decay
/// bucket, a chip on a dark scrim — everything else takes the secondary text colour.
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
    }
}
