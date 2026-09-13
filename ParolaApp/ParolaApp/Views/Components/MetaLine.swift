import SwiftUI

/// One `Text`, not a stack of them, so a row's meta line truncates whole instead of losing a fact.
struct MetaLine: View {
    private let parts: [String]
    private let tint: Color?
    private let timecode: String?

    init(_ parts: [String?], tint: Color? = nil) {
        self.parts = Self.present(parts)
        self.tint = tint
        timecode = nil
    }

    /// A row's fact cluster: the length leads it as a timecode, the facts after it read as text.
    init(timecode: String?, _ parts: [String?], tint: Color? = nil) {
        self.parts = Self.present(parts)
        self.tint = tint
        self.timecode = timecode.flatMap { $0.isEmpty ? nil : $0 }
    }

    nonisolated static func present(_ parts: [String?]) -> [String] {
        parts.compactMap { $0 }.filter { !$0.isEmpty }
    }

    nonisolated static func joined(_ parts: [String?]) -> String {
        present(parts).joined(separator: " · ")
    }

    /// The middots sit back so the facts read as facts, not as a line of punctuation.
    nonisolated static func attributed(_ parts: [String], color: Color, timecode: String? = nil) -> AttributedString {
        var line = AttributedString()
        if let timecode {
            var clock = AttributedString(timecode)
            clock.foregroundColor = color
            clock.font = DS.Font.mono
            line.append(clock)
        }
        for (index, part) in parts.enumerated() {
            if index > 0 || timecode != nil {
                var separator = AttributedString(" · ")
                separator.foregroundColor = color.opacity(0.5)
                line.append(separator)
            }
            var piece = AttributedString(part)
            piece.foregroundColor = color
            line.append(piece)
        }
        return line
    }

    var body: some View {
        Text(Self.attributed(parts, color: tint ?? DS.Color.secondaryText, timecode: timecode))
            .font(DS.Font.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}
