import SwiftUI
import AppKit
import ParolaCore

struct CustomizationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection("Theme and colors") {
                SettingRow("Appearance",
                           description: "Follows the system unless you pick light or dark.",
                           isFirst: true) {
                    Picker("", selection: $model.appTheme) {
                        Text("Match system").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160, alignment: .trailing)
                    .axLeaf("Customization.Picker.Appearance")
                }
                SettingRow("Theme",
                           description: "Recolors the accent across the whole app.") {
                    ThemePresetGallery()
                }
                SettingRow("Custom colors",
                           description: "Pick your own palette instead of a preset.") {
                    Toggle("", isOn: Binding(
                        get: { model.themeIsCustom },
                        set: { on in
                            if !on {
                                model.resetToPresetTheme()
                            } else if !model.resumeCustomPalette() {
                                beginCustom()
                            }
                        }
                    ))
                    .labelsHidden()
                    .axLeaf("Customization.Toggle.CustomColors")
                }
            }

            if model.themeIsCustom {
                SettingsSection("Palette") { CustomThemeEditor() }
            }

            SettingsSection("Text") {
                SettingRow("Monospaced timestamps",
                           description: "Use a fixed-width font for timestamps in the transcript.",
                           isFirst: true) {
                    Toggle("", isOn: $model.monospacedTimestamps).labelsHidden()
                        .axLeaf("Customization.Toggle.MonospacedTimestamps")
                }
            }
            ResetPaneButton(scope: .customization)
        }
    }

    private func beginCustom() {
        let p = DS.theme
        // Seed from the variant currently on screen; the light variant under dark mode
        // pairs light surfaces with dark-resolved system text and is unreadable.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        model.applyCustomPalette(.custom(
            accent: p.accent.editableColor(dark: dark),
            canvas: p.canvas.editableColor(dark: dark),
            surface: p.surface.editableColor(dark: dark),
            surfaceElevated: p.surfaceElevated.editableColor(dark: dark),
            divider: p.divider.editableColor(dark: dark),
            textPrimary: p.textPrimary.editableColor(dark: dark),
            textSecondary: p.textSecondary.editableColor(dark: dark)
        ))
    }
}

private struct ThemePresetGallery: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ThemePreset.allCases) { preset in
                let isActive = !model.themeIsCustom && model.appAccentRaw == preset.rawValue
                Button {
                    model.selectThemePreset(preset.rawValue)
                } label: {
                    ZStack {
                        Circle()
                            .fill(preset.accent.color)
                            .frame(width: 22, height: 22)
                        if isActive {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.6), lineWidth: 2)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(preset.localizedLabel)
                .accessibilityLabel(preset.localizedLabel)
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .axLeaf("Customization.Button.Theme.\(preset.rawValue)")
            }
        }
    }
}

/// One colour well of the custom palette editor, and the binding it edits the palette through.
struct CustomPaletteWell {
    let label: String
    let keyPath: WritableKeyPath<ThemePalette, ThemeColor>
    /// On for the tokens a preset draws translucent: an opaque well stores alpha 1 on the first edit.
    let supportsOpacity: Bool

    @MainActor static let all: [CustomPaletteWell] = [
        CustomPaletteWell(label: "Accent", keyPath: \.accent, supportsOpacity: false),
        CustomPaletteWell(label: "Background", keyPath: \.canvas, supportsOpacity: false),
        CustomPaletteWell(label: "Surface", keyPath: \.surface, supportsOpacity: false),
        CustomPaletteWell(label: "Elevated surface", keyPath: \.surfaceElevated, supportsOpacity: false),
        CustomPaletteWell(label: "Divider", keyPath: \.divider, supportsOpacity: true),
        CustomPaletteWell(label: "Primary text", keyPath: \.textPrimary, supportsOpacity: true),
        CustomPaletteWell(label: "Secondary text", keyPath: \.textSecondary, supportsOpacity: false),
    ]

    @MainActor
    func binding(_ model: AppModel) -> Binding<Color> {
        Binding(
            get: { model.editablePalette[keyPath: keyPath].editableColor },
            set: { model.previewCustomPalette(model.editablePalette.setting(keyPath, to: $0)) }
        )
    }
}

private struct CustomThemeEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ForEach(CustomPaletteWell.all, id: \.label) { well in
                colorRow(well, isFirst: well.label == CustomPaletteWell.all.first?.label)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object is NSColorPanel { model.commitPaletteDraft() }
        }
        .onDisappear { model.commitPaletteDraft() }
    }

    private func colorRow(_ well: CustomPaletteWell, isFirst: Bool) -> some View {
        SettingRow(LocalizedStringKey(well.label), isFirst: isFirst) {
            ColorPicker("", selection: well.binding(model), supportsOpacity: well.supportsOpacity)
                .labelsHidden()
                .axLeaf("Customization.ColorPicker.\(well.label.replacingOccurrences(of: " ", with: ""))")
        }
    }
}
