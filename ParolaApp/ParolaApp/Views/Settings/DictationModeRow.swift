import SwiftUI
import ParolaCore
import ParolaDictation

struct DictationModeRow: View {
    @Binding var selectedID: String

    var body: some View {
        Picker("Cleanup style", selection: $selectedID) {
            ForEach(DictationModePreset.builtIns) { preset in
                Text(LocalizedStringKey(preset.name)).tag(preset.promptID?.uuidString ?? "")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .axLeaf("Dictation.Picker.CleanupStyle")
    }
}
