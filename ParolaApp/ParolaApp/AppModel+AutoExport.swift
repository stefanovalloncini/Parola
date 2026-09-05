import Foundation
import SwiftUI
import ParolaCore

extension AppModel {

    func loadAutoExportRules() {
        autoExportRules = readJSON([AutoExportRule].self, forKey: "autoExportRules") ?? []
    }

    func saveAutoExportRules() {
        writeJSON(autoExportRules, forKey: "autoExportRules")
    }

    func runAutoExports(transcript: Transcript, sourceURL: URL, skippingTargets: Set<URL> = []) {
        let formats = AutoExportEngine.plannedFormats(
            rules: autoExportRules,
            sourceExtension: sourceURL.pathExtension
        )
        guard !formats.isEmpty else { return }
        let markdownTimestamps = self.markdownTimestamps
        let txtTimestamps = self.txtExportTimestamps
        let htmlTheme = HtmlExportTheme(rawValue: htmlExportThemeRaw) ?? .light
        let captionLength = subtitleCaptionLength
        Task.detached(priority: .utility) {
            for format in formats {
                do {
                    let target = sourceURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
                    guard !skippingTargets.contains(target) else { continue }
                    let exporter: any TranscriptExporter = switch format {
                    case .txt:  TxtExporter(options: TxtOptions(showTimestamps: txtTimestamps))
                    case .srt:  SrtExporter(options: SubtitleOptions(captionLength: captionLength))
                    case .vtt:  VttExporter(options: SubtitleOptions(captionLength: captionLength))
                    case .md:   MarkdownExporter(options: MarkdownOptions(showTimestamps: markdownTimestamps))
                    case .html: HtmlExporter(options: HtmlOptions(theme: htmlTheme))
                    default:    Exporters.exporter(for: format)
                    }
                    let data = try exporter.render(transcript)
                    try data.write(to: target, options: .atomic)
                } catch {
                    // Auto-export is best-effort; primary transcription already in the library.
                    ParolaLog.error(.export, "auto-export failed as \(format)", [.error: .error(error)])
                }
            }
        }
    }
}
