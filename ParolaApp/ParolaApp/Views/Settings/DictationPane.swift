import SwiftUI
import ParolaCore

struct DictationPane: View {
    @EnvironmentObject var model: AppModel
    @State private var customApps: [(bundleID: String, name: String)] = []

    private var currentModeName: String? {
        let id = model.dictationCleanupPromptID
        if id.isEmpty {
            return DictationModePreset.builtIns.first { $0.promptID == nil }?.name
        }
        guard let uuid = UUID(uuidString: id) else { return nil }
        if let preset = DictationModePreset.builtIns.first(where: { $0.promptID == uuid }) {
            return preset.name
        }
        return Prompt.builtIns.first(where: { $0.id == uuid })?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DictationHUDPreview(
                style: model.dictationIndicatorStyle,
                modeName: currentModeName
            )
            SettingsSection {
                SettingRow("Enable dictation",
                           description: modeDescription,
                           isFirst: true) {
                    Toggle("", isOn: $model.dictationEnabled).labelsHidden()
                }
                SettingRow("Mode") {
                    Picker("", selection: $model.dictationModeRaw) {
                        ForEach(DictationMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                SettingRow("Activation key",
                           description: "Click to record any key combination.") {
                    HotkeyRecorder(
                        keyCode: $model.dictationKeyCode,
                        modifierRawValue: $model.dictationKeyModifiers
                    )
                }
                SettingRow("Indicator style",
                           description: model.dictationIndicatorStyle.description) {
                    Picker("", selection: $model.dictationIndicatorStyleRaw) {
                        ForEach(DictationIndicatorStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                SettingRow("HUD opacity",
                           description: "Make the dictation HUD translucent.") {
                    HStack(spacing: 8) {
                        Slider(value: $model.dictationHudOpacity, in: 0.4...1.0)
                            .frame(width: 160)
                        Text("\(Int(model.dictationHudOpacity * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingRow("Mode",
                           description: "Quick context: how the dictated text should land.") {
                    DictationModeRow(selectedID: $model.dictationCleanupPromptID)
                }
                SettingRow("Rewrite preset",
                           description: "Fine-tune the cleanup tone.") {
                    RewritePresetRow(selectedID: $model.dictationCleanupPromptID)
                }
                SettingRow("Cleanup mode") {
                    Picker("", selection: $model.dictationCleanupPromptID) {
                        Text("Raw (no cleanup)").tag("")
                        ForEach(Prompt.builtIns) { prompt in
                            Text(prompt.name).tag(prompt.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
                SettingRow("Strip self-corrections",
                           description: "Drops \"scratch that\", \"wait, no\", and collapses \", I mean,\" hedges.") {
                    Toggle("", isOn: $model.dictationStripSelfCorrections).labelsHidden()
                }
                SettingRow("Paste delay",
                           description: "Wait this long after dictation ends before pasting. Useful when the target app needs a beat to refocus.") {
                    HStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { Double(model.dictationPasteDelayMs) },
                            set: { model.dictationPasteDelayMs = Int($0) }
                        ), in: 0...1000, step: 50)
                        .frame(width: 160)
                        Text("\(model.dictationPasteDelayMs) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            SettingHelper(text: "Requires Input Monitoring permission. The HUD shows a live waveform while you speak.")

            SettingsSection("Per-app workflows") {
                let seeds = AppModel.dictationOverrideApps
                ForEach(Array(seeds.enumerated()), id: \.element.bundleID) { idx, app in
                    WorkflowRow(app: app, isFirst: idx == 0, isRemovable: false)
                }
                ForEach(Array(customApps.enumerated()), id: \.element.bundleID) { _, app in
                    WorkflowRow(app: app, isFirst: false, isRemovable: true)
                }
            }
            HStack {
                Button {
                    model.presentAddDictationAppPanel()
                    customApps = model.customDictationOverrideApps()
                } label: {
                    Label("Add app…", systemImage: "plus.circle")
                }
                Spacer()
            }
            SettingHelper(text: "When the frontmost app matches, dictation uses these overrides. Prompt cleans up the text after transcription; language hints the engine before it.")
            ResetPaneButton(scope: .dictation)
        }
        .onAppear {
            customApps = model.customDictationOverrideApps()
        }
        .onChange(of: model.dictationPerAppOverridesJSON) { _, _ in
            customApps = model.customDictationOverrideApps()
        }
    }

    private var modeDescription: String {
        model.dictationMode.description
    }
}

private struct WorkflowRow: View {
    let app: (bundleID: String, name: String)
    let isFirst: Bool
    let isRemovable: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingRow(app.name, isFirst: isFirst) {
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { model.dictationOverridePromptID(for: app.bundleID) },
                    set: { model.setDictationOverridePromptID($0, for: app.bundleID) }
                )) {
                    Text("Default prompt").tag("")
                    ForEach(Prompt.builtIns) { prompt in
                        Text(prompt.name).tag(prompt.id.uuidString)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)

                Picker("", selection: Binding(
                    get: { model.dictationOverrideLanguage(for: app.bundleID) },
                    set: { model.setDictationOverrideLanguage($0, for: app.bundleID) }
                )) {
                    Text("Default language").tag("")
                    ForEach(WorkflowLanguageOptions.options, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)

                Picker("", selection: Binding(
                    get: { model.dictationOverrideInsertion(for: app.bundleID) },
                    set: { model.setDictationOverrideInsertion($0, for: app.bundleID) }
                )) {
                    Text("Paste").tag(DictationInsertionMode.paste)
                    Text("Keystrokes").tag(DictationInsertionMode.keystroke)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)

                if isRemovable {
                    Button(role: .destructive) {
                        model.removeDictationOverride(for: app.bundleID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct DictationModeRow: View {
    @Binding var selectedID: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DictationModePreset.builtIns) { preset in
                modePill(preset)
            }
            Spacer(minLength: 0)
        }
    }

    private func modePill(_ preset: DictationModePreset) -> some View {
        let targetID = preset.promptID?.uuidString ?? ""
        let on = selectedID == targetID
        return Button {
            selectedID = targetID
        } label: {
            Text(preset.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(height: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(on ? DS.Color.accent.opacity(0.85) : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(on ? DS.Color.accent.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) dictation mode")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct RewritePresetRow: View {
    @Binding var selectedID: String

    private static let presetIDs: Set<String> = Set(Prompt.rewritePresets.map { $0.id.uuidString })

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Prompt.rewritePresets) { preset in
                presetPill(preset)
            }
            Spacer(minLength: 0)
        }
    }

    private func presetPill(_ preset: Prompt) -> some View {
        let on = selectedID == preset.id.uuidString
        return Button {
            selectedID = on ? "" : preset.id.uuidString
        } label: {
            Text(presetLabel(preset))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(height: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(on ? DS.Color.accent.opacity(0.85) : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(on ? DS.Color.accent.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(presetLabel(preset)) rewrite preset")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func presetLabel(_ preset: Prompt) -> String {
        switch preset.name {
        case "Professional tone": return "Formal"
        case "Bullet points": return "Bullets"
        default: return preset.name
        }
    }
}

private enum WorkflowLanguageOptions {
    static let options: [(code: String, name: String)] = [
        ("en", "English"),
        ("it", "Italian"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean")
    ]
}
