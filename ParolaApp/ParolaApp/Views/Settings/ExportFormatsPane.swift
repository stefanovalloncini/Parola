import SwiftUI
import AppKit
import ParolaCore

struct ExportFormatsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                let formats = ExportFormat.allCases
                ForEach(Array(formats.enumerated()), id: \.element) { idx, format in
                    SettingRow(titleVerbatim: format.rawValue.uppercased(),
                               description: Self.blurb(for: format),
                               isFirst: idx == 0) {
                        Text(verbatim: ".\(format.fileExtension)").foregroundStyle(DS.Color.secondaryText)
                    }
                }
            }
            SettingHelper(text: "Export the current transcript from the Transcript menu.")
        }
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

struct BatchExportSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                SettingRow("Multi-file transcription",
                           description: "Open multiple audio files at once to queue them for batch transcription.",
                           isFirst: true) {
                    Text("Drag & Drop").foregroundStyle(DS.Color.secondaryText)
                }
                SettingRow("Sidecar files",
                           description: "Pick formats and per-format options in the Batch view. Parola writes them next to each file as its transcription finishes.") {
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
            SettingHelper(text: "Drop a folder of files on the Parola window to start a batch.")
            ResetPaneButton(scope: .batchExport)
        }
    }
}
