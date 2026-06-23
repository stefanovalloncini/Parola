import ParolaCore
import SwiftUI

enum StatusBannerCopy {
    static func text(for phase: TranscriptionCoordinator.Phase) -> String? {
        switch phase {
        case .idle, .recording:
            return nil
        case .downloadingModel(let name, let progress):
            return "Downloading \(modelLabel(name)) · \(Int(progress * 100))%"
        case .loadingModel(let name):
            return "Loading \(modelLabel(name))…"
        case .transcribing(let file):
            return "Transcribing \(file.lastPathComponent)…"
        case .failed(let message):
            return message
        }
    }

    static func isError(for phase: TranscriptionCoordinator.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private static func modelLabel(_ id: String) -> String {
        ModelCatalog.variant(id: id)?.displayName ?? id
    }
}

struct StatusBanner: View {
    let phase: TranscriptionCoordinator.Phase

    var body: some View {
        if let text = StatusBannerCopy.text(for: phase) {
            HStack(spacing: 12) {
                if StatusBannerCopy.isError(for: phase) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(text).font(.subheadline)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
