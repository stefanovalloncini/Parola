import SwiftUI
import ParolaCore
import ParolaDictation

struct DictationModeRow: View {
    @Binding var selectedID: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DictationModePreset.builtIns) { preset in
                let targetID = preset.promptID?.uuidString ?? ""
                Chip(
                    title: LocalizedStringKey(preset.name),
                    isSelected: selectedID == targetID,
                    size: .prominent,
                    style: .subtle,
                    selectedFill: DS.Color.accent.opacity(0.85)
                ) {
                    selectedID = targetID
                }
                .accessibilityLabel("\(preset.name) dictation mode")
            }
            Spacer(minLength: 0)
        }
    }
}
