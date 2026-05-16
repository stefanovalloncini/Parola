import SwiftUI
import ParolaCore

struct DictationView: View {
    let state: DictationCoordinator.State

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            icon
                .font(.title2)
                .foregroundStyle(.white)
            Text(label)
                .font(DS.Font.body)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(DS.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.75))
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .listening:
            Image(systemName: "mic.fill")
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .transcribing:
            ProgressView().controlSize(.small).tint(.white)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "mic")
        }
    }

    private var label: String {
        switch state {
        case .idle: return "Ready"
        case .listening: return "Listening — hold F5, release to insert"
        case .transcribing: return "Transcribing…"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}
