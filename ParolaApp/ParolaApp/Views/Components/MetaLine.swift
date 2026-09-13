import SwiftUI

/// One `Text`, not a stack of them, so a row's meta line truncates whole instead of losing a fact.
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
