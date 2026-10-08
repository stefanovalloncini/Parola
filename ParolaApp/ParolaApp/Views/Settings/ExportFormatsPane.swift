import SwiftUI
import AppKit
import ParolaCore

struct ExportFormatsPane: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var draftName: String = ""
    @State private var pendingDelete: ExportPreset?

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            SettingsSection {
                ForEach(Array(model.exportPresets.enumerated()), id: \.element.id) { index, preset in
                    ExportPresetRow(
                        preset: preset,
                        isFirst: index == 0,
                        isRenaming: renaming == preset.id,
                        draftName: $draftName,
                        onStartRename: {
                            draftName = preset.name
                            renaming = preset.id
                        },
                        onCommitRename: {
                            model.renameExportPreset(id: preset.id, to: draftName)
                            renaming = nil
                        },
                        canMoveUp: index > 0,
                        canMoveDown: index < model.exportPresets.count - 1,
                        onMoveUp: { model.moveExportPreset(id: preset.id, by: -1) },
                        onMoveDown: { model.moveExportPreset(id: preset.id, by: 1) },
                        onDelete: {
                            if model.exportPresetUse(id: preset.id).isUsed {
                                pendingDelete = preset
                            } else {
                                model.deleteExportPreset(id: preset.id)
                            }
                        }
                    )
                }
            }

            SettingHelper(text: "Presets are what the Export As menu, the auto-export rules and the batch runs write. Add one from the Export sheet with Save as Preset.")

            SettingsSection("Export options") {
                SettingRow("Subtitle line length",
                           description: "Applied to SRT and VTT exports and to the subtitle length warnings in the transcript view.",
                           isFirst: true) {
                    Picker("", selection: $model.subtitleCaptionLengthRaw) {
                        ForEach(CaptionLength.allCases) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200, alignment: .trailing)
                    .axLeaf("ExportFormats.Picker.SubtitleLength")
                }
                SettingRow("Markdown timestamps",
                           description: "Prefix each Markdown paragraph with its start time.") {
                    Toggle("", isOn: $model.markdownTimestamps).labelsHidden()
                        .axLeaf("ExportFormats.Toggle.MarkdownTimestamps")
                }
                SettingRow("Plain text timestamps",
                           description: "Prefix each TXT line with its start time.") {
                    Toggle("", isOn: $model.txtExportTimestamps).labelsHidden()
                        .axLeaf("ExportFormats.Toggle.TxtTimestamps")
                }
                SettingRow("HTML theme",
                           description: "Color scheme used by the HTML export.") {
                    Picker("", selection: $model.htmlExportThemeRaw) {
                        ForEach(HtmlExportTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160, alignment: .trailing)
                    .axLeaf("ExportFormats.Picker.HtmlTheme")
                }
            }

            SettingHelper(text: "These apply to the Transcript menu's copy commands, the library's bulk export and the subtitle warnings. Presets keep their own settings.")

            ResetPaneButton(scope: .exportFormats)
        }
        .confirmationDialog(
            pendingDeleteTitle,
            isPresented: isConfirmingDelete,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { preset in
            Button("Delete", role: .destructive) {
                model.deleteExportPreset(id: preset.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { preset in
            Text(verbatim: model.exportPresetUse(id: preset.id).deleteMessage)
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var pendingDeleteTitle: String {
        String(localized: "Delete “\(pendingDelete?.name ?? "")”?")
    }

    static func blurb(for format: ExportFormat) -> LocalizedStringKey {
        switch format {
        case .txt: return "Plain text. Line timestamps optional at export."
        case .srt: return "SubRip subtitles with numbered, timed cues."
        case .vtt: return "WebVTT subtitles for web players."
        case .json: return "Full transcript data: segments, timings, words, speakers."
        case .jsonl: return "One JSON segment per line, for scripts and pipelines."
        case .md: return "Markdown paragraphs. Start-time prefixes optional at export."
        case .html: return "Web page in a light, dark, or sepia theme."
        case .csv: return "Spreadsheet rows: start, end, speaker, text."
        case .tsv: return "Tab-separated rows, same columns as CSV."
        case .docx: return "Word document with speaker names."
        case .pdf: return "Print-ready document."
        case .fcpxml: return "Final Cut Pro project with the transcript as captions."
        case .lrc: return "Timed lyric lines for music players."
        }
    }
}

private struct ExportPresetRow: View {
    let preset: ExportPreset
    let isFirst: Bool
    let isRenaming: Bool
    @Binding var draftName: String
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DS.Spacing.regular) {
                VStack(alignment: .leading, spacing: 2) {
                    if isRenaming {
                        TextField("", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit(onCommitRename)
                            .axLeaf("ExportFormats.TextField.Name.\(ExportPresetChecks.slug(preset))")
                    } else {
                        ExportPresetChecks.label(preset)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.primaryText)
                    }
                    Text(ExportFormatsPane.blurb(for: preset.spec.format))
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Spacing.small)
                if ExportPresetChecks.needsExtensionChip(preset) {
                    BatchFormatChip(extension: preset.spec.format.fileExtension)
                }
                controls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: DS.Spacing.tight) {
            Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                .buttonStyle(DSIconChipButtonStyle(side: 24))
                .disabled(!canMoveUp)
                .help("Move up")
                .axLeaf("ExportFormats.Button.MoveUp.\(ExportPresetChecks.slug(preset))")
            Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                .buttonStyle(DSIconChipButtonStyle(side: 24))
                .disabled(!canMoveDown)
                .help("Move down")
                .axLeaf("ExportFormats.Button.MoveDown.\(ExportPresetChecks.slug(preset))")
            Button(action: isRenaming ? onCommitRename : onStartRename) {
                Image(systemName: isRenaming ? "checkmark" : "pencil")
            }
            .buttonStyle(DSIconChipButtonStyle(side: 24))
            .help(isRenaming ? "Save the name" : "Rename")
            .axLeaf("ExportFormats.Button.Rename.\(ExportPresetChecks.slug(preset))")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(DSIconChipButtonStyle(side: 24))
                .disabled(preset.isBuiltIn)
                .help("Delete this preset")
                .axLeaf("ExportFormats.Button.Delete.\(ExportPresetChecks.slug(preset))")
        }
    }
}

struct BatchExportSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsForm {
            SettingsSection("Export Presets") {
                VStack(alignment: .leading, spacing: DS.Spacing.small) {
                    Text("Parola writes these presets beside every file a batch transcribes.")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                    ExportPresetChecks(
                        presets: model.exportPresets,
                        leafPrefix: "BatchExport",
                        isOn: { model.batchExportPresetIDs.contains($0) },
                        setOn: { id, isOn in model.setBatchExportPreset(id, selected: isOn) }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsSection {
                SettingRow("Batch view",
                           description: "Pick presets in the Batch view too. Parola writes them as each transcription finishes.",
                           isFirst: true) {
                    Button("Open Batch") {
                        model.route = .batch
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows where window.canBecomeMain {
                            window.makeKeyAndOrderFront(nil)
                            break
                        }
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("BatchExport.Button.OpenBatch")
                }
            }
            SettingHelper(text: "To start a batch, open several files at once or drop a folder on the Parola window.")
            ResetPaneButton(scope: .batchExport)
        }
    }
}
