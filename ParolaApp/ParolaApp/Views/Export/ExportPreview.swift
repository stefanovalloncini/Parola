import SwiftUI
import ParolaCore

/// Live text of what the current spec would write. Renders off the main actor after a short
/// pause, so dragging a toggle doesn't re-render the whole transcript on every frame.
struct ExportPreview: View {
    let spec: ExportSpec
    let transcript: Transcript

    @State private var state: State = .rendering

    private enum State: Equatable {
        case rendering
        case text(String)
        case failed(String)
    }

    static let characterCap = 20_000
    private static let debounce = Duration.milliseconds(150)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            ScrollView {
                body(for: state)
                    .font(DS.Font.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
            .axLeaf("Export.Text.Preview")

            if spec.textRendering != spec {
                Text("Layout preview not available for this format")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        // The previous text stays up while the next one renders; only the first load reads "Rendering…".
        .task(id: spec) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            do {
                let rendered = try await Self.render(transcript: transcript, spec: spec)
                guard !Task.isCancelled else { return }
                state = .text(rendered)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(AppModel.exportFailureMessage(for: error))
            }
        }
    }

    @ViewBuilder
    private func body(for state: State) -> some View {
        switch state {
        case .rendering:
            Text("Rendering…").foregroundStyle(DS.Color.secondaryText)
        case .text(let text):
            Text(text).foregroundStyle(DS.Color.primaryText)
        case .failed(let message):
            Text(message).foregroundStyle(DS.Color.dangerText)
        }
    }

    /// The export's first `characterCap` characters, rendered from the fewest segments that reach them.
    static func render(transcript: Transcript, spec: ExportSpec) async throws -> String {
        try await render(transcript: transcript, exporter: Exporters.exporter(for: spec.textRendering))
    }

    static func render(transcript: Transcript, exporter: any TranscriptExporter) async throws -> String {
        var limit = firstPrefixSegments
        var earlier: String?
        while limit < transcript.segments.count {
            // A prefix whose double already covers the transcript could never be confirmed; the full render follows.
            guard earlier != nil || limit * 2 < transcript.segments.count else { break }
            let head = try await Self.head(of: transcript, segments: limit, exporter: exporter)
            if head.isCapped {
                if let earlier {
                    // Two prefixes that agree stand for the whole; a head that moves with the segments (FCPXML's duration) disagrees.
                    guard head.text == earlier else { break }
                    return head.text
                }
                earlier = head.text
            }
            limit *= 2
        }
        return try await Self.head(of: transcript, segments: nil, exporter: exporter).text
    }

    private static let firstPrefixSegments = 200

    private static func head(
        of transcript: Transcript,
        segments limit: Int?,
        exporter: any TranscriptExporter
    ) async throws -> (text: String, isCapped: Bool) {
        try Task.checkCancellation()
        var prefix = transcript
        if let limit { prefix.segments = Array(transcript.segments.prefix(limit)) }
        let slice = prefix
        let cap = characterCap
        return try await AppModel.offMainIO {
            let text = try exporter.renderText(slice)
            guard let end = text.index(text.startIndex, offsetBy: cap, limitedBy: text.endIndex), end < text.endIndex else {
                return (text, false)
            }
            return (String(text[..<end]) + "\n…", true)
        }
    }
}
