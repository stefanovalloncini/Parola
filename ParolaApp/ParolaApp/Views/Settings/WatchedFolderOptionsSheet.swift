import SwiftUI
import ParolaCore

struct WatchedFolderOptionsSheet: View {
    @Environment(AppModel.self) private var model
    let store: WatchedFoldersStore
    let folder: WatchedFolder
    let onClose: () -> Void

    private var options: WatchedFolderOptions { store.options(for: folder.id) }

    var body: some View {
        SheetFrame(titleVerbatim: String(localized: "Options for \(folder.displayName)"), onClose: onClose) {
            Form {
                transcriptionSection
                exportSection
            }
            .formStyle(.grouped)
        } footer: {
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .axLeaf("WatchedFolders.Options.Button.Done")
            }
        }
        .sheetDescription(Text(verbatim: (folder.displayPath as NSString).abbreviatingWithTildeInPath))
        .sheetSize(width: 560, minHeight: 440, maxHeight: 720)
    }

    private var transcriptionSection: some View {
        SettingsSection("New Files") {
            SettingRow("Auto-Transcribe", description: "Off: new files wait in Batch until you start them.") {
                Toggle("", isOn: binding(\.autoTranscribes)).labelsHidden()
                    .axLeaf("WatchedFolders.Options.Toggle.AutoTranscribe")
            }
            SettingRow("Folder Depth") {
                Picker("", selection: binding(\.includesSubfolders)) {
                    Text("This Folder Only").tag(false)
                    Text("Include Subfolders").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .trailing)
                .axLeaf("WatchedFolders.Options.Picker.Depth")
            }
            SettingRow(
                "Save to Library",
                description: options.libraryToggleIsEnabled
                    ? "Off: the transcript is only exported."
                    : "Choose an export format first."
            ) {
                Toggle("", isOn: binding(\.savesToLibrary)).labelsHidden()
                    .disabled(!options.libraryToggleIsEnabled)
                    .help(options.libraryToggleIsEnabled ? "" : String(localized: "Choose an export format first."))
                    .axLeaf("WatchedFolders.Options.Toggle.SaveToLibrary")
            }
        }
    }

    private var exportSection: some View {
        SettingsSection("Export") {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text("Export Formats").font(DS.Font.bodyStrong)
                ExportPresetChecks(
                    presets: model.exportPresets,
                    leafPrefix: "WatchedFolders.Options",
                    isOn: { options.exportPresetIDs.contains($0) },
                    setOn: { id, isOn in
                        var changed = options
                        if isOn {
                            guard !changed.exportPresetIDs.contains(id) else { return }
                            changed.exportPresetIDs.append(id)
                        } else {
                            changed.exportPresetIDs.removeAll { $0 == id }
                        }
                        store.setOptions(changed, for: folder.id)
                    }
                )
            }
            SettingRow(
                "Export To",
                description: model.autoExportFolder == nil ? "Choose an Auto-Export folder in Auto-Export settings." : nil
            ) {
                Picker("", selection: binding(\.exportsToAutoExportFolder)) {
                    Text("Next to the File").tag(false)
                    Text("Auto-Export Folder").tag(true)
                        .disabled(!options.offersAutoExportFolder(chosen: model.autoExportFolder != nil))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200, alignment: .trailing)
                .disabled(!options.exportsFiles)
                .axLeaf("WatchedFolders.Options.Picker.ExportTo")
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<WatchedFolderOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.options(for: folder.id)[keyPath: keyPath] },
            set: { value in
                var changed = store.options(for: folder.id)
                changed[keyPath: keyPath] = value
                store.setOptions(changed, for: folder.id)
            }
        )
    }
}
