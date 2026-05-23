import SwiftUI
import ParolaCore

struct SpeakerFilterRow: View {
    let speakers: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.small) {
                Chip(
                    title: "All",
                    isSelected: selection == nil,
                    size: .regular,
                    help: "Show all speakers"
                ) {
                    selection = nil
                }
                ForEach(speakers, id: \.self) { speaker in
                    Chip(
                        title: LocalizedStringKey(speaker),
                        tint: DS.speakerColor(for: speaker),
                        isSelected: selection == speaker,
                        size: .regular,
                        help: selection == speaker ? "Show all speakers" : "Show only \(speaker)"
                    ) {
                        selection = (selection == speaker) ? nil : speaker
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}
