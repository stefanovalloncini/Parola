import SwiftUI
import ParolaCore

/// The checkbox grid that picks export presets, shared by the auto-export rules and the batch panes.
struct ExportPresetChecks: View {
    let presets: [ExportPreset]
    let leafPrefix: String
    let isOn: (UUID) -> Bool
    let toggle: (UUID) -> Void

    var body: some View {
        let grid = [GridItem(.adaptive(minimum: 160), alignment: .leading)]
        LazyVGrid(columns: grid, alignment: .leading, spacing: 4) {
            ForEach(presets) { preset in
                Toggle(isOn: binding(for: preset.id)) {
                    Text(LocalizedStringKey(preset.name)).font(DS.Font.secondary)
                }
                .toggleStyle(.checkbox)
                .axLeaf("\(leafPrefix).Toggle.Preset.\(ExportPresetChecks.slug(preset))")
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { isOn(id) }, set: { _ in toggle(id) })
    }

    static func slug(_ preset: ExportPreset) -> String {
        let letters = preset.name.filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? preset.spec.format.fileExtension : letters
    }
}
