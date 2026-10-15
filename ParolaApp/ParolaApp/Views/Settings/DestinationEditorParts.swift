import SwiftUI
import ParolaCore

struct EditorCheckLabel: View {
    let result: EditorCheckResult

    var body: some View {
        Label {
            Text(verbatim: result.message)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? DS.Palette.success : DS.Palette.warning)
        }
        .axLeaf("SendTo.Label.CheckResult")
    }
}

/// A button that runs a check, with its spinner and its result underneath.
struct EditorCheckSection: View {
    let buttons: [(title: LocalizedStringKey, leaf: String, run: () async -> EditorCheckResult)]
    let canRun: Bool
    @State private var result: EditorCheckResult?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(buttons.indices, id: \.self) { index in
                    Button(buttons[index].title) { run(buttons[index].run) }
                        .sheetButton()
                        .disabled(!canRun || running)
                        .axLeaf(buttons[index].leaf)
                }
                if running { ProgressView().controlSize(.small) }
            }
            if let result { EditorCheckLabel(result: result) }
        }
    }

    private func run(_ check: @escaping () async -> EditorCheckResult) {
        running = true
        result = nil
        Task {
            result = await check()
            running = false
        }
    }
}

/// A secret field that says whether a value is already in the Keychain. Left empty, it keeps that value.
struct SecretFieldRow: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    let description: LocalizedStringKey?
    let reference: String
    let prompt: String
    let leaf: String
    @Binding var input: String
    @State private var isSaved = false

    var body: some View {
        SettingRow(title, description: description) {
            SecureField("", text: $input, prompt: Text(verbatim: isSaved ? String(localized: "Saved in Keychain") : prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .axLeaf(leaf)
        }
        .task(id: reference) { isSaved = await model.hasSavedSecret(reference) }
    }
}

extension DestinationKind {
    var localizedName: String {
        switch self {
        case .obsidianFolder: return String(localized: "Obsidian vault folder")
        case .obsidianREST: return String(localized: "Obsidian Local REST")
        case .webhook: return String(localized: "Webhook")
        case .notion: return String(localized: "Notion")
        }
    }
}
