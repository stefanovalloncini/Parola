import SwiftUI
import AppKit
import ParolaCore

struct CustomizationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
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
                SettingsSection { CustomThemeEditor() }
            }

            SettingsSection {
                SettingRow("Monospaced timestamps",
                           description: "Use a fixed-width font for timestamps in the transcript.",
                           isFirst: true) {
                    Toggle("", isOn: $model.monospacedTimestamps).labelsHidden()
                        .axLeaf("Customization.Toggle.MonospacedTimestamps")
                }
                SettingRow("Sidebar density",
                           description: "Spacing in the library sidebar.") {
                    Picker("", selection: $model.sidebarDensity) {
                        Text("Comfortable").tag("comfortable")
                        Text("Compact").tag("compact")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160, alignment: .trailing)
                    .axLeaf("Customization.Picker.SidebarDensity")
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
                                .frame(width: 26, height: 26)
                        }
                    }
                    .padding(2)
                }
                .buttonStyle(.plain)
                .help(preset.label)
                .axLeaf("Customization.Button.Theme.\(preset.rawValue)")
            }
        }
    }
}

private struct CustomThemeEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            colorRow("Accent", \.accent, isFirst: true)
            colorRow("Background", \.canvas)
            colorRow("Surface", \.surface)
            colorRow("Elevated surface", \.surfaceElevated)
            colorRow("Divider", \.divider)
            colorRow("Primary text", \.textPrimary)
            colorRow("Secondary text", \.textSecondary)
        }
    }

    private func colorRow(_ label: String, _ keyPath: WritableKeyPath<ThemePalette, ThemeColor>, isFirst: Bool = false) -> some View {
        SettingRow(LocalizedStringKey(label), isFirst: isFirst) {
            ColorPicker("", selection: binding(keyPath), supportsOpacity: false)
                .labelsHidden()
                .axLeaf("Customization.ColorPicker.\(label.replacingOccurrences(of: " ", with: ""))")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ThemePalette, ThemeColor>) -> Binding<Color> {
        Binding(
            get: { DS.theme[keyPath: keyPath].editableColor },
            set: { newColor in
                var palette = DS.theme
                palette[keyPath: keyPath] = .uniform(RGBA(newColor))
                model.previewCustomPalette(palette)
            }
        )
    }
}
