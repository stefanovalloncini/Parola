import SwiftUI
import ParolaCore

/// Live text of what the current spec would write. Renders off the main actor after a short
/// pause, so dragging a toggle doesn't re-render the whole transcript on every frame.
struct ExportPreview: View {
    let spec: ExportSpec
    let transcript: Transcript

    @State private var text: String = ""

    static let characterCap = 20_000
    private static let debounce = Duration.milliseconds(150)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            ScrollView {
                Text(text)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.primaryText)
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

            if Self.previewSpec(for: spec).format != spec.format {
                Text("Layout preview not available for this format")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .task(id: spec) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let rendered = await Self.render(transcript: transcript, spec: spec)
            guard !Task.isCancelled else { return }
            text = rendered
        }
    }

    /// A binary format has no text to show, so the preview renders the same options as plain text.
    static func previewSpec(for spec: ExportSpec) -> ExportSpec {
        guard spec.format == .docx || spec.format == .pdf else { return spec }
        return ExportSpec(style: spec.style, format: .txt, options: spec.options)
    }

    static func render(transcript: Transcript, spec: ExportSpec) async -> String {
        let target = previewSpec(for: spec)
        let rendered = try? await AppModel.offMainIO {
            let text = try Exporters.exporter(for: target).renderText(transcript)
            guard text.count > characterCap else { return text }
            return String(text.prefix(characterCap)) + "\n…"
        }
        return rendered ?? ""
    }
}
