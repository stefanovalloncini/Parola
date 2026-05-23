import SwiftUI
import ParolaCore

struct RewritePresetRow: View {
    @Binding var selectedID: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Prompt.rewritePresets) { preset in
                let on = selectedID == preset.id.uuidString
                Chip(
                    title: LocalizedStringKey(presetLabel(preset)),
                    isSelected: on,
                    size: .prominent,
                    style: .subtle,
                    selectedFill: DS.Color.accent.opacity(0.85)
                ) {
                    selectedID = on ? "" : preset.id.uuidString
                }
                .accessibilityLabel("\(presetLabel(preset)) rewrite preset")
            }
            Spacer(minLength: 0)
        }
    }

    private func presetLabel(_ preset: Prompt) -> String {
        switch preset.name {
        case "Professional tone": return "Formal"
        case "Bullet points": return "Bullets"
        default: return preset.name
        }
    }
}
