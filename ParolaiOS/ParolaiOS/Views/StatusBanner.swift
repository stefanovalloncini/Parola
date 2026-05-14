import SwiftUI

struct StatusBanner: View {
    let phase: TranscriptionCoordinator.Phase

    var body: some View {
        if let content = bannerContent {
            HStack(spacing: 12) {
                if content.isError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(content.text).font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var bannerContent: (text: LocalizedStringKey, isError: Bool)? {
        switch phase {
        case .idle, .recording:
            return nil
        case .downloadingModel(let name, let progress):
            let percent = Int(progress * 100)
            return ("Downloading \(name) · \(percent)%", false)
        case .loadingModel(let name):
            return ("Loading \(name)…", false)
        case .transcribing(let file):
            return ("Transcribing \(file.lastPathComponent)…", false)
        case .failed(let message):
            return (LocalizedStringKey(message), true)
        }
    }
}
