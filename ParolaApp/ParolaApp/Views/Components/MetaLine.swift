import SwiftUI

/// The facts a row states about itself, joined by a middot into one line. One `Text`, not a stack
/// of them, so the line truncates as a whole instead of dropping a fact at a time.
struct MetaLine: View {
    private let text: String
    private let tint: Color?

    init(_ parts: [String?], tint: Color? = nil) {
        self.text = Self.joined(parts)
        self.tint = tint
    }

    nonisolated static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.secondary)
            .monospacedDigit()
            .foregroundStyle(tint ?? DS.Color.secondaryText)
            .lineLimit(1)
    }
}
