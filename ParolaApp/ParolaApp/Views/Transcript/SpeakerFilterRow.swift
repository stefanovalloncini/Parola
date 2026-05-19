import SwiftUI
import ParolaCore

struct SpeakerFilterRow: View {
    let speakers: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.small) {
                SpeakerChip(label: "All", tint: nil, isSelected: selection == nil) {
                    selection = nil
                }
                ForEach(speakers, id: \.self) { speaker in
                    SpeakerChip(
                        label: speaker,
                        tint: DS.speakerColor(for: speaker),
                        isSelected: selection == speaker
                    ) {
                        selection = (selection == speaker) ? nil : speaker
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SpeakerChip: View {
    let label: String
    let tint: Color?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let tint {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(DS.Font.caption)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Color.separator.opacity(isSelected ? 0 : 0.5), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSelected ? "Show all speakers" : "Show only \(label)")
    }

    private var background: Color {
        if isSelected { return DS.Color.accent }
        if hovering { return DS.Color.surfaceElevated.opacity(0.85) }
        return DS.Color.surfaceElevated
    }
}
