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
        .task(id: spec) {
            state = .rendering
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

    static func render(transcript: Transcript, spec: ExportSpec) async throws -> String {
        let target = spec.textRendering
        let cap = Self.characterCap
        return try await AppModel.offMainIO {
            let text = try Exporters.exporter(for: target).renderText(transcript)
            guard text.count > cap else { return text }
            return String(text.prefix(cap)) + "\n…"
        }
    }
}
