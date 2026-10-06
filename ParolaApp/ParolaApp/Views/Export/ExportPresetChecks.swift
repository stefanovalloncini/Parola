import SwiftUI
import ParolaCore

/// The checkbox grid that picks export presets, shared by the auto-export rules and the batch panes.
struct ExportPresetChecks: View {
    let presets: [ExportPreset]
    let leafPrefix: String
    let isOn: (UUID) -> Bool
    let setOn: (UUID, Bool) -> Void

    var body: some View {
        let grid = [GridItem(.adaptive(minimum: 160), alignment: .leading)]
        LazyVGrid(columns: grid, alignment: .leading, spacing: 4) {
            ForEach(presets) { preset in
                Toggle(isOn: binding(for: preset.id)) {
                    ExportPresetChecks.label(preset).font(DS.Font.secondary)
                }
                .toggleStyle(.checkbox)
                .axLeaf("\(leafPrefix).Toggle.Preset.\(ExportPresetChecks.slug(preset))")
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { isOn(id) }, set: { setOn(id, $0) })
    }

    /// A built-in's name is a catalog key; a name the user typed is their own text and must never
    /// be looked one up as — "Cancel" would come back translated, and "%@" as a format string.
    static func label(_ preset: ExportPreset) -> Text {
        preset.isBuiltIn ? Text(LocalizedStringKey(preset.name)) : Text(verbatim: preset.name)
    }

    /// The built-ins name their extension, "Transcript (.txt)"; a chip beside them would print it twice.
    static func needsExtensionChip(_ preset: ExportPreset) -> Bool {
        !preset.name.localizedCaseInsensitiveContains(".\(preset.spec.format.fileExtension)")
    }

    /// Nothing stops two presets sharing a name, so the id's stem keeps their ax ids apart.
    static func slug(_ preset: ExportPreset) -> String {
        let letters = preset.name.filter { $0.isLetter || $0.isNumber }
        let stem = preset.id.uuidString.prefix(8)
        return letters.isEmpty ? "\(preset.spec.format.fileExtension).\(stem)" : "\(letters).\(stem)"
    }
}
