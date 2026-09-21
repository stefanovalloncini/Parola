import Foundation
import SwiftUI
import ParolaCore

/// What the demo card states once the clip has played: how long it ran, how many words it wrote, and the formats that transcript could be saved as.
struct DemoTranscriptSummary {
    let durationLabel: String
    let wordCount: Int?

    init(script: DemoScript) {
        let seconds = Int(script.duration.rounded())
        durationLabel = String(format: "%d:%02d", seconds / 60, seconds % 60)
        wordCount = script.words.isEmpty ? nil : script.words.count
    }

    /// The formats the footer names, each one the app really writes.
    static let exportFormats: [ExportFormat] = [.txt, .md, .srt, .docx, .pdf]

    static func label(for format: ExportFormat) -> LocalizedStringKey {
        switch format {
        case .txt: "Text"
        case .md: "Markdown"
        case .srt: "SRT"
        case .docx: "Word"
        case .pdf: "PDF"
        default: LocalizedStringKey(format.displayName)
        }
    }
}
